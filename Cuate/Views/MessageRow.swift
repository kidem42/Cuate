import SwiftUI
import Foundation
import AppKit

struct MessageRow: View {
    /// Telegram-style pin entry for the bubble's context menu (agent chats
    /// only; nil elsewhere). Lives here because the bubble's own context
    /// menu (CopyableBubble) shadows any menu attached by the row's host.
    struct PinMenu {
        let isPinned: Bool
        let toggle: () -> Void
    }

    let message: ChatMessage
    /// Bubbles scale with the panel: ~75% of the available width.
    var maxBubbleWidth: CGFloat = 320
    /// Whether this message is the reply currently being streamed. Artifact
    /// cards use it to tell "fence still coming" from "stream ended with the
    /// fence never closed" (e.g. cut off by the max-tokens limit) — the
    /// latter must render as an openable card, not spin forever.
    var isStreamingReply: Bool = false
    /// Live streaming buffer. When set, the assistant bubble renders the
    /// growing reply from this model (frozen segments + cheap tail) instead
    /// of `message.text` — and ONLY the text portion observes it, so a
    /// stream flush re-lays-out nothing but the tail. `message` then only
    /// contributes identity, timestamp and the bubble chrome.
    var liveModel: StreamingReplyModel? = nil
    /// Pin/unpin context-menu entry (agent chats); nil hides it.
    var pinMenu: PinMenu? = nil

    // Hover-to-copy (selecting across SwiftUI Text blocks is unreliable,
    // so whole-message copy is the primary affordance, like in Telegram)
    @State private var isHovering = false
    @State private var justCopied = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.themePalette) private var palette

    /// Bubble body text: system `.primary` for glass, else the palette's own
    /// spec color (Blueprint #eaf6ff/#0c2233, Día #fff0e0/#3d0d20, …) so the
    /// text reads on the theme's tinted bubbles instead of the system default.
    private var bubbleTextColor: Color {
        palette.isGlass ? .primary : palette.primaryText
    }

    /// In-bubble link/URL color: system accent for glass, the theme's ink
    /// accent otherwise (Día light uses the deeper #C77800, not the bright
    /// marigold, for legibility).
    private var linkTint: Color {
        palette.isGlass ? .accentColor : palette.ink
    }

    var body: some View {
        HStack {
            if message.messageType == .system {
                Spacer()
                systemMessageBubble
                Spacer()
            } else if message.isUser {
                Spacer()
                userMessageBubble
            } else {
                assistantMessageBubble
                Spacer()
            }
        }
        .padding(.horizontal, 4)
    }
    
    private var userMessageBubble: some View {
        // Agent file note ("Attached files…\n- path") renders as PILLS, not
        // raw paths — the text block stays in the stored message for the
        // agent to read (AgentAttachNote is the shared contract).
        let attachSplit = AgentAttachNote.split(message.text)
        return VStack(alignment: .trailing, spacing: 4) {
            VStack(alignment: .trailing, spacing: 8) {
                userAttachmentsSection()

                if message.messageType == .voice {
                    if let audioURL = message.audioURL {
                        VoiceMessagePlayer(audioURL: audioURL, isUserMessage: true)
                            .frame(maxWidth: 280)
                    }
                    // Show the transcribed text below the player
                    if !message.text.isEmpty {
                        renderMarkdownText(message.text, linkColor: linkTint)
                            .foregroundColor(bubbleTextColor)
                            .textSelection(.enabled)
                            .multilineTextAlignment(.leading)
                    }
                } else {
                    if !attachSplit.display.isEmpty {
                        renderMarkdownText(attachSplit.display, linkColor: linkTint)
                            .foregroundColor(bubbleTextColor)
                            .textSelection(.enabled)
                            .multilineTextAlignment(.leading)
                    }
                    if !attachSplit.paths.isEmpty {
                        // Images the courier put on the agent's host render
                        // inline — that is what makes a photo sent from
                        // ANOTHER device visible here (this device has no
                        // pixels of its own for it). The sending device
                        // already shows its local attachment, so it skips
                        // this to avoid showing the same image twice.
                        let imagePaths = message.attachments.isEmpty
                            ? attachSplit.paths.filter {
                                HermesFileCourier.imageExtensions.contains(
                                    ($0 as NSString).pathExtension.lowercased())
                            }
                            : []
                        ForEach(imagePaths, id: \.self) { path in
                            if let url = HermesFileCourier.downloadURL(forRemotePath: path) {
                                AgentInlineImageView(
                                    urlString: url.absoluteString,
                                    alt: (path as NSString).lastPathComponent
                                )
                            }
                        }
                        let filePaths = attachSplit.paths.filter { !imagePaths.contains($0) }
                        if !filePaths.isEmpty {
                            AgentAttachPillsView(paths: filePaths)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            // Current theme: material + accent tint through glass. Other
            // themes: solid/gradient fill with their own corners + border.
            .modifier(ThemedBubble(palette: palette, isUser: true))
            // Subtle elevation separates content from the surface beneath
            .shadow(color: Color.black.opacity(0.10), radius: 2.5, x: 0, y: 1)
            // Synthwave's neon glow on the user bubble; nil → invisible.
            .shadow(color: palette.userGlow ?? .clear, radius: 7)
            .modifier(CopyableBubble(text: { message.text }, isHovering: $isHovering,
                                     justCopied: $justCopied, pin: pinMenu))

            Text(formatTime(message.timestamp))
                .font(palette.timestampMono ? .system(.caption2, design: .monospaced) : .caption2)
                .tracking(palette.timestamp == .uppercaseMeridiem ? 1.5 : 0)
                .foregroundColor(palette.isGlass ? .secondary : palette.timestampColor)
        }
        .frame(maxWidth: maxBubbleWidth, alignment: .trailing)
    }
    
    private var assistantMessageBubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                // No trailing Spacer: it used to stretch every assistant
                // bubble to the full 75% width — image-only results looked
                // like a small picture lost in an empty field. The bubble
                // now hugs its content (long text still fills the width).
                assistantIcon

                assistantAttachmentsSection()

                if let liveModel {
                    StreamingReplyText(model: liveModel, linkColor: linkTint)
                        .foregroundColor(bubbleTextColor)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.leading)
                } else if message.messageType == .voice {
                    // Voice message from assistant (rare case, but supported)
                    if let audioURL = message.audioURL {
                        VoiceMessagePlayer(audioURL: audioURL, isUserMessage: false)
                            .frame(maxWidth: 280)
                    }
                    // Also show transcribed text if available
                    if !message.text.isEmpty {
                        renderMarkdownText(message.text, linkColor: linkTint)
                            .foregroundColor(bubbleTextColor)
                            .textSelection(.enabled)
                            .multilineTextAlignment(.leading)
                    }
                } else {
                    renderMarkdownText(message.text, linkColor: linkTint)
                        .foregroundColor(bubbleTextColor)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            // Same gate as the chips row below: only agent replies rewrite
            // in-text paths into AgentFileLink links.
            .environment(\.agentFileLinksEnabled,
                         message.agentSteps != nil || message.externalID != nil)
            .modifier(ThemedBubble(palette: palette, isUser: false))
            .shadow(color: Color.black.opacity(0.10), radius: 2.5, x: 0, y: 1)
            .modifier(CopyableBubble(
                text: { [liveModel] in liveModel?.fullText ?? message.text },
                isHovering: $isHovering, justCopied: $justCopied, pin: pinMenu))

            // Agent replies: collapsible tool-step journal, persisted on the
            // message (AgentGateway; nil for ordinary provider replies).
            // A second level lazily pulls the full command/output/exit from
            // the gateway transcript, keyed by the message's gateway row id.
            if let steps = message.agentSteps, !steps.isEmpty {
                AgentStepJournalView(
                    summary: steps,
                    detailLoader: message.seq.map { seq in
                        { await HermesStepDetails.details(forAssistantSeq: seq) }
                    }
                )
                .padding(.leading, 4)
            }

            // Agent replies: files the agent mentioned by path — reveal in
            // Finder when the gateway host is this Mac, copy otherwise.
            // Gated on agent-row markers so ordinary chats never scan text.
            if message.agentSteps != nil || message.externalID != nil {
                AgentFileChipsView(messageText: message.text, messageDate: message.timestamp)
                    .padding(.leading, 4)
            }

            Text(formatTime(message.timestamp))
                .font(palette.timestampMono ? .system(.caption2, design: .monospaced) : .caption2)
                .tracking(palette.timestamp == .uppercaseMeridiem ? 1.5 : 0)
                .foregroundColor(palette.isGlass ? .secondary : palette.timestampColor)
        }
        .frame(maxWidth: maxBubbleWidth, alignment: .leading)
    }

    private var systemMessageBubble: some View {
        VStack(alignment: .center, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundColor(.secondary)
                    .font(.caption)
                renderMarkdownText(message.text, linkColor: .secondary)
                    .foregroundColor(.secondary)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Text(formatTime(message.timestamp))
                .font(palette.timestampMono ? .system(.caption2, design: .monospaced) : .caption2)
                .tracking(palette.timestamp == .uppercaseMeridiem ? 1.5 : 0)
                .foregroundColor(palette.isGlass ? .secondary : palette.timestampColor)
        }
        .frame(maxWidth: maxBubbleWidth, alignment: .center)
    }
    
    // MARK: - Copy affordance

    /// DateFormatter creation is famously expensive — building one per
    /// `formatTime` call meant one per row per body evaluation. One formatter
    /// per format string, reused forever (SwiftUI bodies run on the main
    /// thread, so the unsynchronized dictionary is safe).
    private static var timeFormatters: [String: DateFormatter] = [:]

    private static func cachedFormatter(_ key: String, make: () -> DateFormatter) -> DateFormatter {
        if let cached = timeFormatters[key] { return cached }
        let formatter = make()
        timeFormatters[key] = formatter
        return formatter
    }

    /// POSIX-locale formatter for the themed timestamp formats.
    private static func posixFormatter(_ format: String) -> DateFormatter {
        cachedFormatter(format) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            return formatter
        }
    }

    /// The Current theme keeps the localized short time; every other theme has
    /// a signature timestamp format from the design spec.
    private func formatTime(_ date: Date) -> String {
        if palette.timestamp == .glass {
            let formatter = Self.cachedFormatter("glass.short") {
                let formatter = DateFormatter()
                formatter.timeStyle = .short
                return formatter
            }
            return formatter.string(from: date)
        }
        switch palette.timestamp {
        case .glass, .plain:
            return Self.posixFormatter("HH:mm").string(from: date)
        case .bracketed:
            return "[\(Self.posixFormatter("HH:mm").string(from: date))]"
        case .seconds:
            return Self.posixFormatter("HH:mm:ss").string(from: date)
        case .uppercaseMeridiem:
            return Self.posixFormatter("hh:mm a").string(from: date).uppercased()
        case .flowerSuffix:
            return "\(Self.posixFormatter("HH:mm").string(from: date)) ✿"
        case .lowercaseMeridiem:
            let ampm = Calendar.current.component(.hour, from: date) < 12 ? "a.m." : "p.m."
            return "\(Self.posixFormatter("hh:mm").string(from: date)) \(ampm)"
        }
    }

    /// Assistant bubble icon: the brain for Current, a themed glyph otherwise.
    @ViewBuilder
    private var assistantIcon: some View {
        if palette.isGlass {
            Image(systemName: "brain")
                .foregroundColor(.accentColor)
                .font(.caption)
        } else if palette.themeID == .diaDeMuertos {
            SugarSkull(dark: colorScheme == .dark)
        } else if palette.themeID == .halloween {
            PumpkinIcon(dark: colorScheme == .dark)
        } else {
            Text(palette.assistantGlyph)
                .foregroundColor(palette.glyphColor)
                .font(.caption)
        }
    }
    
    /// Block-level rendering: headings, lists, quotes, code blocks and tables
    /// all display formatted (Telegram-style), not as raw markdown.
    private func renderMarkdownText(_ text: String, linkColor: Color = .blue) -> some View {
        MarkdownBlocksView(text: text, linkColor: linkColor, isStreaming: isStreamingReply)
    }

    /// Image previews scale with the panel: ~70% of the bubble width
    /// (bubbles are ~75% of the window), never below the legacy 220pt.
    /// SwiftUI re-evaluates this on window resize, so previews follow.
    private var attachmentPreviewWidth: CGFloat {
        max(220, maxBubbleWidth * 0.7)
    }

    @ViewBuilder
    private func userAttachmentsSection() -> some View {
        if !message.attachments.isEmpty {
            VStack(alignment: .trailing, spacing: 8) {
                ForEach(message.attachments) { attachment in
                    AttachmentPreviewBubble(attachment: attachment, maxImageWidth: attachmentPreviewWidth)
                }
            }
        }
    }

    @ViewBuilder
    private func assistantAttachmentsSection() -> some View {
        if !message.attachments.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(message.attachments) { attachment in
                    AttachmentPreviewBubble(attachment: attachment, maxImageWidth: attachmentPreviewWidth)
                    // ImageAddon (Addons/ImageAddon): Save/Copy under images
                    // the assistant produced; renders nothing when disabled.
                    ImageResultActionsBar(attachment: attachment)
                }
            }
        }
    }
}

/// Encodes/decodes tap-to-copy payloads carried in a custom URL scheme so
/// inline-code runs inside a SwiftUI Text become clickable (Telegram-style).
enum CopyLink {
    static let scheme = "cuate-copy"

    static func encode(_ text: String) -> URL? {
        let base64 = Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return URL(string: "\(scheme):\(base64)")
    }

    static func decode(_ url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        var base64 = url.absoluteString
            .replacingOccurrences(of: "\(scheme):", with: "")
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Hover-to-copy affordance for chat bubbles: a small floating copy button
/// on hover plus a right-click context menu. Copies the whole message as raw
/// Markdown (cross-block text selection in SwiftUI is unreliable). Also
/// intercepts taps on inline-code runs (CopyLink) — clicking `code` copies it.
struct CopyableBubble: ViewModifier {
    /// Resolved at click time, not at body evaluation — the streaming bubble
    /// re-renders only its text subtree per flush, so a captured String here
    /// would go stale mid-stream.
    let text: () -> String
    @Binding var isHovering: Bool
    @Binding var justCopied: Bool
    /// Optional pin/unpin entry appended to the context menu (agent chats).
    var pin: MessageRow.PinMenu? = nil

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { url in
                if let payload = CopyLink.decode(url) {
                    copyPayload(payload)
                    return .handled
                }
                if let path = AgentFileLink.decode(url) {
                    AgentFileLink.open(path)
                    return .handled
                }
                return .systemAction
            })
            // The button stays in the hierarchy and is hidden via opacity —
            // inserting/removing it on hover rebuilt the tracking areas and
            // made the icon flicker (and vanish when the cursor reached it).
            .overlay(alignment: .topTrailing) {
                Button(action: copy) {
                    Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(justCopied ? .green : .secondary)
                        .frame(width: 20, height: 20)
                        // Material ONLY while shown: the hidden (opacity 0)
                        // button used to keep a live backdrop-blur layer on
                        // EVERY bubble, and each one taxes the compositor on
                        // every scrolled frame (WindowServer at 70–90% while
                        // scrolling — profiled 2026-07-28). The swap keeps
                        // the button's identity, so no tracking-area rebuild
                        // and none of the old hover flicker.
                        .background(isHovering || justCopied
                                    ? AnyShapeStyle(.ultraThinMaterial)
                                    : AnyShapeStyle(Color.clear),
                                    in: Circle())
                        .overlay(Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))
                }
                .buttonStyle(PlainButtonStyle())
                .help(L("tooltip.copy"))
                .padding(4)
                .opacity(isHovering || justCopied ? 1 : 0)
                .allowsHitTesting(isHovering || justCopied)
                .animation(.easeInOut(duration: 0.12), value: isHovering || justCopied)
            }
            // After the overlay, so hovering the button itself counts as
            // hovering the bubble and doesn't dismiss it.
            .onHover { hovering in
                isHovering = hovering
            }
            .contextMenu {
                Button {
                    copy()
                } label: {
                    Label(L("tooltip.copy"), systemImage: "doc.on.doc")
                }
                if let pin {
                    Button {
                        pin.toggle()
                    } label: {
                        Label(pin.isPinned ? AGL("agent.pin.unpin") : AGL("agent.pin.pin"),
                              systemImage: pin.isPinned ? "pin.slash" : "pin")
                    }
                }
            }
    }

    private func copy() {
        copyPayload(text())
    }

    private func copyPayload(_ payload: String) {
        // Messages with pipe tables also publish an HTML flavor: spreadsheets
        // (Sheets/Excel/Numbers) only split a paste into cells from an HTML
        // <table>, while plain-text targets keep receiving the raw markdown.
        MarkdownBlocksView.copyMarkdownToPasteboard(payload)
        withAnimation { justCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation { justCopied = false }
        }
    }
}

struct MarkdownText: View {
    let text: String
    let linkColor: Color
    @Environment(\.themePalette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    // Agent replies only: file paths in prose become clickable
    // (AgentFileLink) — download/open through the same pipeline as the
    // chips, instead of reading as dead text.
    @Environment(\.agentFileLinksEnabled) private var agentFileLinks

    init(_ text: String, linkColor: Color = .blue) {
        self.text = text
        self.linkColor = linkColor
    }

    /// Memoizes the rendered AttributedString. `renderMarkdown` (markdown
    /// parse + URL detection + run styling) used to run on EVERY body
    /// evaluation — per streamed flush of the growing bubble and per
    /// re-layout of every visible row. The output depends only on the text
    /// and the theme context, so it is cached by that key; NSCache evicts
    /// under pressure and the count cap bounds the streaming case.
    private final class RenderBox {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }
    private static let renderCache: NSCache<NSString, RenderBox> = {
        let cache = NSCache<NSString, RenderBox>()
        cache.countLimit = 512
        return cache
    }()

    var body: some View {
        Text(cachedRender())
            .fixedSize(horizontal: false, vertical: true) // preserve line breaks/height
    }

    private func cachedRender() -> AttributedString {
        let key = "\(palette.themeID)|\(colorScheme)|\(linkColor)|\(agentFileLinks)|\(text)" as NSString
        if let boxed = Self.renderCache.object(forKey: key) { return boxed.value }
        let rendered = Self.inlineAttributed(text, linkColor: linkColor,
                                             palette: palette, agentFileLinks: agentFileLinks)
        Self.renderCache.setObject(RenderBox(rendered), forKey: key)
        return rendered
    }

    /// The inline pipeline as a reusable function: markdown parse, URL and
    /// agent-path linkification, inline-code chips, link styling. Static so
    /// the merged prose renderer (`ProseRunText` — one Text per run of prose
    /// blocks, for cross-block selection) shares the exact same look.
    static func inlineAttributed(_ text: String, linkColor: Color,
                                 palette: ThemePalette, agentFileLinks: Bool) -> AttributedString {
        // Use inline-only parsing that preserves whitespace and newlines
        var attributed: AttributedString
        if let parsed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            attributed = parsed
        } else {
            attributed = AttributedString(text)
        }
        
        // Auto-link raw URLs
        attributed = linkifyRawURLs(in: attributed)

        // Agent replies: file paths in prose act like the chips below the
        // bubble ("Файл: /root/map.html" was dead text — e2e 2026-07-27).
        // After the URL pass so a path inside a URL is never double-linked.
        if agentFileLinks {
            attributed = linkifyAgentPaths(in: attributed, linkColor: linkColor)
        }

        // Inline monospace → Telegram-style: sits right in the text body and
        // is barely distinguishable from it (mono font, whisper of a backing)
        // — distinct from fenced code blocks, which render as separate cards.
        // Clicking the span copies it (CopyLink handled by the bubble).
        for run in attributed.runs {
            guard let intent = run.inlinePresentationIntent, intent.contains(.code) else { continue }
            let range = run.range
            let codeText = String(attributed[range].characters)
            attributed[range].font = .system(size: 12.5, design: .monospaced)
            // Themed chip (Día: pale-gold backing + #FFCE7A/#9a5c00 text);
            // glass keeps the whisper-of-a-backing default.
            attributed[range].backgroundColor = palette.isGlass
                ? Color.secondary.opacity(0.08)
                : (palette.inlineCodeFill ?? Color.secondary.opacity(0.08))
            if !palette.isGlass {
                attributed[range].foregroundColor = palette.inlineCodeText ?? palette.codeText
            }
            if let url = CopyLink.encode(codeText) {
                attributed[range].link = url
            }
        }

        // Style links (skip copy-links — they keep the code look, no underline)
        for run in attributed.runs {
            guard let link = run.link, link.scheme != CopyLink.scheme else { continue }
            let range = run.range
            attributed[range].foregroundColor = linkColor
            attributed[range].underlineStyle = .single
        }

        return attributed
    }
    
    /// Shared detector: creating an NSDataDetector compiles a regex — doing
    /// that per render (per streamed token on the growing message) burned
    /// main-thread CPU for nothing. NSDataDetector is thread-safe.
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Turns file-path mentions into AgentFileLink links, mono-styled so
    /// they read as "a thing on disk" (the inline-code look) rather than a
    /// web link. Runs that already carry a link (URLs, code copy-links)
    /// are left alone.
    private static func linkifyAgentPaths(in attributed: AttributedString,
                                          linkColor: Color) -> AttributedString {
        var result = attributed
        let plain = String(result.characters)
        for path in AgentFilePaths.extract(from: plain) {
            var searchRange = plain.startIndex..<plain.endIndex
            while let found = plain.range(of: path, range: searchRange) {
                searchRange = found.upperBound..<plain.endIndex
                guard let lower = AttributedString.Index(found.lowerBound, within: result),
                      let upper = AttributedString.Index(found.upperBound, within: result),
                      !result[lower..<upper].runs.contains(where: { $0.link != nil }),
                      let url = AgentFileLink.encode(path) else { continue }
                result[lower..<upper].link = url
                result[lower..<upper].font = .system(size: 12.5, design: .monospaced)
                result[lower..<upper].foregroundColor = linkColor
                result[lower..<upper].underlineStyle = .single
            }
        }
        return result
    }

    private static func linkifyRawURLs(in attributed: AttributedString) -> AttributedString {
        var result = attributed
        let plain = String(result.characters)
        guard let detector = Self.linkDetector else {
            return result
        }
        let ns = plain as NSString
        let matches = detector.matches(in: plain, range: NSRange(location: 0, length: ns.length))
        
        for match in matches.reversed() {
            guard let url = match.url, let rangeInString = Range(match.range, in: plain) else { continue }
            if let lower = AttributedString.Index(rangeInString.lowerBound, within: result),
               let upper = AttributedString.Index(rangeInString.upperBound, within: result) {
                var sub = result[lower..<upper]
                sub.link = url
                result.replaceSubrange(lower..<upper, with: sub)
            }
        }
        return result
    }
}

/// Decoded-image cache keyed by attachment id. Decoding a multi-megabyte
/// image is expensive, and it used to run synchronously in `body` on the
/// FIRST render of every preview (file read + full-resolution decode on the
/// main thread — a slow first frame that could defeat the open-at-bottom
/// landing). Now: decode + downsample run off the main thread (`image(for:)`
/// is async), previews are capped at `maxPreviewPixels` (a Retina screenshot
/// decoded full-size is a ~50 MB bitmap drawn into a ~300 pt frame), and the
/// cache carries a real cost limit instead of relying on memory pressure.
enum AttachmentImageCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 128 * 1024 * 1024 // ~128 MB of decoded previews
        return cache
    }()

    /// Longest preview side in pixels — plenty for a ~360 pt @2x frame.
    private static let maxPreviewPixels: CGFloat = 1600

    /// Synchronous fast path: already-decoded previews only. Never decodes.
    static func cachedImage(for attachment: ChatAttachment) -> NSImage? {
        cache.object(forKey: attachment.id.uuidString as NSString)
    }

    /// Decodes (downsampled) off the main thread and caches the result.
    static func image(for attachment: ChatAttachment) async -> NSImage? {
        guard attachment.mimeType.hasPrefix("image") else { return nil }
        if let cached = cachedImage(for: attachment) { return cached }
        let decoded = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let data = attachment.data else { return nil }
            return downsample(data)
        }.value
        if let decoded {
            let cost = Int(decoded.size.width * decoded.size.height * 4)
            cache.setObject(decoded, forKey: attachment.id.uuidString as NSString, cost: cost)
        }
        return decoded
    }

    /// ImageIO thumbnail decode: never materializes the full-resolution
    /// bitmap for oversized sources. Falls back to a plain decode for data
    /// ImageIO cannot open.
    private static func downsample(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(
            data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            return NSImage(data: data)
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // bake in EXIF rotation
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPreviewPixels
        ] as [CFString: Any] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return NSImage(data: data)
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

private struct AttachmentPreviewBubble: View {
    let attachment: ChatAttachment
    /// Scales with the bubble (see `MessageRow.attachmentPreviewWidth`).
    let maxImageWidth: CGFloat
    /// Decoded preview; loaded asynchronously so the first render of a row
    /// never blocks the main thread on a file read + image decode.
    @State private var decodedImage: NSImage?

    var body: some View {
        // The bubble hugs the preview — no `.infinity` stretcher: an
        // image-only message must not blow the bubble up to full width.
        Group {
            if attachment.mimeType.hasPrefix("image"),
               let image = decodedImage ?? AttachmentImageCache.cachedImage(for: attachment) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    // maxHeight keeps portrait shots from towering over the
                    // chat; scaledToFit honors both bounds.
                    .frame(maxWidth: maxImageWidth, maxHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        AttachmentOpener.open(attachment)
                    }
            } else if attachment.mimeType.hasPrefix("image") {
                // Decode in flight — a quiet placeholder keeps the layout
                // from jumping when the image lands.
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.08))
                    .frame(width: min(maxImageWidth, 220), height: 140)
                    .overlay(ThinkingEqualizer().scaleEffect(0.8))
                    .task(id: attachment.id) {
                        decodedImage = await AttachmentImageCache.image(for: attachment)
                    }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "doc.fill")
                        .foregroundColor(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(attachment.filename)
                            .font(.callout)
                        Text(attachment.mimeType)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(12)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
                .onTapGesture {
                    AttachmentOpener.open(attachment)
                }
            }
        }
        .help(L("tooltip.attachment"))
    }
}

private enum AttachmentOpener {
    private static var trackedTemporaryFiles = Set<URL>()
    private static var cleanupRegistered = false

    static func open(_ attachment: ChatAttachment) {
        guard let data = attachment.data else { return }

        let sanitizedName = sanitizeFilename(attachment.filename)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CuateAttachments", isDirectory: true)
        let fileURL = directory.appendingPathComponent("\(attachment.id.uuidString)-\(sanitizedName)")

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            trackForCleanup(fileURL)
            NSWorkspace.shared.open(fileURL)
        } catch {
            NSLog("Failed to open attachment: \(error.localizedDescription)")
        }
    }

    private static func sanitizeFilename(_ filename: String) -> String {
        let illegalCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        return filename.components(separatedBy: illegalCharacters).joined(separator: "-")
    }

    private static func trackForCleanup(_ url: URL) {
        trackedTemporaryFiles.insert(url)
        registerCleanupObserverIfNeeded()
    }

    private static func registerCleanupObserverIfNeeded() {
        guard !cleanupRegistered else { return }
        cleanupRegistered = true
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            cleanupTemporaryFiles()
        }
    }

    private static func cleanupTemporaryFiles() {
        for url in trackedTemporaryFiles {
            try? FileManager.default.removeItem(at: url)
        }
        trackedTemporaryFiles.removeAll()
    }
}
