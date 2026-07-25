import Foundation
import Security

nonisolated enum KeychainHelper {

    /// Outcome of a read. `interactionRequired` is the case that used to hang
    /// the app: the item's ACL no longer matches this binary (every update
    /// re-signs it), so securityd wants to put an authorization dialog on
    /// screen — and `SecItemCopyMatching` blocks until it is answered. Reads
    /// are non-interactive by default so that can never happen on a thread
    /// that must stay responsive; the caller decides when to ask for real.
    enum ReadResult {
        case success(Data)
        case notFound
        case interactionRequired
        case failure(OSStatus)
    }

    @discardableResult
    static func save(service: String, account: String, data: Data) -> Bool {
        delete(service: service, account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // Security: only readable while the Mac is unlocked, and never
            // synced to iCloud Keychain — secrets stay on this device.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    /// Serializes the process-global interaction switch below.
    private static let interactionLock = NSLock()

    /// Reads an item. `interactive: false` (the default) forbids securityd from
    /// showing any UI — a stale ACL then fails fast with `.interactionRequired`
    /// instead of blocking the calling thread indefinitely.
    /// `interactive: true` MUST only be called off the main thread.
    ///
    /// Suppressing the dialog needs the DEPRECATED switch: items added without
    /// `kSecUseDataProtectionKeychain` live in the legacy (file-based) keychain,
    /// whose `SecItemCopyMatching_osx` path ignores `kSecUseAuthenticationUI`
    /// and honors only the process-global `SecKeychainSetUserInteractionAllowed`
    /// — verified by sampling the blocked thread, which sat on the dialog with
    /// the modern key set.
    static func read(service: String, account: String, interactive: Bool = false) -> ReadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        interactionLock.lock()
        SecKeychainSetUserInteractionAllowed(interactive)
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        SecKeychainSetUserInteractionAllowed(true)
        interactionLock.unlock()
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return .failure(status) }
            return .success(data)
        case errSecItemNotFound:
            return .notFound
        // The legacy (file-based) keychain reports a suppressed ACL prompt as
        // errSecInteractionNotAllowed; errSecAuthFailed covers a dismissed one.
        case errSecInteractionNotAllowed, errSecInteractionRequired, errSecAuthFailed:
            return .interactionRequired
        default:
            return .failure(status)
        }
    }

    @discardableResult
    static func delete(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
