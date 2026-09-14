import SwiftUI

/// Service chrome and compact action pills shared with the chat.
struct HermesContinuationCard: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.colorScheme) private var scheme

    let checking: Bool
    let unavailable: Bool
    let approve: () -> Void
    let approveSession: () -> Void
    let deferRequest: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(HL("hermes.continuation.title"), systemImage: "arrow.turn.down.right")
                .font(.system(size: 11, weight: .medium, design: palette.fontDesign))
                .foregroundColor(palette.secondaryText)
            Text(HL("hermes.continuation.body"))
                .font(.system(size: 11, design: palette.fontDesign))
                .foregroundColor(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if checking {
                Text(HL("hermes.conn.testing"))
                    .font(.system(size: 11, design: palette.fontDesign))
                    .foregroundColor(palette.secondaryText)
            } else if unavailable {
                Text(HL("hermes.continuation.unavailable"))
                    .font(.system(size: 11, design: palette.fontDesign))
                    .foregroundColor(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { actions }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 8) { actions }
            }
            .disabled(checking)
        }
        .modifier(HermesServiceCardSurface())
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var actions: some View {
        Button(HL("hermes.continuation.once"), action: approve)
            .actionPillStyle(.generic(palette: palette, dark: scheme == .dark), glass: palette.isGlass)
            .help(HL("hermes.continuation.onceHelp"))
        Button(HL("hermes.continuation.session"), action: approveSession)
            .actionPillStyle(.generic(palette: palette, dark: scheme == .dark), glass: palette.isGlass)
            .help(HL("hermes.continuation.sessionHelp"))
        Button(HL("hermes.continuation.later"), action: deferRequest)
            .actionPillStyle(.generic(palette: palette, dark: scheme == .dark), glass: palette.isGlass)
            .help(HL("hermes.continuation.laterHelp"))
    }
}

/// A revocable session permission, kept separate from the composer and its send action.
struct HermesContinuationModeBar: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.colorScheme) private var scheme
    let revoke: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                status.fixedSize()
                Spacer(minLength: 8)
                revokeButton.fixedSize()
            }
            VStack(alignment: .leading, spacing: 6) {
                status.fixedSize(horizontal: false, vertical: true)
                revokeButton
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11, design: palette.fontDesign))
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(palette.ink.opacity(0.07))
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.inputStroke).frame(height: 1)
        }
    }

    private var status: some View {
        Label(HL("hermes.continuation.enabled"), systemImage: "checkmark.shield")
            .foregroundColor(palette.secondaryText)
    }

    private var revokeButton: some View {
        Button(HL("hermes.continuation.disable"), action: revoke)
            .actionPillStyle(.generic(palette: palette, dark: scheme == .dark), glass: palette.isGlass)
            .help(HL("hermes.continuation.disableHelp"))
    }
}

/// Dispatch evidence survives the parent reply. No live-parent/steer semantics.
struct HermesBackgroundWorkView: View {
    @Environment(\.themePalette) private var palette
    let work: [HermesBackgroundWork]
    @State private var visible = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let uncertain = work.contains { $0.isUnconfirmed(at: context.date) }
            HStack(spacing: 8) {
                ThinkingEqualizer(paused: !visible || uncertain)
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(format: HL("hermes.background.title"), work.reduce(0) { $0 + $1.count }))
                        .font(.system(size: 11, weight: .medium, design: palette.fontDesign))
                    Text(HL(uncertain ? "hermes.background.unconfirmed" : "hermes.background.waiting"))
                        .font(.system(size: 11, design: palette.fontDesign))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundColor(palette.secondaryText)
            }
            .modifier(HermesServiceCardSurface())
        }
        .onAppear { visible = true }
        .onDisappear { visible = false }
    }
}
