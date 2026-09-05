import Foundation

/// What a provider can take from the user, in one localized tooltip: images,
/// tools, and — since 4.17 — documents, which differ by provider more than
/// anything else (OpenAI reads them natively through its Files API; everyone
/// else gets the text extracted on this Mac). Shown on the key rows and next
/// to the chat provider picker.
enum ProviderCapabilityHints {
    /// One line per capability, newline-separated (tooltips render them as is).
    static func summary(for provider: ProviderID) -> String {
        var lines: [String] = []
        lines.append(L(documentsKey(for: provider)))
        lines.append(L(provider.supportsVision ? "cap.images.yes" : "cap.images.ocr"))
        lines.append(L(provider == .openrouter || provider == .ollama ? "cap.tools.perModel" : "cap.tools.yes"))
        return lines.joined(separator: "\n")
    }

    /// The documents line alone — the caption under the chat provider picker.
    static func documentsLine(for provider: ProviderID) -> String {
        L(documentsKey(for: provider))
    }

    private static func documentsKey(for provider: ProviderID) -> String {
        switch provider {
        case .openai: return "cap.documents.native"
        case .openrouter: return "cap.documents.openrouter"
        default: return "cap.documents.text"
        }
    }
}
