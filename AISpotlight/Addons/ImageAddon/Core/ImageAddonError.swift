import Foundation

/// Errors of the ImageAddon pipeline. Localized through the addon's own
/// `IAL()` table so the host `L()` table stays untouched.
enum ImageAddonError: LocalizedError {
    /// No fal.ai key in the Keychain.
    case missingKey
    /// The input bytes could not be decoded as an image (or converted to PNG).
    case unreadableInput
    /// Another operation is already running (the runner is single-flight).
    case busy
    /// Provider rejected the image (content filter).
    case contentFiltered
    /// HTTP-level failure, sanitized message included.
    case http(status: Int, message: String)
    /// The queue job did not finish within the deadline.
    case timeout
    /// Anything that doesn't decode the way the provider documented.
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return IAL("ia.error.missingKey")
        case .unreadableInput:
            return IAL("ia.error.unreadableInput")
        case .busy:
            return IAL("ia.error.busy")
        case .contentFiltered:
            return IAL("ia.error.contentFiltered")
        case .http(let status, let message):
            return String(format: IAL("ia.error.http"), status, message)
        case .timeout:
            return IAL("ia.error.timeout")
        case .badResponse:
            return IAL("ia.error.badResponse")
        }
    }

    /// Builds an HTTP error with a compact, human-readable message —
    /// same sanitizing idea as the host `ProviderError.fromHTTP`.
    static func fromHTTP(status: Int, body: Data) -> ImageAddonError {
        var message = ""
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let detail = json["detail"] as? String {
                message = detail
            } else if let details = json["detail"] as? [[String: Any]] {
                // fal validation errors: [{"loc": …, "msg": …, "type": …}]
                message = details.compactMap { $0["msg"] as? String }.joined(separator: "; ")
            } else if let error = json["error"] as? [String: Any], let msg = error["message"] as? String {
                message = msg
            } else if let msg = json["message"] as? String {
                message = msg
            }
        }
        if message.isEmpty, let text = String(data: body, encoding: .utf8), !text.isEmpty {
            message = text
        }
        if message.count > 300 {
            message = String(message.prefix(300)) + "…"
        }
        return .http(status: status, message: message)
    }
}
