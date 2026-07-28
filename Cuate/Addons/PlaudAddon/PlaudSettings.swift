import Foundation
import Combine

extension Notification.Name {
    /// Posted when the addon's enable flag or connection state changes (the
    /// host refreshes UI that gates on it).
    static let plaudAddonDidChange = Notification.Name("plaudAddonDidChange")
}

/// Persisted settings for the PlaudAddon. Own `UserDefaults` keys (prefix
/// `plaudAddon.`), fully self-contained (pattern: `CalendarSettings`).
/// The OAuth tokens are NOT here — they live in the Keychain.
@MainActor
final class PlaudSettings: ObservableObject {
    static let shared = PlaudSettings()

    private let defaults = UserDefaults.standard

    // MARK: - Master switch

    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "plaudAddon.enabled")
            NotificationCenter.default.post(name: .plaudAddonDidChange, object: nil)
        }
    }

    // MARK: - Exposure

    /// When true (default) the tools ride along in every chat turn and the
    /// model reaches for them on its own ("что решили на встрече?", voice
    /// messages mentioning Plaud). When false the notes stay invisible until
    /// the user explicitly invokes /plaud — the privacy-lean mode.
    @Published var alwaysAvailable: Bool {
        didSet { defaults.set(alwaysAvailable, forKey: "plaudAddon.alwaysAvailable") }
    }

    // MARK: - Connected account (display cache)

    /// Snapshot of `get_current_user` taken at connect time — settings UI
    /// only, never used for authorization decisions.
    @Published var accountName: String? {
        didSet { defaults.set(accountName, forKey: "plaudAddon.accountName") }
    }
    @Published var accountEmail: String? {
        didSet { defaults.set(accountEmail, forKey: "plaudAddon.accountEmail") }
    }
    @Published var accountAvatarURL: String? {
        didSet { defaults.set(accountAvatarURL, forKey: "plaudAddon.accountAvatarURL") }
    }

    /// The authorization URL of an OAuth flow in progress — surfaced in the
    /// settings UI as "copy the sign-in link" for users whose Plaud login
    /// lives in a non-default browser. Transient, never persisted.
    @Published var pendingAuthURL: URL?

    /// Mirrors Keychain token presence for SwiftUI observation — the source
    /// of truth stays `PlaudClient.hasTokens`; the addon updates this after
    /// connect/disconnect and on launch.
    @Published var isConnected: Bool = PlaudClient.hasTokens {
        didSet {
            if oldValue != isConnected {
                NotificationCenter.default.post(name: .plaudAddonDidChange, object: nil)
            }
        }
    }

    func setAccount(name: String?, email: String?, avatarURL: String?) {
        accountName = name
        accountEmail = email
        accountAvatarURL = avatarURL
    }

    func clearAccount() {
        accountName = nil
        accountEmail = nil
        accountAvatarURL = nil
    }

    // MARK: - Init

    private init() {
        enabled = defaults.bool(forKey: "plaudAddon.enabled")
        alwaysAvailable = defaults.object(forKey: "plaudAddon.alwaysAvailable") as? Bool ?? true
        accountName = defaults.string(forKey: "plaudAddon.accountName")
        accountEmail = defaults.string(forKey: "plaudAddon.accountEmail")
        accountAvatarURL = defaults.string(forKey: "plaudAddon.accountAvatarURL")
    }
}
