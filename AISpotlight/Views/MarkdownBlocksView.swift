import SwiftUI

/// Block-level Markdown renderer for chat bubbles (Telegram-style):
/// paragraphs, **bold headings**, bullet lists, block quotes, fenced code
/// blocks with a monospaced card, and pipe tables rendered as a real grid.
/// Inline styling (bold/italic/links) inside every block is handled by
/// AttributedString + raw-URL linkification.
struct MarkdownBlocksView: View {
    let text: String
    let linkColor: Color
    /// `.chat` keeps the compact bubble typography; `.document` uses larger,
    /// Notion-like typography for the artifact preview window.
    var style: Style = .chat
    /// Whether the text is still being streamed in. An unterminated artifact
    /// fence means "generating" only while this is true; once the stream is
    /// over it renders as a finished (possibly truncated) card.
    var isStreaming: Bool = false
    @Environment(\.themePalette) private var palette

    enum Style {
        case chat
        case document
    }

    enum Block {
        case paragraph(String)
        case heading(level: Int, text: String)
        case bullets([String])
        case numbered([String])
        case tasks([(checked: Bool, text: String)])
        case quote(String)
        case code(content: String, language: String)
        case divider
        case table(rows: [[String]])
        /// A deliverable document (```html or ```markdown fence) rendered as an
        /// artifact card with a preview instead of a wall of code.
        /// `complete` is false while the fence is still streaming in.
        case artifact(kind: ArtifactKind, content: String, complete: Bool)
        /// A ```mermaid fence rendered inline as a native-looking diagram.
        case mermaid(code: String, complete: Bool)
    }

    private var isDocument: Bool { style == .document }

    var body: some View {
        let blocks = Self.parse(text)
        VStack(alignment: .leading, spacing: isDocument ? 10 : 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                render(block)
            }
        }
        .font(isDocument ? .system(size: 14) : nil)
    }

    // MARK: - Block rendering

    @ViewBuilder
    private func render(_ block: Block) -> some View {
        switch block {
        case .paragraph(let content):
            MarkdownText(content, linkColor: linkColor)

        case .heading(let level, let content):
            MarkdownText(content, linkColor: linkColor)
                .font(headingFont(level))
                .padding(.top, isDocument ? 8 : 2)

        case .bullets(let items):
            VStack(alignment: .leading, spacing: isDocument ? 5 : 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text(palette.isGlass ? "•" : palette.bulletGlyph)
                            .font(.system(size: 13))
                            .foregroundColor(palette.isGlass ? .primary : (palette.bulletColor ?? palette.ink))
                        MarkdownText(item, linkColor: linkColor)
                    }
                }
            }

        case .numbered(let items):
            VStack(alignment: .leading, spacing: isDocument ? 5 : 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(index + 1).")
                            .font(.system(size: isDocument ? 13.5 : 12.5))
                            .foregroundColor(palette.isGlass ? .secondary : palette.secondaryText)
                            .frame(minWidth: 18, alignment: .trailing)
                        MarkdownText(item, linkColor: linkColor)
                    }
                }
            }

        case .tasks(let items):
            VStack(alignment: .leading, spacing: isDocument ? 5 : 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: item.checked ? "checkmark.square.fill" : "square")
                            .font(.system(size: isDocument ? 13 : 12))
                            .foregroundColor(item.checked
                                ? (palette.isGlass ? .accentColor : palette.accent)
                                : (palette.isGlass ? .secondary : palette.secondaryText))
                            .padding(.top, 1.5)
                        MarkdownText(item.text, linkColor: linkColor)
                            .foregroundColor(item.checked
                                ? (palette.isGlass ? .secondary : palette.secondaryText)
                                : nil)
                    }
                }
            }

        case .divider:
            Rectangle()
                .fill((palette.isGlass ? Color.secondary : palette.ink).opacity(0.18))
                .frame(height: 1)
                .padding(.vertical, isDocument ? 8 : 3)

        case .quote(let content):
            QuoteBlockView(content: content, linkColor: linkColor)

        case .code(let content, let language):
            CodeBlockView(content: content, language: language)

        case .artifact(let kind, let content, let complete):
            ArtifactCardView(
                kind: kind,
                content: content,
                complete: complete || !isStreaming,
                truncated: !complete && !isStreaming
            )

        case .mermaid(let code, let complete):
            // Once the stream is over an unterminated fence still gets a render
            // attempt; the parser decides whether it degrades to source.
            MermaidBlockView(code: code, complete: complete || !isStreaming)

        case .table(let rows):
            tableView(rows)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        if isDocument {
            switch level {
            case 1: return .system(size: 23, weight: .bold)
            case 2: return .system(size: 18, weight: .bold)
            default: return .system(size: 15.5, weight: .semibold)
            }
        }
        switch level {
        case 1: return .system(size: 16, weight: .bold)
        case 2: return .system(size: 14.5, weight: .bold)
        default: return .system(size: 13, weight: .semibold)
        }
    }

    // MARK: - Table

    /// Blockquote: quotations keep their normal typography (accent bar, no
    /// mono) but the whole quote is tap-to-copy — for "give me the quote"
    /// answers where the text itself is the artifact.
    private struct QuoteBlockView: View {
        let content: String
        let linkColor: Color
        @State private var justCopied = false
        @State private var isHovering = false
        @Environment(\.themePalette) private var palette

        var body: some View {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(palette.isGlass ? Color.accentColor.opacity(0.6) : (palette.quoteColor ?? palette.accent))
                    .frame(width: 3)
                MarkdownText(content, linkColor: linkColor)
                    .foregroundColor(palette.isGlass ? .secondary : palette.secondaryText)
                if isHovering || justCopied {
                    Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9))
                        .foregroundColor(justCopied ? .green : .secondary)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.12)) { isHovering = hovering }
            }
            .onTapGesture {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(content, forType: .string)
                withAnimation { justCopied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    withAnimation { justCopied = false }
                }
            }
            .help(L("tooltip.tapToCopy"))
        }
    }

    /// Fenced-code card: click anywhere on it to copy the whole block
    /// (Telegram-style), with a brief checkmark confirmation.
    /// Internal (not private): MermaidBlockView reuses it as the source
    /// fallback when a diagram fails to parse.
    struct CodeBlockView: View {
        let content: String
        var language: String = ""
        @State private var justCopied = false
        @State private var justRan = false
        @Environment(\.themePalette) private var palette
        @ObservedObject private var settings = AppSettings.shared

        /// ▶ shows only on shell-tagged blocks, and only while the feature
        /// is enabled in Settings → General.
        private var showsRun: Bool {
            settings.terminalRunMode != .off && TerminalCommandRunner.isShellLanguage(language)
        }

        private func copyContent() {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(content, forType: .string)
            withAnimation { justCopied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation { justCopied = false }
            }
        }

        var body: some View {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(content)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(palette.isGlass ? .primary : palette.codeText)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .background(palette.isGlass ? AnyShapeStyle(Color.secondary.opacity(0.12)) : palette.codeFill)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topTrailing) {
                // Real buttons with generous (22 pt) hit zones: a near-miss
                // on ▶ must not fall through to the block's tap-to-copy.
                HStack(spacing: 0) {
                    if showsRun {
                        Button {
                            TerminalCommandRunner.run(content)
                            withAnimation { justRan = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                withAnimation { justRan = false }
                            }
                        } label: {
                            Image(systemName: justRan ? "checkmark" : "play.fill")
                                .font(.system(size: 9))
                                .foregroundColor(justRan ? .green : .secondary)
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(settings.terminalRunMode == .autorun
                            ? L("tooltip.runInTerminal")
                            : L("tooltip.insertIntoTerminal"))
                    }
                    Button {
                        copyContent()
                    } label: {
                        Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9))
                            .foregroundColor(justCopied ? .green : .secondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L("tooltip.tapToCopy"))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onTapGesture {
                copyContent()
            }
            .help(L("tooltip.tapToCopy"))
        }
    }

    @ViewBuilder
    private func tableView(_ rows: [[String]]) -> some View {
        let columnCount = rows.map(\.count).max() ?? 0
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    GridRow {
                        ForEach(0..<columnCount, id: \.self) { column in
                            let cell = column < row.count ? row[column] : ""
                            MarkdownText(cell, linkColor: linkColor)
                                .font(.system(size: 12, weight: rowIndex == 0 ? .semibold : .regular))
                        }
                    }
                    if rowIndex == 0 {
                        Divider()
                            .gridCellUnsizedAxes(.horizontal)
                    }
                }
            }
            .padding(10)
        }
        .background(palette.isGlass ? Color.secondary.opacity(0.08) : palette.ink.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(palette.isGlass ? Color.secondary.opacity(0.18) : palette.ink.opacity(0.22), lineWidth: 1)
        )
    }

    // MARK: - Parsing

    private final class BlockBox {
        let blocks: [Block]
        init(_ blocks: [Block]) { self.blocks = blocks }
    }

    /// Memoizes the block parse. `parse` used to run on every `body`
    /// evaluation — per hover, per scroll, per geometry change, and per
    /// streamed chunk of the growing bubble. The result depends only on
    /// `text`, so it is cached by text; NSCache evicts under memory pressure
    /// and the count cap bounds the streaming case (each grown increment is a
    /// distinct key that ages out).
    private static let parseCache: NSCache<NSString, BlockBox> = {
        let cache = NSCache<NSString, BlockBox>()
        cache.countLimit = 256
        return cache
    }()

    static func parse(_ text: String) -> [Block] {
        let cacheKey = text as NSString
        if let cached = parseCache.object(forKey: cacheKey) { return cached.blocks }
        var blocks: [Block] = []
        var paragraphLines: [String] = []
        var bulletItems: [String] = []
        var numberedItems: [String] = []
        var taskItems: [(checked: Bool, text: String)] = []
        var quoteLines: [String] = []
        var tableLines: [String] = []
        var codeLines: [String] = []
        var inCodeFence = false
        var codeFenceLanguage = ""
        var codeFenceTicks = 3

        // ```html / ```markdown fences (and unlabeled fences that carry a full
        // HTML document) become artifact cards; everything else stays a plain
        // code block.
        func codeOrArtifact(_ content: String, complete: Bool) -> Block {
            let lower = content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let looksLikeDocument = lower.hasPrefix("<!doctype") || lower.hasPrefix("<html")
            if codeFenceLanguage == "html" || looksLikeDocument {
                return .artifact(kind: .html, content: content, complete: complete)
            }
            if codeFenceLanguage == "markdown" || codeFenceLanguage == "md" {
                return .artifact(kind: .markdown, content: content, complete: complete)
            }
            if codeFenceLanguage == "mermaid" {
                return .mermaid(code: content, complete: complete)
            }
            return .code(content: content, language: codeFenceLanguage)
        }

        func flushParagraph() {
            if !paragraphLines.isEmpty {
                blocks.append(.paragraph(paragraphLines.joined(separator: "\n")))
                paragraphLines = []
            }
        }
        func flushBullets() {
            if !bulletItems.isEmpty {
                blocks.append(.bullets(bulletItems))
                bulletItems = []
            }
        }
        func flushNumbered() {
            if !numberedItems.isEmpty {
                blocks.append(.numbered(numberedItems))
                numberedItems = []
            }
        }
        func flushTasks() {
            if !taskItems.isEmpty {
                blocks.append(.tasks(taskItems))
                taskItems = []
            }
        }
        func flushQuote() {
            if !quoteLines.isEmpty {
                blocks.append(.quote(quoteLines.joined(separator: "\n")))
                quoteLines = []
            }
        }
        func flushTable() {
            guard !tableLines.isEmpty else { return }
            let rows: [[String]] = tableLines.compactMap { line in
                let inner = line.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                let cells = inner.components(separatedBy: "|").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                // Skip separator rows like |---|:---:|
                let isSeparator = cells.allSatisfy { cell in
                    !cell.isEmpty && cell.allSatisfy { "-: ".contains($0) }
                }
                return isSeparator ? nil : cells
            }
            if !rows.isEmpty {
                blocks.append(.table(rows: rows))
            }
            tableLines = []
        }
        func flushAllText() {
            flushParagraph()
            flushBullets()
            flushNumbered()
            flushTasks()
            flushQuote()
            flushTable()
        }

        // "- [ ] item" / "- [x] item" (also "* [...]") → task-list item.
        func taskItem(_ line: String) -> (checked: Bool, text: String)? {
            guard line.hasPrefix("- [") || line.hasPrefix("* [") else { return nil }
            let rest = line.dropFirst(2)
            guard rest.count > 4 else { return nil }
            switch rest.prefix(4).lowercased() {
            case "[ ] ": return (false, String(rest.dropFirst(4)))
            case "[x] ": return (true, String(rest.dropFirst(4)))
            default: return nil
            }
        }

        // "1. item" / "12) item" → ordered-list item.
        func numberedItem(_ line: String) -> String? {
            let digits = line.prefix(while: { $0.isNumber })
            guard !digits.isEmpty, digits.count <= 3 else { return nil }
            let rest = line.dropFirst(digits.count)
            guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
            return String(rest.dropFirst(2))
        }

        for rawLine in text.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if inCodeFence {
                // A closing fence is backticks-only, at least as long as the
                // opening one (CommonMark). Anything else — including inner
                // ``` fences of a ````markdown document — is content.
                let ticks = trimmed.prefix(while: { $0 == "`" }).count
                if ticks >= codeFenceTicks, trimmed.drop(while: { $0 == "`" }).isEmpty {
                    blocks.append(codeOrArtifact(codeLines.joined(separator: "\n"), complete: true))
                    codeLines = []
                    inCodeFence = false
                } else {
                    codeLines.append(rawLine)
                }
                continue
            }

            if trimmed.hasPrefix("```") {
                flushAllText()
                inCodeFence = true
                codeFenceTicks = trimmed.prefix(while: { $0 == "`" }).count
                codeFenceLanguage = String(trimmed.drop(while: { $0 == "`" }))
                    .trimmingCharacters(in: .whitespaces).lowercased()
                continue
            }

            // Table row
            if trimmed.hasPrefix("|"), trimmed.hasSuffix("|"), trimmed.count > 1 {
                flushParagraph(); flushBullets(); flushQuote()
                tableLines.append(trimmed)
                continue
            } else {
                flushTable()
            }

            // Horizontal rule: a line of only --- / *** / ___
            if trimmed.count >= 3, let first = trimmed.first,
               "-*_".contains(first), trimmed.allSatisfy({ $0 == first }) {
                flushAllText()
                blocks.append(.divider)
                continue
            }

            // Heading
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                let content = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                if level <= 6, !content.isEmpty {
                    flushAllText()
                    blocks.append(.heading(level: level, text: content))
                    continue
                }
            }

            // Block quote
            if trimmed.hasPrefix(">") {
                flushParagraph(); flushBullets()
                quoteLines.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            } else {
                flushQuote()
            }

            // Task list — checked before bullets ("- [ ]" also matches "- ")
            if let task = taskItem(trimmed) {
                flushParagraph(); flushBullets(); flushNumbered()
                taskItems.append(task)
                continue
            } else {
                flushTasks()
            }

            // Bullet list
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                flushParagraph(); flushNumbered()
                bulletItems.append(String(trimmed.dropFirst(2)))
                continue
            } else {
                flushBullets()
            }

            // Ordered list
            if let item = numberedItem(trimmed) {
                flushParagraph()
                numberedItems.append(item)
                continue
            } else {
                flushNumbered()
            }

            // Blank line separates paragraphs
            if trimmed.isEmpty {
                flushParagraph()
            } else {
                paragraphLines.append(rawLine)
            }
        }

        // Unterminated code fence (still streaming) — render what we have
        if inCodeFence, !codeLines.isEmpty {
            blocks.append(codeOrArtifact(codeLines.joined(separator: "\n"), complete: false))
        }
        flushAllText()
        parseCache.setObject(BlockBox(blocks), forKey: cacheKey)
        return blocks
    }

    // MARK: - Clipboard HTML

    /// Single entry point for copying message markdown: writes the plain
    /// string always, plus an HTML flavor when the text contains a pipe
    /// table (see `clipboardHTML`). Used by the bubble copy button and the
    /// OCR auto-copy — both must behave identically.
    static func copyMarkdownToPasteboard(_ markdown: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let html = clipboardHTML(from: markdown) {
            let item = NSPasteboardItem()
            item.setString(markdown, forType: .string)
            item.setString(html, forType: .html)
            pasteboard.writeObjects([item])
        } else {
            pasteboard.setString(markdown, forType: .string)
        }
    }

    /// HTML flavor for the copy button: spreadsheets (Google Sheets, Excel,
    /// Numbers) split a paste into cells only when the clipboard carries an
    /// HTML `<table>` (or TSV) — raw pipe-markdown lands as text in a single
    /// column. Returns nil when the message contains no table, so ordinary
    /// messages keep the plain-string-only clipboard exactly as before.
    static func clipboardHTML(from text: String) -> String? {
        let blocks = parse(text)
        let hasTable = blocks.contains { if case .table = $0 { return true } else { return false } }
        guard hasTable else { return nil }

        var html = "<meta charset=\"utf-8\">"
        for block in blocks {
            switch block {
            case .paragraph(let content):
                html += "<p>\(inlineHTML(content))</p>"
            case .heading(let level, let content):
                let tag = "h\(min(max(level, 1), 6))"
                html += "<\(tag)>\(inlineHTML(content))</\(tag)>"
            case .bullets(let items):
                html += "<ul>" + items.map { "<li>\(inlineHTML($0))</li>" }.joined() + "</ul>"
            case .numbered(let items):
                html += "<ol>" + items.map { "<li>\(inlineHTML($0))</li>" }.joined() + "</ol>"
            case .tasks(let items):
                html += "<ul>" + items.map { "<li>\($0.checked ? "☑" : "☐") \(inlineHTML($0.text))</li>" }.joined() + "</ul>"
            case .quote(let content):
                html += "<blockquote>\(inlineHTML(content))</blockquote>"
            case .code(let content, _), .artifact(_, let content, _), .mermaid(let content, _):
                html += "<pre>\(escapeHTML(content))</pre>"
            case .divider:
                html += "<hr>"
            case .table(let rows):
                html += "<table>"
                for (rowIndex, row) in rows.enumerated() {
                    let cellTag = rowIndex == 0 ? "th" : "td"
                    html += "<tr>" + row.map { "<\(cellTag)>\(inlineHTML($0))</\(cellTag)>" }.joined() + "</tr>"
                }
                html += "</table>"
            }
        }
        return html
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Minimal inline markdown → HTML for clipboard cells: links, bold,
    /// inline code. Single-`*` italics are left alone — a lone asterisk in
    /// OCR'd table data is far more common than intentional italics.
    private static func inlineHTML(_ text: String) -> String {
        var s = escapeHTML(text)
        s = s.replacingOccurrences(
            of: #"\[([^\]]+)\]\((https?://[^)\s]+)\)"#,
            with: "<a href=\"$2\">$1</a>", options: .regularExpression)
        s = s.replacingOccurrences(
            of: #"\*\*([^*]+)\*\*"#,
            with: "<b>$1</b>", options: .regularExpression)
        s = s.replacingOccurrences(
            of: #"`([^`]+)`"#,
            with: "<code>$1</code>", options: .regularExpression)
        return s
    }
}
