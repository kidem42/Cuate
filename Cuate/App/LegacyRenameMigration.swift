import Foundation
import AppKit
import ServiceManagement

/// One-shot carry-over from the pre-rename identity to the current one.
///
/// The app used to be called AISpotlight and shipped as `kpn.AISpotlight`.
/// Three things the system keys off that old name survive an update, so an
/// otherwise silent rename would look to the user like a wiped install:
///
///   * `~/Library/Application Support/AISpotlight` — chats, spend ledger,
///     attached images, pricing cache
///   * the preferences domain, which is the bundle identifier verbatim — every
///     setting, hotkey and theme choice lives there
///   * the Keychain service holding the API keys (carried over separately, in
///     `APIKeyStore`, because that one may need an authorization dialog)
///
/// TCC grants — Accessibility, Screen Recording, Microphone — cannot be
/// carried over by anyone: they are bound to the bundle identifier and the code
/// signature, so the user re-grants them once after this update. That is the
/// one unavoidable cost of the rename.
///
/// Everything here is idempotent and does its work exactly once per process
/// (`once`), so calling `runIfNeeded()` from several places costs nothing.
/// Delete this file once no install predating the rename is left in the wild.
enum LegacyRenameMigration {
    private static let legacyBundleID = "kpn.AISpotlight"
    private static let legacyDirectoryName = "AISpotlight"
    private static let currentDirectoryName = "Cuate"
    private static let didRunFlag = "renamedFromAISpotlight"

    /// SwiftData store files, which are named after the app. SQLite keeps its
    /// journal in sidecar files next to the store — moving the `.store` alone
    /// strands the WAL and loses every write still held in it.
    private static let stores = [
        (old: "AISpotlightChats.store", new: "CuateChats.store"),
        (old: "AISpotlightSpend.store", new: "CuateSpend.store"),
    ]
    private static let storeSidecars = ["", "-shm", "-wal"]

    /// Swift runs a `static let` initializer exactly once, thread-safely, on
    /// first touch — which is precisely the guarantee this needs.
    private static let once: Void = perform()

    /// Must run before anything reads the data directory, the defaults or the
    /// Keychain. Safe to call from anywhere, any number of times.
    static func runIfNeeded() { _ = once }

    private static func perform() {
        guard !UserDefaults.standard.bool(forKey: didRunFlag) else { return }

        // An e2e run points persistence at a sandbox directory and starts from
        // nothing; there is no previous install to carry over.
        if let sandbox = ProcessInfo.processInfo.environment["CUATE_DATA_DIR"], !sandbox.isEmpty {
            UserDefaults.standard.set(true, forKey: didRunFlag)
            return
        }

        // The old build must not be running. Its SQLite stores are open, so
        // moving the directory out from under it leaves two processes writing
        // the same files, and it flushes its own (now stale) defaults when it
        // finally quits. Leave the flag unset and retry on a later launch.
        if !NSRunningApplication.runningApplications(withBundleIdentifier: legacyBundleID).isEmpty {
            Diagnostics.log("migration", "\(legacyBundleID) is still running — carry-over deferred")
            return
        }

        migrateDefaults()
        migrateLoginItem()
        migrateDataDirectory()
        UserDefaults.standard.set(true, forKey: didRunFlag)
    }

    // MARK: - Login item

    /// `SMAppService` registrations are keyed by bundle identifier, so the old
    /// app's login item does not follow the rename. Left alone, the setting
    /// reads back as off under the new identity while the OLD app keeps
    /// launching at login — so re-register when the carried-over setting says
    /// it was on. Removing the old registration is not possible from here;
    /// it goes away when the previous app bundle is deleted.
    private static func migrateLoginItem() {
        guard UserDefaults.standard.bool(forKey: "launchAtLogin"),
              SMAppService.mainApp.status != .enabled else { return }
        do {
            try SMAppService.mainApp.register()
            Diagnostics.log("migration", "login item re-registered under the new identity")
        } catch {
            Diagnostics.log("migration", "login item re-registration failed: \(error)")
        }
    }

    // MARK: - Preferences

    /// Copies the old preferences domain across key by key. `CFPreferences`
    /// rather than `UserDefaults(suiteName:)` because only the former reads a
    /// foreign domain without also folding in the global domain's contents.
    private static func migrateDefaults() {
        let domain = legacyBundleID as CFString
        guard let keys = CFPreferencesCopyKeyList(
            domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost
        ) as? [String], !keys.isEmpty else { return }

        let defaults = UserDefaults.standard
        // Compared against the PERSISTENT domain, not `object(forKey:)`: the
        // latter also answers out of the registration domain, so every setting
        // that has a built-in default would look "already present" and never
        // get carried over — silently resetting the system prompt, the active
        // preset and the webhook while appearing to succeed.
        let written = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        var carried = 0
        for key in keys {
            // Anything actually written under the new identity wins — a
            // migration must never overwrite live state.
            guard written[key] == nil else { continue }
            guard let value = CFPreferencesCopyValue(
                key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost
            ) else { continue }
            defaults.set(value, forKey: key)
            carried += 1
        }
        Diagnostics.log("migration", "carried \(carried) preference(s) over from \(legacyBundleID)")
    }

    // MARK: - Application Support

    private static func migrateDataDirectory() {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return }

        let old = support.appendingPathComponent(legacyDirectoryName, isDirectory: true)
        let new = support.appendingPathComponent(currentDirectoryName, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: old.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return }

        if fm.fileExists(atPath: new.path) {
            // `Diagnostics.logsDirectory` also lives under `Cuate/`, and opt-in
            // logging may well have created it before this ran — so merge
            // instead of giving up. Anything already at the new name wins.
            merge(from: old, into: new, fm: fm)
        } else {
            do {
                try fm.moveItem(at: old, to: new)
            } catch {
                Diagnostics.log("migration", "data directory move failed: \(error)")
                return
            }
        }

        renameStores(in: new, fm: fm)
        Diagnostics.log("migration", "data directory carried over from \(legacyDirectoryName)")
    }

    /// Moves the old directory's entries into the new one, then drops the old
    /// directory if nothing was left behind. Shallow on purpose: the only
    /// colliding entry in practice is `Logs/`, and stale logs are disposable.
    private static func merge(from old: URL, into new: URL, fm: FileManager) {
        let entries = (try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil)) ?? []
        for entry in entries {
            let target = new.appendingPathComponent(entry.lastPathComponent)
            guard !fm.fileExists(atPath: target.path) else { continue }
            try? fm.moveItem(at: entry, to: target)
        }
        let leftovers = (try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil)) ?? []
        if leftovers.isEmpty { try? fm.removeItem(at: old) }
    }

    private static func renameStores(in directory: URL, fm: FileManager) {
        for store in stores {
            for sidecar in storeSidecars {
                let from = directory.appendingPathComponent(store.old + sidecar)
                let to = directory.appendingPathComponent(store.new + sidecar)
                guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { continue }
                try? fm.moveItem(at: from, to: to)
            }
        }
    }
}
