import SwiftUI

/// Block-level Markdown renderer for chat bubbles (Telegram-style):
/// paragraphs, **bold headings**, bullet lists, block quotes, fenced code
/// blocks with a monospaced card, and pipe tables rendered as a real grid.
/// Inline styling (bold/italic/links) inside every block is handled by
/// AttributedString + raw-URL linkification.
struct MarkdownBlocksView: View {
    let text: String
    let linkColor: Color

    enum Block: Identifiable {
        case paragraph(String)
        case heading(level: Int, text: String)
        case bullets([String])
        case quote(String)
        case code(String)
        case table(rows: [[String]])

        var id: UUID { UUID() }
    }

    var body: some View {
        let blocks = Self.parse(text)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                render(block)
            }
        }
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
                .padding(.top, 2)

        case .bullets(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                            .font(.system(size: 13))
                        MarkdownText(item, linkColor: linkColor)
                    }
                }
            }

        case .quote(let content):
            QuoteBlockView(content: content, linkColor: linkColor)

        case .code(let content):
            CodeBlockView(content: content)

        case .table(let rows):
            tableView(rows)
        }
    }

    private func headingFont(_ level: Int) -> Font {
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

        var body: some View {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor.opacity(0.6))
                    .frame(width: 3)
                MarkdownText(content, linkColor: linkColor)
                    .foregroundColor(.secondary)
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
    private struct CodeBlockView: View {
        let content: String
        @State private var justCopied = false

        var body: some View {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(content)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
            }
            .background(Color.secondary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topTrailing) {
                Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9))
                    .foregroundColor(justCopied ? .green : .secondary)
                    .padding(5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
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
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        )
    }

    // MARK: - Parsing

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraphLines: [String] = []
        var bulletItems: [String] = []
        var quoteLines: [String] = []
        var tableLines: [String] = []
        var codeLines: [String] = []
        var inCodeFence = false

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
            flushQuote()
            flushTable()
        }

        for rawLine in text.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if inCodeFence {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(codeLines.joined(separator: "\n")))
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

            // Bullet list
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                flushParagraph()
                bulletItems.append(String(trimmed.dropFirst(2)))
                continue
            } else {
                flushBullets()
            }

            // Blank line separates paragraphs
            if trimmed.isEmpty {
                flushParagraph()
            } else {
                paragraphLines.append(rawLine)
            }
        }

        // Unterminated code fence — render what we have
        if inCodeFence, !codeLines.isEmpty {
            blocks.append(.code(codeLines.joined(separator: "\n")))
        }
        flushAllText()
        return blocks
    }
}
