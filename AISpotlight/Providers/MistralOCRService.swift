import Foundation

/// Mistral OCR — extracts structured markdown from images (and PDFs).
/// Used for the "Extract Text" action on screenshots and as a fallback that
/// lets non-vision chat providers (DeepSeek) receive image content as text.
enum MistralOCRService {
    private static let endpoint = URL(string: "https://api.mistral.ai/v1/ocr")!

    static var isAvailable: Bool {
        APIKeyStore.hasKey(for: .mistral)
    }

    /// Runs OCR on a base64-encoded image and returns the extracted markdown.
    @MainActor
    static func extractText(imageBase64: String, mimeType: String) async throws -> String {
        guard let apiKey = APIKeyStore.key(for: .mistral) else {
            throw ProviderError.missingAPIKey(.mistral)
        }
        let model = AppSettings.shared.ocrModel

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": model,
            "document": [
                "type": "image_url",
                "image_url": "data:\(mimeType);base64,\(imageBase64)"
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await HTTPClient.json(request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pages = json["pages"] as? [[String: Any]] else {
            throw ProviderError.decoding("no `pages` in OCR response")
        }

        // Billed per page — record actual page count (Apple OCR is free and
        // never reaches this service).
        let pageCount = Double(max(1, pages.count))
        SpendStore.shared.record(
            kind: .ocr, provider: ProviderID.mistral.rawValue, model: model,
            units: pageCount,
            costUSD: PricingCatalog.ocrPerPage[.mistral].map { $0 * pageCount }
        )

        let markdown = pages
            .compactMap { $0["markdown"] as? String }
            .joined(separator: "\n\n")

        let cleaned = stripImageReferences(from: markdown)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else {
            throw ProviderError.decoding("OCR returned no text")
        }
        return cleaned
    }

    /// OCR output embeds image placeholders like `![img-0.jpeg](img-0.jpeg)` —
    /// meaningless outside the OCR container, so remove them.
    private static func stripImageReferences(from markdown: String) -> String {
        var result = markdown
        if let regex = try? NSRegularExpression(pattern: "!\\[[^\\]]*\\]\\([^)]*\\)") {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }
        // Collapse the blank lines left behind
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return result
    }
}
