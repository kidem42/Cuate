import Foundation

/// Secure storage for provider API keys.
///
/// Security model:
/// - Keys live exclusively in the macOS Keychain (device-only, non-syncing —
///   see `KeychainHelper.save`), never in `UserDefaults`, files, or logs.
/// - Keys are read from the Keychain at request time and are not cached in
///   observable app state; the UI only ever sees a masked representation.
///
/// Storage layout: ALL keys live in ONE keychain item (a JSON dictionary
/// keyed by the account names below). Keychain ACLs pin each item to the
/// exact signing identity, and with a self-signed certificate (no Team ID)
/// the partition check re-prompts PER ITEM after every app update — one
/// bundle item caps that at a single password prompt instead of seven.
/// Pre-bundle per-key items are migrated in once (`migrationFlag`).
enum APIKeyStore {
    private static let service = "org.topassistant.AISpotlight.apikeys"
    /// Account of the single JSON-bundle item holding every key.
    private static let bundleAccount = "bundle"
    /// Set once the legacy per-key items have been folded into the bundle,
    /// so fresh installs never scan (and possibly prompt for) legacy items.
    private static let migrationFlag = "apiKeysMigratedToBundle"

    /// Accounts used by the pre-bundle layout (one keychain item each).
    private static var legacyAccounts: [String] {
        ProviderID.allCases.map(\.rawValue) + AuxKey.allCases.map { "aux." + $0.rawValue }
    }

    /// Serializes bundle read-modify-write cycles.
    private static let bundleLock = NSLock()

    // MARK: - Bundle storage

    /// Loads the bundle; if it doesn't exist yet, performs the one-time
    /// migration of legacy per-key items. Caller must hold `bundleLock`.
    private static func loadBundleLocked() -> [String: String] {
        if let data = KeychainHelper.load(service: service, account: bundleAccount),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            return dict
        }

        // No bundle yet — fold the legacy items in (may prompt once per item
        // on an updated build; this is the last time that can happen).
        guard !UserDefaults.standard.bool(forKey: migrationFlag) else { return [:] }
        var migrated: [String: String] = [:]
        for account in legacyAccounts {
            if let data = KeychainHelper.load(service: service, account: account),
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

    private static func value(account: String) -> String? {
        bundleLock.lock()
        defer { bundleLock.unlock() }
        guard let key = loadBundleLocked()[account], !key.isEmpty else { return nil }
        return key
    }

    /// Sets (or, with nil, removes) one key inside the bundle.
    private static func setValue(_ newValue: String?, account: String) -> Bool {
        bundleLock.lock()
        defer { bundleLock.unlock() }
        var bundle = loadBundleLocked()
        if let newValue {
            bundle[account] = newValue
        } else {
            bundle.removeValue(forKey: account)
        }
        return saveBundleLocked(bundle)
    }

    /// In-memory presence cache. SwiftUI bodies check key presence on every
    /// render (e.g. per streamed token), and each Keychain round-trip is a
    /// securityd IPC that can even block on an ACL prompt — reading the
    /// Keychain from the render path froze the app for some users. Presence
    /// is cached until any key changes; full key values are never cached.
    private static var presenceCache: [String: Bool] = [:]
    private static let presenceLock = NSLock()

    private static func cachedPresence(_ account: String, compute: () -> Bool) -> Bool {
        presenceLock.lock()
        if let hit = presenceCache[account] {
            presenceLock.unlock()
            return hit
        }
        presenceLock.unlock()
        let value = compute()
        presenceLock.lock()
        presenceCache[account] = value
        presenceLock.unlock()
        return value
    }

    private static func invalidatePresenceCache() {
        presenceLock.lock()
        presenceCache.removeAll()
        presenceLock.unlock()
    }

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
        cachedPresence(provider.rawValue) { key(for: provider) != nil }
    }

    static func hasKey(aux: AuxKey) -> Bool {
        cachedPresence("aux." + aux.rawValue) { key(aux: aux) != nil }
    }

    /// Masked representation for the UI, e.g. "••••••••1a2b". Never expose the full key.
    static func maskedKey(for provider: ProviderID) -> String? {
        guard let key = key(for: provider) else { return nil }
        let suffix = key.count > 4 ? String(key.suffix(4)) : ""
        return "••••••••" + suffix
    }

    private static func notifyChange() {
        invalidatePresenceCache()
        NotificationCenter.default.post(name: .apiKeysDidChange, object: nil)
    }

    // MARK: - Auxiliary keys (non-chat services)

    enum AuxKey: String, CaseIterable {
        case brave
        case deepgram

        var displayName: String {
            switch self {
            case .brave: return "Brave Search"
            case .deepgram: return "Deepgram"
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
    static let apiKeysDidChange = Notification.Name("apiKeysDidChange")
    static let panelPositionDidReset = Notification.Name("panelPositionDidReset")
    static let showOnboarding = Notification.Name("showOnboarding")
    static let selectSettingsTab = Notification.Name("selectSettingsTab")
}
