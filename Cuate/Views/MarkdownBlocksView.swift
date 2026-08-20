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

    /// One entry of a list, with whatever is nested under it: sub-lists and
    /// continuation lines. Lists are a TREE — a flat model renumbered every
    /// sub-list's parent from 1 and lost indentation entirely (an answer with
    /// seven numbered points, each with sub-bullets, rendered as seven "1."s).
    struct ListItem {
        let text: String
        let children: [Block]

        init(_ text: String, children: [Block] = []) {
            self.text = text
            self.children = children
        }
    }

    struct TaskItem {
        let checked: Bool
        let text: String
        let children: [Block]

        init(checked: Bool, text: String, children: [Block] = []) {
            self.checked = checked
            self.text = text
            self.children = children
        }
    }

    indirect enum Block {
        case paragraph(String)
        case heading(level: Int, text: String)
        case bullets([ListItem])
        /// `start` is the first item's own number: CommonMark renumbers the
        /// rest from it, so "1. 1. 1." counts up and a list that opens at "3."
        /// keeps starting at three.
        case numbered(start: Int, items: [ListItem])
        case tasks([TaskItem])
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
        /// A standalone `![alt](url)` line — agents send screenshots and
        /// plots as image links; without this they were dead markdown text.
        /// Loading goes through `AgentInlineImageView` (adds the gateway's
        /// Bearer token for its own host).
        case image(alt: String, url: String)
    }

    /// A list line as parsed, before nesting is worked out.
    struct RawListLine {
        enum Kind: Equatable {
            case bullet
            case numbered(Int)
            case task(Bool)
            /// A non-list line indented under an item — it keeps its place in
            /// the stream, so a sentence written after a sub-list renders
            /// after it and one written before renders before.
            case text

            /// Two lines belong to the same list only when they are the same
            /// KIND of list — a bullet run after a numbered run is a new list,
            /// not a continuation of it.
            var family: Int {
                switch self {
                case .bullet: return 0
                case .numbered: return 1
                case .task: return 2
                case .text: return 3
                }
            }
        }

        let indent: Int
        /// Column where the item's TEXT starts (indent + marker width). A
        /// continuation line belongs to the deepest item whose text column is
        /// at or left of it — indenting under "- option A" is not the same as
        /// indenting under the numbered point that owns it.
        let contentIndent: Int
        let kind: Kind
        let text: String
    }

    /// Whether a line opens or continues a list. Shared with the streaming
    /// buffer: a blank line no longer ends a list, so cutting the text there
    /// would split one list into two and restart its numbering.
    static func isListLine(_ rawLine: String) -> Bool {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ")
            || trimmed.hasPrefix("+ ") { return true }
        let digits = trimmed.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, digits.count <= 3 else { return false }
        let rest = trimmed.dropFirst(digits.count)
        return rest.hasPrefix(". ") || rest.hasPrefix(") ")
    }

    /// Turns a flat run of list lines into blocks, nesting by indentation.
    ///
    /// Rules, in the order they matter:
    /// - the shallowest indentation in the run is the top level; anything
    ///   deeper belongs to the item above it (models indent by 2, 3 or 4
    ///   spaces, so levels are compared, never divided);
    /// - a change of list kind at the same level starts a new list — bullets
    ///   under a numbered point are a sub-list, not a renumbering;
    /// - an ordered list keeps its FIRST number as the start and counts from
    ///   there, which is what CommonMark does and what makes "1. 1. 1." come
    ///   out as 1, 2, 3.
    static func buildListBlocks(_ lines: [RawListLine]) -> [Block] {
        guard !lines.isEmpty else { return [] }
        let base = lines.map(\.indent).min() ?? 0

        var blocks: [Block] = []
        var index = 0
        while index < lines.count {
            let family = lines[index].kind.family
            var bullets: [ListItem] = []
            var tasks: [TaskItem] = []
            var prose: [String] = []
            var start: Int?

            // One run of same-kind items at this level, each with its subtree.
            while index < lines.count, lines[index].indent <= base,
                  lines[index].kind.family == family {
                let line = lines[index]
                index += 1
                var childLines: [RawListLine] = []
                while index < lines.count, lines[index].indent > base {
                    childLines.append(lines[index])
                    index += 1
                }
                let children = buildListBlocks(childLines)
                switch line.kind {
                case .bullet:
                    bullets.append(ListItem(line.text, children: children))
                case .numbered(let number):
                    if start == nil { start = number }
                    bullets.append(ListItem(line.text, children: children))
                case .task(let checked):
                    tasks.append(TaskItem(checked: checked, text: line.text, children: children))
                case .text:
                    prose.append(line.text)
                }
            }

            switch family {
            case 0 where !bullets.isEmpty: blocks.append(.bullets(bullets))
            case 1 where !bullets.isEmpty: blocks.append(.numbered(start: start ?? 1, items: bullets))
            case 2 where !tasks.isEmpty: blocks.append(.tasks(tasks))
            case 3 where !prose.isEmpty: blocks.append(.paragraph(prose.joined(separator: "\n")))
            default: break
            }
        }
        return blocks
    }

    private var isDocument: Bool { style == .document }

    /// A run of consecutive PROSE blocks (paragraphs, headings, lists) is
    /// rendered as ONE Text — SwiftUI selection cannot cross view borders,
    /// so per-block Texts limited a drag to a single paragraph ("selects in
    /// weird blocks", 2026-07-28). Interactive blocks (code cards,
    /// tables, artifacts, quotes with their tap-to-copy) stay their own
    /// views between runs.
    enum Segment {
        case prose([Block])
        case other(Block)
    }

    static func isProse(_ block: Block) -> Bool {
        switch block {
        case .paragraph, .heading, .bullets, .numbered, .tasks: return true
        default: return false
        }
    }

    static func segment(_ blocks: [Block]) -> [Segment] {
        var segments: [Segment] = []
        var run: [Block] = []
        for block in blocks {
            if isProse(block) {
                run.append(block)
            } else {
                if !run.isEmpty { segments.append(.prose(run)); run = [] }
                segments.append(.other(block))
            }
        }
        if !run.isEmpty { segments.append(.prose(run)) }
        return segments
    }

    var body: some View {
        let segments = Self.segment(Self.parse(text))
        VStack(alignment: .leading, spacing: isDocument ? 10 : 6) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let run):
                    ProseRunText(run: run, linkColor: linkColor, isDocument: isDocument)
                case .other(let block):
                    render(block)
                }
            }
        }
        .font(isDocument ? .system(size: 14) : nil)
    }

    // MARK: - Block rendering

    /// Blocks nested under a list item. Indentation comes from the parent's
    /// glyph column, so nothing extra is added here — a second level of
    /// padding stacked up fast and pushed deep items off the bubble.
    /// `AnyView` on purpose: `render` → `nested` → `render` is genuine
    /// recursion, and a ViewBuilder's static type cannot close that loop.
    private func nested(_ children: [Block]) -> AnyView {
        guard !children.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(
            VStack(alignment: .leading, spacing: isDocument ? 5 : 3) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                    render(child)
                }
            }
        )
    }

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
                        VStack(alignment: .leading, spacing: isDocument ? 5 : 3) {
                            MarkdownText(item.text, linkColor: linkColor)
                            nested(item.children)
                        }
                    }
                }
            }

        case .numbered(let start, let items):
            VStack(alignment: .leading, spacing: isDocument ? 5 : 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(start + index).")
                            .font(.system(size: isDocument ? 13.5 : 12.5))
                            .foregroundColor(palette.isGlass ? .secondary : palette.secondaryText)
                            .frame(minWidth: 18, alignment: .trailing)
                        VStack(alignment: .leading, spacing: isDocument ? 5 : 3) {
                            MarkdownText(item.text, linkColor: linkColor)
                            nested(item.children)
                        }
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
                        VStack(alignment: .leading, spacing: isDocument ? 5 : 3) {
                            MarkdownText(item.text, linkColor: linkColor)
                                .foregroundColor(item.checked
                                    ? (palette.isGlass ? .secondary : palette.secondaryText)
                                    : nil)
                            nested(item.children)
                        }
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

        case .image(let alt, let url):
            AgentInlineImageView(urlString: url, alt: alt)
        case .mermaid(let code, let complete):
            // Once the stream is over an unterminated fence still gets a render
            // attempt; the parser decides whether it degrades to source.
            MermaidBlockView(code: code, complete: complete || !isStreaming)

        case .table(let rows):
            TableBlockView(rows: rows, linkColor: linkColor)
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
        @Environment(\.isInUserBubble) private var inUserBubble

        /// On the panel the quote dims to the theme's secondary; on the USER
        /// bubble that secondary can fight the fill (Yule: green on red), so
        /// there it stays the bubble's own text color, slightly dimmed — the
        /// accent bar alone marks the quote.
        private var quoteTextColor: Color {
            if palette.isGlass { return Color.secondary }
            return inUserBubble ? palette.userText.opacity(0.9) : palette.secondaryText
        }

        var body: some View {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(palette.isGlass ? Color.accentColor.opacity(0.6) : (palette.quoteColor ?? palette.accent))
                    .frame(width: 3)
                MarkdownText(content, linkColor: linkColor)
                    .foregroundColor(quoteTextColor)
                // Always in the layout (fixed width) so revealing it on hover
                // only changes opacity — the quote text never reflows. Both
                // glyphs share the frame, so the checkmark swap doesn't nudge
                // the text either.
                Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9))
                    .foregroundColor(justCopied ? .green : .secondary)
                    .frame(width: 11, alignment: .center)
                    .opacity(isHovering || justCopied ? 1 : 0)
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
        /// Long logs render folded (the tail); the user can unfold.
        @State private var showFullLog = false
        @Environment(\.themePalette) private var palette
        @Environment(\.colorScheme) private var colorScheme
        @ObservedObject private var settings = AppSettings.shared

        /// Memoizes the ANSI/diff rendering. The character-by-character SGR
        /// walk over a pasted terminal dump is the expensive part of creating
        /// an agent row — and it re-ran on every body evaluation. The output
        /// depends only on the content and the theme context, so it caches by
        /// that key (same idiom as `MarkdownText.renderCache`).
        private final class AttrBox {
            let value: AttributedString
            init(_ value: AttributedString) { self.value = value }
        }
        private static let terminalRenderCache: NSCache<NSString, AttrBox> = {
            let cache = NSCache<NSString, AttrBox>()
            cache.countLimit = 256
            return cache
        }()

        private func cachedTerminalRender(_ kind: String,
                                          render: () -> AttributedString) -> AttributedString {
            let key = "\(kind)|\(palette.themeID)|\(colorScheme)|\(displayContent)" as NSString
            if let boxed = Self.terminalRenderCache.object(forKey: key) { return boxed.value }
            let rendered = render()
            Self.terminalRenderCache.setObject(AttrBox(rendered), forKey: key)
            return rendered
        }

        /// A single message can carry a 20k-line log — rendering it whole
        /// hangs the panel (notes §7.2 item 4). Above this the block folds.
        private static let foldThreshold = 300

        /// ▶ shows on shell-tagged blocks — and, in AGENT chats, on untagged
        /// blocks that read as commands (agents don't follow our prompt's
        /// tagging rules). Only while the feature is enabled in Settings.
        private var showsRun: Bool {
            guard settings.terminalRunMode != .off else { return false }
            if TerminalCommandRunner.isShellLanguage(language) { return true }
            return language.isEmpty
                && settings.activeAgentRole != nil
                && AgentTerminalText.looksLikeShellCommands(content)
        }

        /// The active agent role, when the block lives in an agent chat —
        /// enables "run at the agent" and the host label (§7.3: the local ▶
        /// default never changes; remote is a separate, explicit action).
        private var agentRole: AgentRole? {
            settings.activeAgentRole
        }

        /// Whether the block carries PROSE rather than code — models fence
        /// "copy and send this" letters, and those must wrap at the card
        /// edge (GitHub-style horizontal scrolling is for code, where a
        /// broken line is a broken program). Anything tagged with a language,
        /// or reading as shell commands / a diff / terminal output, keeps
        /// the no-wrap scroller.
        private var wrapsText: Bool {
            if ["text", "txt", "plain"].contains(language) { return true }
            guard language.isEmpty else { return false }
            // Column alignment inside a fence (pipe/ASCII tables, box
            // drawings) relies on the mono grid — wrapping would shred it.
            // NOTE: real markdown pipe tables never reach this view; the
            // parser renders them as a TableBlockView grid.
            let gridMarkers = CharacterSet(charactersIn: "|│┃┌┐└┘├┤┬┴┼═║╔╗╚╝")
            let gridLines = content.split(separator: "\n").filter {
                $0.unicodeScalars.contains(where: gridMarkers.contains)
            }
            if gridLines.count >= 2 { return false }
            return !AgentTerminalText.looksLikeShellCommands(content)
                && !AgentTerminalText.isUnifiedDiff(content: content, language: language)
                && !AgentTerminalText.containsANSI(content)
        }

        private func copyContent() {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(content, forType: .string)
            withAnimation { justCopied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation { justCopied = false }
            }
        }

        /// Line count of the raw content (fold decision).
        private var lineCount: Int {
            content.reduce(into: 1) { if $1 == "\n" { $0 += 1 } }
        }

        private var isFolded: Bool {
            !showFullLog && lineCount > Self.foldThreshold
        }

        /// The text actually rendered: folded logs keep the TAIL (that is
        /// where a failed command's verdict lives, terminal-style).
        private var displayContent: String {
            guard isFolded else { return content }
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            return lines.suffix(Self.foldThreshold).joined(separator: "\n")
        }

        /// Theme-tuned ANSI palette: Terminal theme brings its own signature
        /// green; everything else uses the readable defaults.
        private var ansiPalette: AgentTerminalText.AnsiPalette {
            var ansi = AgentTerminalText.AnsiPalette()
            if palette.placeholderCaret { // Terminal/Blueprint family
                ansi.green = palette.accent
            }
            return ansi
        }

        private var baseTextColor: Color {
            palette.isGlass ? .primary : palette.codeText
        }

        /// The rendered text: unified diffs get line colors, ANSI output
        /// gets its terminal colors (with `\r` redraws collapsed), plain
        /// code stays plain.
        @ViewBuilder
        private var codeText: some View {
            if AgentTerminalText.isUnifiedDiff(content: displayContent, language: language) {
                Text(cachedTerminalRender("diff") {
                    AgentTerminalText.diffAttributed(displayContent, palette: ansiPalette, baseColor: baseTextColor)
                })
                    .font(.system(size: 11.5, design: .monospaced))
            } else if AgentTerminalText.containsANSI(displayContent) {
                Text(cachedTerminalRender("ansi") {
                    AgentTerminalText.ansiAttributed(displayContent, palette: ansiPalette, baseColor: baseTextColor)
                })
                    .font(.system(size: 11.5, design: .monospaced))
            } else {
                Text(displayContent)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(baseTextColor)
            }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                // Title strip: the diff's file name, and the agent-host label
                // when a role is active (where a remote run would execute).
                if let title = blockTitle {
                    HStack(spacing: 4) {
                        Image(systemName: title.icon)
                            .font(.system(size: 9))
                        Text(title.text)
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)
                    }
                    .foregroundColor(palette.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                }

                if isFolded {
                    Button {
                        showFullLog = true
                    } label: {
                        Text(String(format: AGL("agent.code.showAll"), lineCount))
                            .font(.system(size: 10))
                            .foregroundColor(palette.ink)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                }

                if wrapsText {
                    // Prose in a fence (a letter to send, a quote to paste)
                    // wraps at the card edge — a horizontal scroller would
                    // hide everything past the first screenful of each line.
                    codeText
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        codeText
                            .textSelection(.enabled)
                            .padding(8)
                    }
                    // A ScrollView is infinitely compressible, so a row whose
                    // measured height came in short (stale intrinsic size after
                    // a detached rootView swap, 2026-08-17) dumped the WHOLE
                    // shortfall here — the code Text tail-truncated with "…"
                    // while the rest of the bubble looked fine. Refuse vertical
                    // compression: content must never silently disappear.
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .background(palette.isGlass ? AnyShapeStyle(Color.secondary.opacity(0.12)) : palette.codeFill)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topTrailing) {
                // Real buttons with generous (22 pt) hit zones: a near-miss
                // on ▶ must not fall through to the block's tap-to-copy.
                HStack(spacing: 0) {
                    if lineCount > Self.foldThreshold {
                        Button {
                            saveLogToFile()
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(AGL("agent.code.saveLog"))
                    }
                    if showsRun {
                        runControl
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

        private var blockTitle: (icon: String, text: String)? {
            if AgentTerminalText.isUnifiedDiff(content: content, language: language),
               let file = AgentTerminalText.diffFileName(content) {
                return ("doc.text", file)
            }
            if showsRun, let role = agentRole {
                // The label answers "where would a remote run land" BEFORE
                // the user opens the ▶ menu.
                let host = HermesSettings.shared.baseURL.host ?? role.displayName
                return ("desktopcomputer", host)
            }
            return nil
        }

        /// ▶ with the default LOCAL action; when an agent role is active a
        /// context menu adds the explicit "run at the agent" alternative.
        /// Autorun composes with the local default only — a remote run is
        /// always a deliberate menu pick, never automatic (§7.3).
        @ViewBuilder
        private var runControl: some View {
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
            .contextMenu {
                if let role = agentRole {
                    Button {
                        NotificationCenter.default.post(
                            name: .agentRunCommandRemotely, object: content)
                    } label: {
                        Label(String(format: AGL("agent.code.runAtAgent"),
                                     HermesSettings.shared.baseURL.host ?? role.displayName),
                              systemImage: "desktopcomputer")
                    }
                }
            }
        }

        /// Save the full log via a sheet (a free-standing dialog would
        /// trigger the floating panel's auto-hide, see presentAttachOpenPanel).
        private func saveLogToFile() {
            guard let window = FloatingPanelWindow.chatPanel else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "agent-log.txt"
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                try? content.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Pipe table as a real grid, with a copy button revealed on hover. The
    /// button is deliberately the only copy affordance here — a tap-to-copy
    /// over the whole card (the way code blocks work) would fight the table's
    /// own text selection and links.
    private struct TableBlockView: View {
        let rows: [[String]]
        let linkColor: Color
        @State private var justCopied = false
        @State private var isHovering = false
        @Environment(\.themePalette) private var palette

        var body: some View {
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
                // Keeps the button clear of the last header cell.
                .padding(.trailing, 14)
            }
            .background(palette.isGlass ? Color.secondary.opacity(0.08) : palette.ink.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(palette.isGlass ? Color.secondary.opacity(0.18) : palette.ink.opacity(0.22), lineWidth: 1)
            )
            .overlay(alignment: .topTrailing) {
                Button {
                    MarkdownBlocksView.copyTableToPasteboard(rows)
                    withAnimation { justCopied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        withAnimation { justCopied = false }
                    }
                } label: {
                    Image(systemName: justCopied ? "checkmark" : "tablecells")
                        .font(.system(size: 10))
                        .foregroundColor(justCopied ? .green : .secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(isHovering || justCopied ? 1 : 0)
                .help(L("tooltip.copyTable"))
            }
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.12)) { isHovering = hovering }
            }
        }
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
        var listLines: [RawListLine] = []
        // A single blank line inside a list is legal (a "loose" list); it ends
        // the list only when what follows is not a list line.
        var pendingListBlank = false
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
            flushList()
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

        // "1. item" / "12) item" → ordered-list item, number kept: it decides
        // where the list starts.
        func numberedItem(_ line: String) -> (number: Int, text: String)? {
            let digits = line.prefix(while: { $0.isNumber })
            guard !digits.isEmpty, digits.count <= 3, let number = Int(digits) else { return nil }
            let rest = line.dropFirst(digits.count)
            guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
            return (number, String(rest.dropFirst(2)))
        }

        /// Any list line, before nesting is worked out. Indentation is kept in
        /// SPACES (a tab counts as four) because models mix 2, 3 and 4-space
        /// steps freely; the level is derived by comparing to siblings, never
        /// by dividing.
        func listLine(_ rawLine: String) -> RawListLine? {
            let indent = rawLine.prefix { $0 == " " || $0 == "\t" }
                .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if let task = taskItem(trimmed) {
                let marker = trimmed.count - task.text.count
                return RawListLine(indent: indent, contentIndent: indent + marker,
                                   kind: .task(task.checked), text: task.text)
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ")
                || trimmed.hasPrefix("+ ") {
                return RawListLine(indent: indent, contentIndent: indent + 2,
                                   kind: .bullet, text: String(trimmed.dropFirst(2)))
            }
            if let numbered = numberedItem(trimmed) {
                let marker = trimmed.count - numbered.text.count
                return RawListLine(indent: indent, contentIndent: indent + marker,
                                   kind: .numbered(numbered.number), text: numbered.text)
            }
            return nil
        }

        func flushList() {
            guard !listLines.isEmpty else { return }
            blocks.append(contentsOf: buildListBlocks(listLines))
            listLines = []
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
                flushParagraph(); flushList(); flushQuote()
                tableLines.append(trimmed)
                continue
            } else {
                flushTable()
            }

            // Standalone image line: ![alt](url)
            if trimmed.hasPrefix("!["), trimmed.hasSuffix(")"),
               let close = trimmed.range(of: "](") {
                let alt = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<close.lowerBound])
                let url = String(trimmed[close.upperBound..<trimmed.index(before: trimmed.endIndex)])
                if url.hasPrefix("http://") || url.hasPrefix("https://") || url.hasPrefix("data:image") {
                    flushAllText()
                    blocks.append(.image(alt: alt, url: url))
                    continue
                }
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
                flushParagraph(); flushList()
                quoteLines.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            } else {
                flushQuote()
            }

            // Lists (bullet, ordered, task) — one collector for all three, so
            // a sub-list can never split its parent into a fresh block.
            if let line = listLine(rawLine) {
                flushParagraph()
                listLines.append(line)
                pendingListBlank = false
                continue
            }

            // Inside a list: an indented non-list line continues the item
            // above it (the "compare cost, cooling, noise" sentence under a
            // numbered point), and a single blank line does not end the list —
            // only a blank followed by something else does.
            if !listLines.isEmpty {
                if trimmed.isEmpty {
                    pendingListBlank = true
                    continue
                }
                let indent = rawLine.prefix { $0 == " " || $0 == "\t" }
                    .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
                // Indented under some item: keep it in the stream at that
                // item's depth, so its position relative to sub-lists holds.
                if indent >= 2,
                   let owner = listLines.lastIndex(where: { $0.contentIndent <= indent }) {
                    listLines.append(RawListLine(
                        indent: listLines[owner].contentIndent,
                        contentIndent: listLines[owner].contentIndent,
                        kind: .text, text: trimmed
                    ))
                    pendingListBlank = false
                    continue
                }
                flushList()
                pendingListBlank = false
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

    /// Copies ONE table in every flavor a paste target might want, on a single
    /// pasteboard item — no "copy as…" menu, one click serves both:
    ///   • `.string`      — the pipe table, so editors and chats get something
    ///                      a human can read;
    ///   • `.tabularText` — TSV, which is what Numbers and most CSV importers
    ///                      ask for first;
    ///   • `.html`        — a real `<table>`, which is what Sheets and Excel
    ///                      prefer and the only flavor that keeps headers.
    /// Ragged rows are padded to the widest one so the columns stay aligned in
    /// every flavor.
    static func copyTableToPasteboard(_ rows: [[String]]) {
        let width = rows.map(\.count).max() ?? 0
        guard width > 0 else { return }
        let padded = rows.map { $0 + Array(repeating: "", count: width - $0.count) }

        var markdown: [String] = []
        for (index, row) in padded.enumerated() {
            // A literal pipe inside a cell would split it into two columns.
            markdown.append("| " + row.map { $0.replacingOccurrences(of: "|", with: "\\|") }
                .joined(separator: " | ") + " |")
            if index == 0 { markdown.append("|" + String(repeating: " --- |", count: width)) }
        }

        let tsv = padded.map { $0.map(plainCell).joined(separator: "\t") }.joined(separator: "\n")

        var html = "<meta charset=\"utf-8\"><table>"
        for (index, row) in padded.enumerated() {
            let tag = index == 0 ? "th" : "td"
            html += "<tr>" + row.map { "<\(tag)>\(inlineHTML($0))</\(tag)>" }.joined() + "</tr>"
        }
        html += "</table>"

        let item = NSPasteboardItem()
        item.setString(markdown.joined(separator: "\n"), forType: .string)
        item.setString(tsv, forType: .tabularText)
        item.setString(html, forType: .html)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }

    /// Cell text stripped of inline markdown — a spreadsheet cell should read
    /// `Total`, not `**Total**`. Tabs and newlines are flattened to spaces:
    /// either one would silently shift every later column of the TSV.
    private static func plainCell(_ text: String) -> String {
        var s = text.replacingOccurrences(
            of: #"\[([^\]]+)\]\((https?://[^)\s]+)\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "**", with: "")
        s = s.replacingOccurrences(of: "`", with: "")
        return s.replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
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
            case .bullets, .numbered, .tasks:
                html += listHTML(block)
            case .quote(let content):
                html += "<blockquote>\(inlineHTML(content))</blockquote>"
            case .code(let content, _), .artifact(_, let content, _), .mermaid(let content, _):
                html += "<pre>\(escapeHTML(content))</pre>"
            case .divider:
                html += "<hr>"
            case .image(let alt, let url):
                html += "<img src=\"\(escapeHTML(url))\" alt=\"\(escapeHTML(alt))\">"
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

    /// A list (with its sub-lists) as nested `<ul>`/`<ol>` — a spreadsheet
    /// paste keeps the hierarchy instead of flattening it.
    private static func listHTML(_ block: Block) -> String {
        func itemHTML(_ text: String, _ children: [Block]) -> String {
            "<li>" + inlineHTML(text) + children.map { child -> String in
                switch child {
                case .bullets, .numbered, .tasks: return listHTML(child)
                case .paragraph(let content): return "<p>" + inlineHTML(content) + "</p>"
                default: return ""
                }
            }.joined() + "</li>"
        }
        switch block {
        case .bullets(let items):
            return "<ul>" + items.map { itemHTML($0.text, $0.children) }.joined() + "</ul>"
        case .numbered(let start, let items):
            let open = start == 1 ? "<ol>" : "<ol start=\"\(start)\">"
            return open + items.map { itemHTML($0.text, $0.children) }.joined() + "</ol>"
        case .tasks(let items):
            return "<ul>" + items.map {
                itemHTML(($0.checked ? "☑ " : "☐ ") + $0.text, $0.children)
            }.joined() + "</ul>"
        default:
            return ""
        }
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

/// One `Text` for a whole run of prose blocks. SwiftUI selection cannot
/// cross view borders, so as long as paragraphs/headings/lists were separate
/// `Text`s a drag stopped at the edge of the block it started in. Merging a
/// run into a single AttributedString makes selection flow across the whole
/// prose stretch; interactive blocks (code cards, tables, artifacts, quotes)
/// remain their own views between runs.
///
/// SwiftUI `Text` ignores paragraph styles, so inter-block spacing is a
/// spacer line: a zero-width space on a tiny font. The build is cached the
/// same way `MarkdownText` caches its inline render.
private struct ProseRunText: View {
    let run: [MarkdownBlocksView.Block]
    let linkColor: Color
    let isDocument: Bool
    @Environment(\.themePalette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.agentFileLinksEnabled) private var agentFileLinks

    private final class Box {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }
    /// Bounded by BYTES, not entry count: entries here range from a one-line
    /// paragraph to a 14 000-character agent answer, so a flat count limit
    /// either starves long conversations or lets a few giants own the memory.
    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 512
        cache.totalCostLimit = 8 << 20 // 8 MB of source text
        return cache
    }()

    var body: some View {
        Text(cached())
            .fixedSize(horizontal: false, vertical: true)
    }

    private func cached() -> AttributedString {
        let (digest, cost) = Self.runDigest(run)
        let key = "\(palette.themeID)|\(colorScheme)|\(linkColor)|\(agentFileLinks)|\(isDocument)|\(digest)|\(cost)" as NSString
        if let boxed = Self.cache.object(forKey: key) { return boxed.value }
        let built = build()
        Self.cache.setObject(Box(built), forKey: key, cost: cost)
        return built
    }

    /// Stable cache identity of the run's content, as a HASH rather than the
    /// text itself. The text-as-key version made every render of every row
    /// concatenate the whole message into a fresh String just to look itself
    /// up — O(message) per body evaluation, on a path AppKit re-enters for the
    /// whole transcript on each layout pass — and then had NSCache retain that
    /// copy, so the cache cost twice the text it saved (spin-20260812-175422).
    ///
    /// Returns the digest and the character count, which doubles as the
    /// NSCache cost and as a second discriminator against hash collisions.
    private static func runDigest(_ run: [MarkdownBlocksView.Block]) -> (UInt64, Int) {
        var hasher = Hasher()
        var characters = 0
        func feed(_ tag: String, _ text: String) {
            hasher.combine(tag)
            hasher.combine(text)
            characters += text.count
        }
        // Nested blocks feed the digest too: two runs differing only in a
        // sub-list would otherwise share a cache entry and render each other.
        func feedChild(_ block: MarkdownBlocksView.Block) {
            switch block {
            case .paragraph(let text): feed("cp", text)
            case .bullets(let items): items.forEach { feedItem("cb", $0) }
            case .numbered(let start, let items):
                feed("cn", "\(start)")
                items.forEach { feedItem("cn", $0) }
            case .tasks(let items):
                items.forEach { item in
                    feed(item.checked ? "ct1" : "ct0", item.text)
                    item.children.forEach { feedChild($0) }
                }
            default: break
            }
        }
        func feedItem(_ tag: String, _ item: MarkdownBlocksView.ListItem) {
            feed(tag, item.text)
            item.children.forEach { feedChild($0) }
        }
        for block in run {
            switch block {
            case .paragraph(let text): feed("p", text)
            case .heading(let level, let text): feed("h\(level)", text)
            case .bullets(let items): items.forEach { feedItem("b", $0) }
            case .numbered(let start, let items):
                feed("n", "\(start)")
                items.forEach { feedItem("n", $0) }
            case .tasks(let items):
                items.forEach { item in
                    feed(item.checked ? "t1" : "t0", item.text)
                    item.children.forEach { feedChild($0) }
                }
            default: break
            }
        }
        return (UInt64(bitPattern: Int64(hasher.finalize())), characters)
    }

    private func inline(_ text: String) -> AttributedString {
        MarkdownText.inlineAttributed(text, linkColor: linkColor,
                                      palette: palette, agentFileLinks: agentFileLinks)
    }

    private func build() -> AttributedString {
        var result = AttributedString()
        for (index, block) in run.enumerated() {
            if index > 0 { result += Self.blockGap(isDocument: isDocument) }
            switch block {
            case .paragraph(let content):
                result += inline(content)

            case .heading(let level, let content):
                var heading = inline(content)
                // Only ranges without their own font (inline code keeps mono).
                for r in heading.runs where r.font == nil {
                    heading[r.range].font = headingFont(level)
                }
                result += heading

            case .bullets, .numbered, .tasks:
                result += list(block, depth: 0)

            default:
                break
            }
        }
        return result
    }

    /// Lists inside a prose run, rendered recursively into the SAME
    /// AttributedString — selection cannot cross view boundaries, so a nested
    /// list must not become its own view. Depth shows as leading spaces: an
    /// attributed run has no padding, and two spaces per level line up with
    /// the glyph column closely enough to read as nesting.
    private func list(_ block: MarkdownBlocksView.Block, depth: Int) -> AttributedString {
        var result = AttributedString()
        let pad = AttributedString(String(repeating: "  ", count: depth))

        func appendItem(_ marker: AttributedString, _ text: AttributedString,
                        children: [MarkdownBlocksView.Block], first: Bool) {
            if !first || depth > 0 { result += AttributedString("\n") }
            result += pad + marker + AttributedString(" ") + text
            for child in children {
                switch child {
                case .bullets, .numbered, .tasks:
                    result += list(child, depth: depth + 1)
                case .paragraph(let content):
                    result += AttributedString("\n") + pad + AttributedString("  ") + inline(content)
                default:
                    break
                }
            }
        }

        switch block {
        case .bullets(let items):
            for (i, item) in items.enumerated() {
                var glyph = AttributedString(palette.isGlass ? "•" : palette.bulletGlyph)
                glyph.font = .system(size: 13)
                if !palette.isGlass {
                    glyph.foregroundColor = palette.bulletColor ?? palette.ink
                }
                appendItem(glyph, inline(item.text), children: item.children, first: i == 0)
            }

        case .numbered(let start, let items):
            for (i, item) in items.enumerated() {
                var number = AttributedString("\(start + i).")
                number.font = .system(size: isDocument ? 13.5 : 12.5)
                number.foregroundColor = palette.isGlass ? Color.secondary : palette.secondaryText
                appendItem(number, inline(item.text), children: item.children, first: i == 0)
            }

        case .tasks(let items):
            for (i, item) in items.enumerated() {
                var box = AttributedString(item.checked ? "☑" : "☐")
                box.foregroundColor = item.checked
                    ? (palette.isGlass ? Color.accentColor : palette.accent)
                    : (palette.isGlass ? Color.secondary : palette.secondaryText)
                var text = inline(item.text)
                if item.checked {
                    text.foregroundColor = palette.isGlass ? Color.secondary : palette.secondaryText
                }
                appendItem(box, text, children: item.children, first: i == 0)
            }

        default:
            break
        }
        return result
    }

    /// Thin spacer line between blocks (≈ the old VStack spacing).
    private static func blockGap(isDocument: Bool) -> AttributedString {
        var gap = AttributedString("\n\u{200B}\n")
        gap.font = .system(size: isDocument ? 7 : 4)
        return gap
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
}
