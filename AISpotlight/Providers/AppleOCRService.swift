import Foundation
import Vision
import AppKit

/// Native, on-device OCR via the Vision framework (`VNRecognizeTextRequest`).
/// No key, no network, no cost — runs on the Neural Engine. Recognizes plain
/// text (screenshots, photos) in many languages including Cyrillic, but returns
/// flat lines: it does NOT reconstruct document layout (tables, columns) the way
/// the cloud document model (`MistralOCRService`) does.
enum AppleOCRService {
    /// Always usable — no key required.
    static var isAvailable: Bool { true }

    /// Synchronous Vision OCR — call OFF the main actor (Vision's `perform`
    /// is CPU/ANE-bound). `languages` are BCP-47 tags in priority order.
    static func recognize(imageData: Data, languages: [String]) throws -> String {
        guard let cg = NSBitmapImageRep(data: imageData)?.cgImage else {
            throw ProviderError.decoding("OCR: could not read the image")
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if !languages.isEmpty { request.recognitionLanguages = languages }

        try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])

        let text = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else { throw ProviderError.decoding("OCR returned no text") }
        return text
    }
}
