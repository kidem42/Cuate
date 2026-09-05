import Foundation

// Contract test for the document attachment pre-flight and the read_document
// text queries. Compiled STANDALONE with the two pure files — no app target:
//   swiftc DocumentPreflight.swift DocumentTextQuery.swift DocumentContractTest.swift -o test
// Run via scripts/test-attach-note.sh.

nonisolated(unsafe) var failures = 0
func check(_ condition: Bool, _ label: String) {
    if condition { print("  ok   \(label)") } else { failures += 1; print("  FAIL \(label)") }
}

@main
struct DocumentContractTest {
    static func main() {

    print("== pre-flight ==")
    let mb = 1024 * 1024
    check(DocumentPreflight.check(ext: "pdf", bytes: 10 * mb, isEncrypted: false, pendingDocumentCount: 0, pendingDocumentBytes: 0) == .accepted, "pdf accepted")
    check(DocumentPreflight.check(ext: "DOCX", bytes: 100, isEncrypted: false, pendingDocumentCount: 2, pendingDocumentBytes: 0) == .accepted, "extension case-insensitive, third document accepted")
    check(DocumentPreflight.check(ext: "docx", bytes: 100, isEncrypted: false, pendingDocumentCount: 3, pendingDocumentBytes: 0) == .tooManyDocuments(limit: 3), "fourth document refused")
    check(DocumentPreflight.check(ext: "exe", bytes: 100, isEncrypted: false, pendingDocumentCount: 0, pendingDocumentBytes: 0) == .unsupportedType(ext: "exe"), "unsupported type")
    check(DocumentPreflight.check(ext: "png", bytes: 100, isEncrypted: false, pendingDocumentCount: 0, pendingDocumentBytes: 0) == .unsupportedType(ext: "png"), "images are not documents")
    check(DocumentPreflight.check(ext: "pdf", bytes: 0, isEncrypted: false, pendingDocumentCount: 0, pendingDocumentBytes: 0) == .emptyFile, "empty file")
    check(DocumentPreflight.check(ext: "pdf", bytes: 100, isEncrypted: true, pendingDocumentCount: 0, pendingDocumentBytes: 0) == .encrypted, "encrypted pdf")
    check(DocumentPreflight.check(ext: "pdf", bytes: 51 * mb, isEncrypted: false, pendingDocumentCount: 0, pendingDocumentBytes: 0) == .fileTooLarge(limitBytes: 50 * mb), "single file over 50 MB")
    check(DocumentPreflight.check(ext: "pdf", bytes: 30 * mb, isEncrypted: false, pendingDocumentCount: 1, pendingDocumentBytes: 25 * mb) == .messageTooLarge(limitBytes: 50 * mb), "combined over 50 MB")
    check(DocumentPreflight.isDocumentMime("application/pdf") && !DocumentPreflight.isDocumentMime("image/png"), "mime classification")
    check(DocumentPreflight.isLocallyReadable(mime: "application/pdf") && !DocumentPreflight.isLocallyReadable(mime: DocumentPreflight.mimeType(forExtension: "xlsx")!), "local readability")
    check(DocumentPreflight.iconName(forFilename: "a.PDF") == "doc.richtext", "icon by extension")

    print("== page markers ==")
    let joined = DocumentTextQuery.join(pages: ["First page text.", "", "Third page.\n\nSecond paragraph."])
    let pages = DocumentTextQuery.pages(of: joined)
    check(pages.count == 3, "three pages round-trip (empty page kept)")
    check(pages[0] == "First page text." && pages[1] == "" && pages[2].hasPrefix("Third page."), "page contents preserved")
    check(DocumentTextQuery.pages(of: "plain text without markers").count == 1, "unmarked text is one page")

    print("== page ranges ==")
    check(DocumentTextQuery.parsePageRange("3-5", pageCount: 10) == 3...5, "3-5")
    check(DocumentTextQuery.parsePageRange("7", pageCount: 10) == 7...7, "single page")
    check(DocumentTextQuery.parsePageRange(" 2 – 4 ", pageCount: 10) == 2...4, "spaces and en dash")
    check(DocumentTextQuery.parsePageRange("8-20", pageCount: 10) == 8...10, "clamped to the last page")
    check(DocumentTextQuery.parsePageRange("12", pageCount: 10) == nil, "start past the end")
    check(DocumentTextQuery.parsePageRange("abc", pageCount: 10) == nil, "garbage")
    check(DocumentTextQuery.parsePageRange(nil, pageCount: 10) == nil, "nil")

    print("== search ==")
    let hits = DocumentTextQuery.search(joined, query: "PAGE")
    check(hits.count == 2 && hits[0].page == 1 && hits[1].page == 3, "case-insensitive hits with page numbers")
    check(DocumentTextQuery.search(joined, query: "   ").isEmpty, "blank query → no hits")

    print("== rendering ==")
    let whole = DocumentTextQuery.render(name: "a.pdf", text: joined, pageRange: nil, query: nil)
    check(whole.hasPrefix("a.pdf — 3 pages") && whole.contains("[Page 3]"), "whole document with header")
    let ranged = DocumentTextQuery.render(name: "a.pdf", text: joined, pageRange: "3", query: nil)
    check(ranged.contains("pages 3-3") && ranged.contains("Third page.") && !ranged.contains("First page"), "page range")
    check(DocumentTextQuery.render(name: "a.pdf", text: joined, pageRange: "99", query: nil).contains("Invalid page range"), "invalid range message")
    let queried = DocumentTextQuery.render(name: "a.pdf", text: joined, pageRange: nil, query: "second")
    check(queried.contains("1 match") && queried.contains("Page 3:"), "query result")
    check(DocumentTextQuery.render(name: "a.pdf", text: joined, pageRange: nil, query: "zzz").contains("No matches"), "no matches message")
    let long = String(repeating: "word ", count: 20_000)
    let capped = DocumentTextQuery.capped(long)
    check(capped.count <= DocumentTextQuery.maxResultCharacters + DocumentTextQuery.truncationNote.count + 1 && capped.hasSuffix(DocumentTextQuery.truncationNote), "cap with note")
    check(DocumentTextQuery.capped("short") == "short", "short text untouched")

    if failures > 0 {
        print("\(failures) failure(s)")
        exit(1)
    }
    print("all green")
    }
}
