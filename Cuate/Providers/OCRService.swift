import Foundation

/// Routes OCR to the provider selected in Settings: Apple Vision (on-device,
/// free, default) or Mistral (cloud, layout-aware Markdown). Exposes the same
/// entry points the call sites already used for Mistral, so the "Extract Text"
/// action and the non-vision fallback go through here unchanged.
@MainActor
enum OCRService {
    /// Whether OCR can run with the current selection (Apple always can;
    /// Mistral needs its key).
    static var isAvailable: Bool {
        switch AppSettings.shared.ocrProvider {
        case .apple: return AppleOCRService.isAvailable
        case .mistral: return MistralOCRService.isAvailable
        }
    }

    /// Extracts text from a base64-encoded image using the selected provider.
    static func extractText(imageBase64: String, mimeType: String) async throws -> String {
        switch AppSettings.shared.ocrProvider {
        case .apple:
            guard let data = Data(base64Encoded: imageBase64) else {
                throw ProviderError.decoding("OCR: bad image data")
            }
            let languages = recognitionLanguages()
            // Vision is synchronous/ANE-bound — keep it off the main actor.
            return try await Task.detached(priority: .userInitiated) {
                try AppleOCRService.recognize(imageData: data, languages: languages)
            }.value
        case .mistral:
            return try await MistralOCRService.extractText(imageBase64: imageBase64, mimeType: mimeType)
        }
    }

    /// Recognition languages in priority order: the UI language first, then
    /// English as a fallback (covers mixed-language screenshots).
    private static func recognitionLanguages() -> [String] {
        let primary: String
        switch Localization.currentLanguage {
        case .russian: primary = "ru-RU"
        case .spanish: primary = "es-ES"
        default: primary = "en-US"
        }
        return primary == "en-US" ? [primary] : [primary, "en-US"]
    }
}
