import SwiftUI

// MARK: - Shared AgentGateway UI (approval card, step journal, role chip)
//
// Every component draws exclusively from the ThemePalette in the environment
// (same rule as the rest of the chat: no hardcoded colors, no bare system
// materials) so agent UI follows Terminal/Pastel/seasonal themes like any
// native bubble.

/// Inline permission request: an assistant-style bubble carrying the action
/// text (monospaced), where it would run, and the resolution buttons.
/// Pattern: `ChatWindow.localStartConfirmBubble`.
struct AgentApprovalCard: View {
    @Environment(\.themePalette) private var palette

    let approval: AgentApproval
    let resolve: (AgentApprovalDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AGL("agent.approval.title"))
                .font(.system(size: 13, design: palette.fontDesign))
                .foregroundColor(palette.isGlass ? .primary : palette.ink)

            // The action verbatim, monospaced on a code backing — the human
            // approves exactly this text, so it must be legible and selectable.
            Text(approval.subject)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(palette.codeText)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.codeFill, in: RoundedRectangle(cornerRadius: 6))

            if let host = approval.hostDescription {
                Label(host, systemImage: "desktopcomputer")
                    .font(.system(size: 11, design: palette.fontDesign))
                    .foregroundColor(palette.secondaryText)
            }

            HStack(spacing: 8) {
                Button(AGL("agent.approval.allow")) { resolve(.approve) }
                    .buttonStyle(.borderedProminent)
                    .tint(palette.accent)
                if approval.supportsAlways {
                    Button(AGL("agent.approval.always")) { resolve(.approveAlways) }
                        .buttonStyle(.bordered)
                        .tint(palette.accent)
                }
                Button(AGL("agent.approval.deny")) { resolve(.deny) }
                    .buttonStyle(.bordered)
                    .tint(palette.accent)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .modifier(ThemedBubble(palette: palette, isUser: false))
        .shadow(color: Color.black.opacity(0.10), radius: 2.5, x: 0, y: 1)
    }
}

/// Collapsible tool-step journal shown under an agent reply. Renders either
/// live steps (during a turn) or a persisted summary (`ChatMessage.agentSteps`
/// parsed back after a restart).
struct AgentStepJournalView: View {
    @Environment(\.themePalette) private var palette
    @State private var expanded = false

    /// (tool, status, detail) rows — from live `AgentStep`s or a parsed summary.
    let rows: [(toolName: String, status: String, detail: String?)]

    init(steps: [AgentStep]) {
        self.rows = steps.map { step in
            var detail = step.duration.map { String(format: "%.1fs", $0) }
            if let preview = step.preview, !preview.isEmpty {
                detail = [detail, String(preview.prefix(120))].compactMap { $0 }.joined(separator: " · ")
            }
            return (step.toolName, step.status.rawValue, detail)
        }
    }

    init(summary: String) {
        self.rows = AgentStepJournal.parse(summary)
    }

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text("\(AGL("agent.steps.title")) · \(rows.count)")
                            .font(.system(size: 11, design: palette.fontDesign))
                    }
                    .foregroundColor(palette.secondaryText)
                }
                .buttonStyle(PlainButtonStyle())

                if expanded {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: statusSymbol(row.status))
                                .font(.system(size: 9))
                                .foregroundColor(statusColor(row.status))
                            Text(row.toolName)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(palette.primaryText)
                            if let detail = row.detail {
                                Text(detail)
                                    .font(.system(size: 11, design: palette.fontDesign))
                                    .foregroundColor(palette.secondaryText)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.leading, 14)
                }
            }
        }
    }

    private func statusSymbol(_ status: String) -> String {
        switch status {
        case AgentStep.Status.completed.rawValue: return "checkmark.circle"
        case AgentStep.Status.failed.rawValue: return "xmark.circle"
        default: return "circle.dotted"
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case AgentStep.Status.failed.rawValue: return .red
        default: return palette.ink
        }
    }
}

/// Header chip for the active agent role: icon + name + connection dot, in
/// the same visual language as the other header controls (11pt secondary
/// text, fixed 20pt row — see `ChatWindow.headerControlLabel`).
struct AgentRoleChip: View {
    @Environment(\.themePalette) private var palette

    let role: AgentRole
    let state: AgentConnectionState

    var body: some View {
        HStack(spacing: 4) {
            // The addon's brand glyph (Provider-<addonID> asset, template
            // monochrome — follows the header's secondary ink like the
            // provider logos); the emoji is only the no-asset fallback.
            ProviderGlyph(name: role.addonID,
                          fallbackLetter: String(role.icon.prefix(1)),
                          size: 12)
            Text(role.displayName)
                .font(.system(size: 11))
                .lineLimit(1)
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
        }
        .foregroundColor(.secondary)
        .frame(height: 20)
        .help(helpText)
    }

    private var dotColor: Color {
        switch state {
        case .connected: return .green
        case .degraded: return .yellow
        case .disconnected: return .red
        case .unknown: return .gray
        }
    }

    private var helpText: String {
        switch state {
        case .connected: return AGL("agent.chip.connected")
        case .degraded(let detail), .disconnected(let detail):
            return detail.isEmpty ? AGL("agent.chip.disconnected") : detail
        case .unknown: return AGL("agent.chip.disconnected")
        }
    }
}
