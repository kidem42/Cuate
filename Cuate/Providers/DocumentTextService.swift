import Foundation
import AppKit
import PDFKit

/// Local text extraction for document attachments — the data source of the
/// read_document tool and of the attach-turn text for providers without a
/// native document input. Everything runs on the Mac: PDFKit for the text
/// layer, Apple Vision for scanned pages, AppKit for Word/RTF. No cloud OCR
/// for documents, by decision.
nonisolated enum DocumentTextService {
    struct PDFInfo {
        let pageCount: Int
        /// Needs a password — the pre-flight refuses these.
        let isLocked: Bool
    }

    /// Longest side of a page rendered for OCR. Vision handles 2,000 px
    /// comfortably; a letter page at 150 dpi is ~1,650 px tall.
    private static let ocrMaxPixels: CGFloat = 2000

    static func pdfInfo(data: Data) -> PDFInfo? {
        guard let document = PDFDocument(data: data) else { return nil }
        return PDFInfo(pageCount: document.pageCount, isLocked: document.isLocked)
    }

    /// Text with page markers (`DocumentTextQuery.pageMarker`), or nil when the
    /// type can't be read locally or nothing readable was found. `ocrLanguages`
    /// are resolved by the caller on the main actor (see `ocrLanguages()`).
    static func extract(data: Data, mimeType: String, ocrLanguages: [String]) async -> String? {
        let mime = mimeType.lowercased()
        guard DocumentPreflight.isLocallyReadable(mime: mime) else { return nil }
        switch mime {
        case "application/pdf":
            // PDFKit parsing and Vision are CPU-bound — off the main actor,
            // the same way OCRService runs Vision for screenshots.
            return await Task.detached(priority: .userInitiated) {
                extractPDF(data: data, ocrLanguages: ocrLanguages)
            }.value
        case "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
             "application/msword",
             "application/rtf":
            // AppKit's document readers belong to the main thread.
            return await MainActor.run { extractAttributed(data: data, mime: mime) }
        default:
            return extractPlainText(data: data)
        }
    }

    /// Recognition languages for scanned pages: the UI language first, then
    /// English (mixed-language documents are the norm).
    @MainActor
    static func ocrLanguages() -> [String] {
        let primary: String
        switch Localization.currentLanguage {
        case .russian: primary = "ru-RU"
        case .spanish: primary = "es-ES"
        default: primary = "en-US"
        }
        return primary == "en-US" ? [primary] : [primary, "en-US"]
    }

    // MARK: - PDF

    private static func extractPDF(data: Data, ocrLanguages: [String]) -> String? {
        guard let document = PDFDocument(data: data), !document.isLocked, document.pageCount > 0 else {
            return nil
        }
        var pages: [String] = []
        var readable = false
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else {
                pages.append("")
                continue
            }
            let layer = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !layer.isEmpty {
                pages.append(layer)
                readable = true
                continue
            }
            // No text layer: render and recognize on-device.
            if let recognized = ocrPage(page, languages: ocrLanguages), !recognized.isEmpty {
                pages.append(recognized)
                readable = true
            } else {
                pages.append("")
            }
        }
        guard readable else { return nil }
        return DocumentTextQuery.join(pages: pages)
    }

    private static func ocrPage(_ page: PDFPage, languages: [String]) -> String? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(ocrMaxPixels / max(bounds.width, bounds.height), 150.0 / 72.0)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let image = page.thumbnail(of: size, for: .mediaBox)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return try? AppleOCRService.recognize(imageData: png, languages: languages)
    }

    // MARK: - Word / RTF

    @MainActor
    private static func extractAttributed(data: Data, mime: String) -> String? {
        let type: NSAttributedString.DocumentType
        switch mime {
        case "application/msword": type = .docFormat
        case "application/rtf": type = .rtf
        default: type = .officeOpenXML
        }
        guard let attributed = try? NSAttributedString(
            data: data,
            options: [.documentType: type],
            documentAttributes: nil
        ) else { return nil }
        let text = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: - Plain text

    private static func extractPlainText(data: Data) -> String? {
        let decoded = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1)
        let text = decoded?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }
}
