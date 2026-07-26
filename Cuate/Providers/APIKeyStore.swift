import Foundation

/// Secure storage for provider API keys.
///
/// Security model:
/// - Keys live exclusively in the macOS Keychain (device-only, non-syncing —
///   see `KeychainHelper.save`), never in `UserDefaults`, files, or logs.
/// - The decrypted bundle is held in memory for the process lifetime (see
///   `bundleCache`) and never reaches observable app state or the UI, which
///   only ever sees a masked representation.
///
/// Why the values are cached rather than re-read per request: every Keychain
/// read is a synchronous securityd IPC, and when the item's ACL no longer
/// matches the running binary (which is the case after EVERY update — each
/// build is re-signed) securityd wants to put an authorization dialog on
/// screen and blocks the calling thread until it is answered. Reading at
/// request time therefore froze the whole app on every message sent. The
/// bundle is now read ONCE, off the main thread; the keys are in memory during
/// a request anyway, so keeping them there for the session costs no real
/// secrecy and removes the freeze entirely.
///
/// Storage layout: ALL keys live in ONE keychain item (a JSON dictionary
/// keyed by the account names below) — one ACL to authorize instead of seven.
/// Pre-bundle per-key items are migrated in once (`migrationFlag`).
nonisolated enum APIKeyStore {
    private static let service = "com.getcuate.Cuate.apikeys"
    /// Account of the single JSON-bundle item holding every key.
    private static let bundleAccount = "bundle"
    /// Set once the legacy per-key items have been folded into the bundle,
    /// so fresh installs never scan (and possibly prompt for) legacy items.
    private static let migrationFlag = "apiKeysMigratedToBundle"

    /// Service name used before the app was renamed to Cuate. Kept on its own
    /// flag rather than `migrationFlag`: pre-rename installs already have that
    /// one set to true, and it is carried over with the rest of the defaults.
    private static let legacyService = "org.topassistant.AISpotlight.apikeys"
    private static let renameCarryOverFlag = "keysCarriedOverFromLegacyService"

    /// Accounts used by the pre-bundle layout (one keychain item each).
    private static var legacyAccounts: [String] {
        ProviderID.allCases.map(\.rawValue) + AuxKey.allCases.map { "aux." + $0.rawValue }
    }

    /// Guards every field below.
    private static let bundleLock = NSLock()
    /// Decrypted keys, cached for the process lifetime. `nil` = never read yet.
    private static var bundleCache: [String: String]?
    private static var warmInFlight = false
    private static var repairInFlight = false

    /// Whether the keys have been read into memory (all sync accessors are
    /// cache-only, so everything reports "no key" until this is true).
    static var isWarm: Bool { bundleLock.withLock { bundleCache != nil } }

    // MARK: - Warming

    /// Fills the cache with ONE Keychain read. MUST be called off the main
    /// thread. Idempotent, and a no-op once warm.
    ///
    /// If the read is refused because the item's ACL no longer matches this
    /// build, it escalates to an interactive read — still off the main thread,
    /// so macOS' dialog appears while the app stays fully responsive — and
    /// rewrites the item afterwards so the ACL matches the current signature
    /// and no later launch has to ask again.
    static func warm() {
        bundleLock.lock()
        guard bundleCache == nil, !warmInFlight else { bundleLock.unlock(); return }
        warmInFlight = true
        bundleLock.unlock()

        let result = readBundle(interactive: false)

        // "No item under our service" is also what a first launch after the
        // rename looks like, so the old service is checked before we conclude
        // there are no keys. Deliberately outside the lock — the carry-over may
        // put an authorization dialog on screen — and `warmInFlight` is still
        // set, so no concurrent warm can raise a second dialog.
        var carried: [String: String]?
        if case .missing = result { carried = carryOverLegacyService() }

        bundleLock.lock()
        warmInFlight = false
        if let carried {
            bundleCache = carried
            bundleLock.unlock()
            DispatchQueue.main.async { notifyChange(invalidateCache: false) }
            return
        }
        switch result {
        case .success(let bundle):
            bundleCache = bundle
            bundleLock.unlock()
            // Republish now that the cache is real: every sync accessor
            // answered "no key" while cold, so UI computed from them (the
            // panel's provider switcher) is stale until told otherwise.
            // The ACL-repair path below always posted; this silent-success
            // path never did — with a STABLE signing identity (no repair on
            // relaunch) that left the switcher hidden after every launch.
            DispatchQueue.main.async { notifyChange(invalidateCache: false) }
        case .missing:
            let migrated = migrateLegacyLocked()
            bundleCache = migrated
            bundleLock.unlock()
            DispatchQueue.main.async { notifyChange(invalidateCache: false) }
        case .locked:
            bundleLock.unlock()
            Diagnostics.log("keys", "keychain needs authorization — asking in the background")
            authorizeAndRepair()
        }
    }

    /// Schedules `warm()` on a background queue. Safe to call from anywhere,
    /// including a SwiftUI body.
    static func warmInBackground() {
        bundleLock.lock()
        let needed = bundleCache == nil && !warmInFlight && !repairInFlight
        bundleLock.unlock()
        guard needed else { return }
        DispatchQueue.global(qos: .userInitiated).async { warm() }
    }

    /// Awaits a warm cache without ever touching the Keychain on the caller's
    /// thread — for request paths that must actually have the key in hand
    /// (chat turn, transcription, OCR).
    static func warmIfNeeded() async {
        if isWarm { return }
        // A GCD queue, not `Task.detached`: the module defaults to MainActor
        // isolation, and a detached task's closure was still resumed ON the
        // main thread — which put the blocking read right back where it hung
        // (confirmed by a watchdog report against this very code).
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                warm()
                continuation.resume()
            }
        }
    }

    /// Asks for authorization once (off the main thread) and, on success,
    /// rewrites the item so its ACL is rebuilt around the running binary.
    private static func authorizeAndRepair() {
        bundleLock.lock()
        guard bundleCache == nil, !repairInFlight else { bundleLock.unlock(); return }
        repairInFlight = true
        bundleLock.unlock()

        // Blocks on the system dialog — which is exactly why this must never
        // run on the main thread.
        let result = readBundle(interactive: true)

        bundleLock.lock()
        repairInFlight = false
        guard case .success(let bundle) = result else {
            bundleLock.unlock()
            Diagnostics.log("keys", "keychain authorization declined — keys unavailable this session")
            return
        }
        bundleCache = bundle
        // A fresh delete+add from this binary re-creates the item's ACL around
        // the current signature: the one dialog above is the last one.
        let rewritten = saveBundleLocked(bundle)
        bundleLock.unlock()

        Diagnostics.log("keys", "keychain authorized — acl rebuilt=\(rewritten)")
        DispatchQueue.main.async { notifyChange(invalidateCache: false) }
    }

    // MARK: - Bundle storage

    private enum BundleRead {
        case success([String: String])
        case missing
        case locked
    }

    private static func readBundle(interactive: Bool) -> BundleRead {
        switch KeychainHelper.read(service: service, account: bundleAccount, interactive: interactive) {
        case .success(let data):
            guard let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
                return .missing
            }
            return .success(dict)
        case .notFound:
            return .missing
        case .interactionRequired:
            return .locked
        case .failure(let status):
            Diagnostics.log("keys", "keychain read failed status=\(status)")
            return .missing
        }
    }

    /// Moves the key bundle written by a pre-rename build onto the current
    /// service. The old item's ACL was built around the old bundle identifier
    /// and signature, so the first read after the rename needs the user to
    /// allow it once — hence the interactive retry, and hence the requirement
    /// that this runs off the main thread and outside `bundleLock`.
    ///
    /// Returns nil when there is nothing to carry over, so the caller falls
    /// through to the ordinary pre-bundle migration.
    private static func carryOverLegacyService() -> [String: String]? {
        guard !UserDefaults.standard.bool(forKey: renameCarryOverFlag) else { return nil }

        var read = KeychainHelper.read(service: legacyService, account: bundleAccount)
        if case .interactionRequired = read {
            Diagnostics.log("keys", "pre-rename keychain item needs authorization — asking")
            read = KeychainHelper.read(service: legacyService, account: bundleAccount, interactive: true)
        }

        guard case .success(let data) = read,
              let bundle = try? JSONDecoder().decode([String: String].self, from: data),
              !bundle.isEmpty
        else {
            // Give up permanently only when the item is known not to exist —
            // a declined dialog or a transient failure is retried next launch.
            if case .notFound = read {
                UserDefaults.standard.set(true, forKey: renameCarryOverFlag)
            }
            return nil
        }

        bundleLock.lock()
        let saved = saveBundleLocked(bundle)
        bundleLock.unlock()
        // Keep the old item and the flag unset if the write failed: the keys
        // are usable this session and the move is retried on the next launch.
        guard saved else { return bundle }

        KeychainHelper.delete(service: legacyService, account: bundleAccount)
        UserDefaults.standard.set(true, forKey: renameCarryOverFlag)
        Diagnostics.log("keys", "carried \(bundle.count) key(s) over from the pre-rename keychain service")
        return bundle
    }

    /// Folds the pre-bundle per-key items into one bundle item. Reads stay
    /// non-interactive: a legacy item we cannot read without a dialog is left
    /// alone and retried on a later launch. Caller must hold `bundleLock`.
    private static func migrateLegacyLocked() -> [String: String] {
        guard !UserDefaults.standard.bool(forKey: migrationFlag) else { return [:] }
        var migrated: [String: String] = [:]
        for account in legacyAccounts {
            if case .success(let data) = KeychainHelper.read(service: service, account: account),
               let key = String(data: data, encoding: .utf8), !key.isEmpty {
                migrated[account] = key
            }
        }
        if migrated.isEmpty {
            UserDefaults.standard.set(true, forKey: migrationFlag)
            return [:]
        }
        guard saveBundleLocked(migrated) else {
            return migrated // keep legacy items; retried on the next access
        }
        for account in legacyAccounts {
            KeychainHelper.delete(service: service, account: account)
        }
        UserDefaults.standard.set(true, forKey: migrationFlag)
        Diagnostics.log("keys", "migrated \(migrated.count) key(s) into the keychain bundle")
        return migrated
    }

    /// Caller must hold `bundleLock`.
    @discardableResult
    private static func saveBundleLocked(_ bundle: [String: String]) -> Bool {
        guard let data = try? JSONEncoder().encode(bundle) else { return false }
        return KeychainHelper.save(service: service, account: bundleAccount, data: data)
    }

    /// Cache-only read. SwiftUI bodies call this per evaluation, so it must
    /// never wait on securityd: a cold cache reports "no key" and schedules a
    /// background warm that republishes (`apiKeysDidChange`) when it lands.
    private static func value(account: String) -> String? {
        bundleLock.lock()
        let cached = bundleCache
        bundleLock.unlock()
        guard let cached else {
            warmInBackground()
            return nil
        }
        guard let key = cached[account], !key.isEmpty else { return nil }
        return key
    }

    /// Sets (or, with nil, removes) one key inside the bundle.
    private static func setValue(_ newValue: String?, account: String) -> Bool {
        bundleLock.lock()
        defer { bundleLock.unlock() }
        if bundleCache == nil {
            // An authorization dialog is up: its read holds the interaction
            // lock, and waiting for it here would block whoever is saving
            // (Settings, i.e. the main thread).
            guard !repairInFlight else { return false }
            switch readBundle(interactive: false) {
            case .success(let bundle):
                bundleCache = bundle
            case .missing:
                bundleCache = migrateLegacyLocked()
            case .locked:
                // Merging into a bundle we cannot read would drop every other
                // provider's key, and asking here would block the UI. The
                // launch-time repair owns that case.
                return false
            }
        }
        var bundle = bundleCache ?? [:]
        if let newValue {
            bundle[account] = newValue
        } else {
            bundle.removeValue(forKey: account)
        }
        guard saveBundleLocked(bundle) else { return false }
        bundleCache = bundle
        return true
    }

    // MARK: - Accessors

    static func key(for provider: ProviderID) -> String? {
        value(account: provider.rawValue)
    }

    @discardableResult
    static func set(_ key: String, for provider: ProviderID) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let ok = setValue(trimmed, account: provider.rawValue)
        if ok { notifyChange() }
        return ok
    }

    @discardableResult
    static func remove(for provider: ProviderID) -> Bool {
        let ok = setValue(nil, account: provider.rawValue)
        if ok { notifyChange() }
        return ok
    }

    static func hasKey(for provider: ProviderID) -> Bool {
        key(for: provider) != nil
    }

    static func hasKey(aux: AuxKey) -> Bool {
        key(aux: aux) != nil
    }

    /// Masked representation for the UI, e.g. "••••••••1a2b". Never expose the full key.
    static func maskedKey(for provider: ProviderID) -> String? {
        guard let key = key(for: provider) else { return nil }
        let suffix = key.count > 4 ? String(key.suffix(4)) : ""
        return "••••••••" + suffix
    }

    /// `invalidateCache: false` is for the authorization repair, which has just
    /// FILLED the cache — dropping it there would send the app straight back to
    /// the Keychain.
    private static func notifyChange(invalidateCache: Bool = true) {
        if invalidateCache {
            bundleLock.withLock { bundleCache = nil }
            warmInBackground()
        }
        NotificationCenter.default.post(name: .apiKeysDidChange, object: nil)
    }

    // MARK: - Auxiliary keys (non-chat services)

    enum AuxKey: String, CaseIterable {
        case brave
        case deepgram
        case fal // ImageAddon (Addons/ImageAddon)
        case hermes // HermesAddon gateway token (Addons/HermesAddon)
        case hermesDashboard // HermesAddon dashboard session token (remote files)

        var displayName: String {
            switch self {
            case .brave: return "Brave Search"
            case .deepgram: return "Deepgram"
            case .fal: return "fal.ai"
            case .hermes: return "Hermes Agent"
            case .hermesDashboard: return "Hermes Dashboard"
            }
        }
    }

    static func key(aux: AuxKey) -> String? {
        value(account: "aux." + aux.rawValue)
    }

    @discardableResult
    static func set(_ key: String, aux: AuxKey) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let ok = setValue(trimmed, account: "aux." + aux.rawValue)
        if ok { notifyChange() }
        return ok
    }

    @discardableResult
    static func remove(aux: AuxKey) -> Bool {
        let ok = setValue(nil, account: "aux." + aux.rawValue)
        if ok { notifyChange() }
        return ok
    }

    static func maskedKey(aux: AuxKey) -> String? {
        guard let key = key(aux: aux) else { return nil }
        let suffix = key.count > 4 ? String(key.suffix(4)) : ""
        return "••••••••" + suffix
    }
}

extension Notification.Name {
    /// `nonisolated`: posted from APIKeyStore's off-main warm/repair path.
    nonisolated static let apiKeysDidChange = Notification.Name("apiKeysDidChange")
    static let panelPositionDidReset = Notification.Name("panelPositionDidReset")
    static let showOnboarding = Notification.Name("showOnboarding")
    static let selectSettingsTab = Notification.Name("selectSettingsTab")
    /// Opens the Settings window from anywhere (AppDelegate listens).
    static let openSettingsWindow = Notification.Name("openSettingsWindow")
    /// Deep link past the tab level: switches Settings to the API Keys tab,
    /// scrolls to the speech-to-text key section and flashes it. Posted by the
    /// composer's mic button when no STT provider has a key.
    static let revealSpeechKeySection = Notification.Name("revealSpeechKeySection")
}
