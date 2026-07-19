import SwiftUI
import WebKit
import UniformTypeIdentifiers

// MARK: - Artifact kinds

/// What kind of deliverable document the fenced block carries.
enum ArtifactKind {
    case html
    case markdown

    var icon: String {
        switch self {
        case .html: return "globe"
        case .markdown: return "doc.text"
        }
    }

    var fileExtension: String {
        switch self {
        case .html: return "html"
        case .markdown: return "md"
        }
    }

    var contentType: UTType {
        switch self {
        case .html: return .html
        case .markdown: return UTType(filenameExtension: "md") ?? .plainText
        }
    }

    /// Subtitle under the card title.
    var typeLabel: String {
        switch self {
        case .html: return L("artifact.interactive")
        case .markdown: return L("artifact.mdDoc")
        }
    }

    /// Title fallback when the document itself doesn't name one.
    var untitledLabel: String {
        switch self {
        case .html: return L("artifact.untitled")
        case .markdown: return L("artifact.mdDoc")
        }
    }

    /// Document title: `<title>` for HTML, the first `#` heading for Markdown.
    func extractTitle(from content: String) -> String? {
        switch self {
        case .html:
            guard let range = content.range(
                of: "<title[^>]*>([^<]*)</title>",
                options: [.regularExpression, .caseInsensitive]
            ) else { return nil }
            let tag = String(content[range])
            guard let open = tag.range(of: ">"),
                  let close = tag.range(of: "</", options: .backwards) else { return nil }
            let inner = tag[open.upperBound..<close.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return inner.isEmpty ? nil : inner
        case .markdown:
            for line in content.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("#") else { continue }
                let heading = trimmed.drop(while: { $0 == "#" })
                    .trimmingCharacters(in: .whitespaces)
                return heading.isEmpty ? nil : heading
            }
            return nil
        }
    }
}

// MARK: - Inline artifact card

/// Chat-bubble card for a document artifact (an HTML page or a Markdown
/// document the model produced in a fenced block). While the fence is still
/// streaming the card shows a spinner and the growing size; once complete,
/// clicking it opens the preview window. Styled through `ThemePalette` so
/// every theme (glass, Halloween, Día, Sakura, Blueprint, Terminal, …)
/// keeps its look.
struct ArtifactCardView: View {
    let kind: ArtifactKind
    let content: String
    let complete: Bool
    /// The stream ended without closing the fence — the document was likely
    /// cut off by the max-tokens limit. Still openable; flagged in the subtitle.
    var truncated: Bool = false
    @State private var isHovering = false
    @Environment(\.themePalette) private var palette

    private var title: String {
        kind.extractTitle(from: content) ?? kind.untitledLabel
    }

    private var sizeLabel: String {
        let bytes = content.utf8.count
        if bytes < 1024 { return "\(bytes) B" }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }

    var body: some View {
        // A real Button, not onTapGesture: the bubble wraps all markdown in
        // `.textSelection(.enabled)`, and over text regions clicks start a
        // selection instead of reaching a tap gesture — a button (with
        // selection disabled inside) receives the click over its whole area.
        Button {
            ArtifactPreview.show(kind: kind, content: content, title: title)
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(iconBackground)
                        .frame(width: 34, height: 34)
                    if complete {
                        Image(systemName: kind.icon)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(accentColor)
                    } else {
                        ThinkingEqualizer()
                            .scaleEffect(0.8)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(complete ? title : L("artifact.generating"))
                        .font(.system(size: 12.5, weight: .semibold, design: palette.fontDesign))
                        .foregroundColor(palette.isGlass ? .primary : palette.primaryText)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10.5, design: palette.fontDesign))
                        .foregroundColor(truncated ? .orange : (palette.isGlass ? .secondary : palette.secondaryText))
                }

                Spacer(minLength: 8)

                if complete {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(isHovering ? accentColor : (palette.isGlass ? .secondary : palette.secondaryText))
                }
            }
            .textSelection(.disabled)
            .padding(10)
            .frame(maxWidth: 280, alignment: .leading)
            .background(palette.isGlass ? AnyShapeStyle(Color.secondary.opacity(0.12)) : palette.codeFill)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        isHovering && complete
                            ? accentColor.opacity(0.55)
                            : (palette.isGlass ? Color.secondary.opacity(0.18) : palette.ink.opacity(0.22)),
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!complete)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) { isHovering = hovering }
        }
        .help(complete ? L("artifact.open") : L("artifact.generating"))
    }

    private var subtitle: String {
        guard complete else { return sizeLabel }
        if truncated { return "\(L("artifact.truncated")) · \(sizeLabel)" }
        return "\(kind.typeLabel) · \(sizeLabel)"
    }

    private var accentColor: Color {
        palette.isGlass ? .accentColor : palette.accent
    }

    private var iconBackground: Color {
        accentColor.opacity(0.16)
    }
}

// MARK: - Preview window

/// One shared floating window that shows the artifact: rendered preview
/// (WKWebView for HTML, the app's own Markdown renderer for .md) with a Code
/// tab, plus Save / Open-in-Browser / Copy actions. Re-showing a different
/// artifact reuses the window.
@MainActor
enum ArtifactPreview {
    private static var window: NSWindow?

    /// Preview size: always two thirds of the screen, centered.
    private static var previewSize: NSSize {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSSize(width: screen.width * 2 / 3, height: screen.height * 2 / 3)
    }

    static func show(kind: ArtifactKind, content: String, title: String) {
        let hosting = NSHostingController(
            rootView: ArtifactPreviewView(kind: kind, content: content, title: title)
        )
        if let window {
            window.contentViewController = hosting
            window.title = title
            window.setContentSize(previewSize)
            window.center()
            window.makeKeyAndOrderFront(nil)
        } else {
            let newWindow = NSWindow(contentViewController: hosting)
            newWindow.title = title
            newWindow.styleMask = [.titled, .closable, .resizable]
            newWindow.setContentSize(previewSize)
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            newWindow.level = .floating
            window = newWindow
            newWindow.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Safe file-name stem derived from the artifact title.
    static func fileStem(for title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let cleaned = title.unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "-" }
            .reduce(into: "") { $0.append($1) }
            .trimmingCharacters(in: CharacterSet(charactersIn: "- "))
        return cleaned.isEmpty ? "artifact" : cleaned
    }
}

private struct ArtifactPreviewView: View {
    let kind: ArtifactKind
    let content: String
    let title: String
    @State private var showCode = false
    @State private var justCopied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $showCode) {
                    Text(L("artifact.preview")).tag(false)
                    Text(L("artifact.code")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)

                Spacer()

                Button(action: copy) {
                    Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                        .foregroundColor(justCopied ? .green : .primary)
                }
                .help(L("artifact.copy"))

                if kind == .html {
                    Button(action: openInBrowser) {
                        Image(systemName: "safari")
                    }
                    .help(L("artifact.openBrowser"))
                }

                Button(action: save) {
                    Image(systemName: "square.and.arrow.down")
                }
                .help(L("artifact.save"))
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if showCode {
                ScrollView([.vertical, .horizontal]) {
                    Text(content)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                switch kind {
                case .html:
                    ArtifactWebView(html: content)
                case .markdown:
                    // Notion-like reading column: document typography, capped
                    // line length, generous margins.
                    ScrollView {
                        MarkdownBlocksView(text: content, linkColor: .accentColor, style: .document)
                            .textSelection(.enabled)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 28)
                            .frame(maxWidth: 720, alignment: .topLeading)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        withAnimation { justCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation { justCopied = false }
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [kind.contentType]
        panel.nameFieldStringValue = ArtifactPreview.fileStem(for: title) + "." + kind.fileExtension
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSSound.beep()
            Diagnostics.log("artifact", "save.failed \(error.localizedDescription)")
        }
    }

    private func openInBrowser() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AISpotlightArtifacts", isDirectory: true)
        let url = dir
            .appendingPathComponent(ArtifactPreview.fileStem(for: title))
            .appendingPathExtension(kind.fileExtension)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(url)
        } catch {
            NSSound.beep()
            Diagnostics.log("artifact", "openBrowser.failed \(error.localizedDescription)")
        }
    }
}

/// Minimal WKWebView wrapper. JS stays on (the whole point is interactivity);
/// content is loaded from a string, so nothing touches the user's cookies or
/// browsing data (non-persistent store).
private struct ArtifactWebView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString(html, baseURL: nil)
        context.coordinator.lastHTML = html
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        webView.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator {
        var lastHTML: String?
    }
}
