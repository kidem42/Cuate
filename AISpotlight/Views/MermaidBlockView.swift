import SwiftUI

/// Inline mermaid diagram in a chat bubble. The diagram is rendered offscreen
/// (see MermaidRenderer) and shown as a retina snapshot on a themed card, so
/// scrolling stays cheap and no live webviews live inside the transcript.
/// Click opens the interactive preview window (live SVG, zoom, export).
///
/// Quality-first failure path: while the fence streams the card shows a
/// spinner; a diagram that fails mermaid's parser degrades to a regular code
/// block with an orange badge instead of an error graphic.
struct MermaidBlockView: View {
    let code: String
    let complete: Bool
    @State private var result: Result<MermaidRenderer.Rendered, MermaidRenderer.RenderError>?
    @State private var isHovering = false
    @Environment(\.themePalette) private var palette
    @Environment(\.colorScheme) private var colorScheme

    private var theme: MermaidTheme {
        MermaidTheme.make(
            accent: palette.isGlass ? Color.accentColor : palette.accent,
            dark: colorScheme == .dark
        )
    }

    private var title: String {
        ArtifactKind.mermaid.extractTitle(from: code) ?? ArtifactKind.mermaid.untitledLabel
    }

    var body: some View {
        Group {
            if !complete {
                ArtifactCardView(kind: .mermaid, content: code, complete: false)
            } else {
                switch result {
                case nil:
                    ArtifactCardView(kind: .mermaid, content: code, complete: false)
                case .success(let rendered):
                    diagramCard(rendered)
                case .failure(let error):
                    errorFallback(error)
                }
            }
        }
        .task(id: complete ? "\(theme.key)|\(code)" : "") {
            guard complete else { return }
            result = await MermaidRenderer.shared.render(code: code, theme: theme)
        }
    }

    // MARK: Success

    private func diagramCard(_ rendered: MermaidRenderer.Rendered) -> some View {
        Button {
            ArtifactPreview.show(kind: .mermaid, content: code, title: title)
        } label: {
            Image(nsImage: rendered.image)
                .resizable()
                .scaledToFit()
                .frame(
                    maxWidth: min(rendered.size.width, 640),
                    maxHeight: min(rendered.size.height, 480)
                )
                .padding(12)
                .background(theme.backgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(
                            isHovering
                                ? accentColor.opacity(0.55)
                                : (palette.isGlass ? Color.secondary.opacity(0.18) : palette.ink.opacity(0.22)),
                            lineWidth: 1
                        )
                )
                .overlay(alignment: .topTrailing) {
                    if isHovering {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(accentColor)
                            .padding(7)
                            .transition(.opacity)
                    }
                }
                .textSelection(.disabled)
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) { isHovering = hovering }
        }
        .help(L("artifact.open"))
    }

    // MARK: Failure

    private func errorFallback(_ error: MermaidRenderer.RenderError) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(L("artifact.diagramError"), systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(.orange)
                .help(error.message)
            MarkdownBlocksView.CodeBlockView(content: code)
        }
    }

    private var accentColor: Color {
        palette.isGlass ? .accentColor : palette.accent
    }
}
