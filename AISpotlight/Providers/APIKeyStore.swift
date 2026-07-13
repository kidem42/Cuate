import Foundation

/// Secure storage for provider API keys.
///
/// Security model:
/// - Keys live exclusively in the macOS Keychain (device-only, non-syncing —
///   see `KeychainHelper.save`), never in `UserDefaults`, files, or logs.
/// - Keys are read from the Keychain at request time and are not cached in
///   observable app state; the UI only ever sees a masked representation.
enum APIKeyStore {
    private static let service = "org.topassistant.AISpotlight.apikeys"

    static func key(for provider: ProviderID) -> String? {
        guard let data = KeychainHelper.load(service: service, account: provider.rawValue),
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else { return nil }
        return key
    }

    @discardableResult
    static func set(_ key: String, for provider: ProviderID) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return false }
        let ok = KeychainHelper.save(service: service, account: provider.rawValue, data: data)
        if ok { notifyChange() }
        return ok
    }

    @discardableResult
    static func remove(for provider: ProviderID) -> Bool {
        let ok = KeychainHelper.delete(service: service, account: provider.rawValue)
        if ok { notifyChange() }
        return ok
    }

    static func hasKey(for provider: ProviderID) -> Bool {
        key(for: provider) != nil
    }

    /// Masked representation for the UI, e.g. "••••••••1a2b". Never expose the full key.
    static func maskedKey(for provider: ProviderID) -> String? {
        guard let key = key(for: provider) else { return nil }
        let suffix = key.count > 4 ? String(key.suffix(4)) : ""
        return "••••••••" + suffix
    }

    private static func notifyChange() {
        NotificationCenter.default.post(name: .apiKeysDidChange, object: nil)
    }

    // MARK: - Auxiliary keys (non-chat services)

    enum AuxKey: String, CaseIterable {
        case brave

        var displayName: String {
            switch self {
            case .brave: return "Brave Search"
            }
        }
    }

    static func key(aux: AuxKey) -> String? {
        guard let data = KeychainHelper.load(service: service, account: "aux." + aux.rawValue),
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else { return nil }
        return key
    }

    @discardableResult
    static func set(_ key: String, aux: AuxKey) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return false }
        let ok = KeychainHelper.save(service: service, account: "aux." + aux.rawValue, data: data)
        if ok { notifyChange() }
        return ok
    }

    @discardableResult
    static func remove(aux: AuxKey) -> Bool {
        let ok = KeychainHelper.delete(service: service, account: "aux." + aux.rawValue)
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
