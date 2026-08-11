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
/// parsed back after a restart). A SECOND level expands per step: full
/// command, output and exit code are lazily fetched from the gateway
/// transcript via `detailLoader` (the persisted summary stays one line per
/// step); file paths inside become Finder shortcuts.
struct AgentStepJournalView: View {
    @Environment(\.themePalette) private var palette
    @State private var expanded = false
    @State private var expandedSteps: Set<Int> = []
    @State private var details: [AgentStepDetail]?
    @State private var loadingDetails = false

    /// (tool, status, detail) rows — from live `AgentStep`s or a parsed summary.
    let rows: [(toolName: String, status: String, detail: String?)]
    /// Fetches full per-step details on first expand (nil → no second level).
    var detailLoader: (() async -> [AgentStepDetail])?

    init(steps: [AgentStep], detailLoader: (() async -> [AgentStepDetail])? = nil) {
        self.rows = steps.map { step in
            var detail = step.duration.map { String(format: "%.1fs", $0) }
            if let preview = step.preview, !preview.isEmpty {
                detail = [detail, String(preview.prefix(120))].compactMap { $0 }.joined(separator: " · ")
            }
            return (step.toolName, step.status.rawValue, detail)
        }
        self.detailLoader = detailLoader
    }

    init(summary: String, detailLoader: (() async -> [AgentStepDetail])? = nil) {
        self.rows = AgentStepJournal.parse(summary)
        self.detailLoader = detailLoader
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
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        stepRow(index: index, row: row)
                    }
                    .padding(.leading, 14)
                }
            }
        }
    }

    @ViewBuilder
    private func stepRow(index: Int, row: (toolName: String, status: String, detail: String?)) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                toggleStep(index)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if detailLoader != nil {
                        Image(systemName: expandedSteps.contains(index) ? "chevron.down" : "chevron.right")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundColor(palette.secondaryText)
                    }
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
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            if expandedSteps.contains(index) {
                stepDetailView(index: index)
                    .padding(.leading, 18)
            }
        }
    }

    private func toggleStep(_ index: Int) {
        guard detailLoader != nil else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            if expandedSteps.contains(index) {
                expandedSteps.remove(index)
            } else {
                expandedSteps.insert(index)
            }
        }
        // One transcript fetch serves every row of this journal.
        if details == nil, !loadingDetails, let loader = detailLoader {
            loadingDetails = true
            Task { @MainActor in
                details = await loader()
                loadingDetails = false
            }
        }
    }

    @ViewBuilder
    private func stepDetailView(index: Int) -> some View {
        if let details {
            if index < details.count {
                let detail = details[index]
                VStack(alignment: .leading, spacing: 4) {
                    if let command = detail.command, !command.isEmpty {
                        HStack(alignment: .top, spacing: 6) {
                            ScrollView(.horizontal, showsIndicators: false) {
                                Text(command)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundColor(palette.codeText)
                                    .textSelection(.enabled)
                                    .padding(6)
                            }
                            if let exit = detail.exitCode {
                                Text("exit \(exit)")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(exit == 0 ? palette.secondaryText : .red)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.10), in: Capsule())
                                    .padding(.top, 4)
                            }
                        }
                        .background(palette.codeFill, in: RoundedRectangle(cornerRadius: 6))
                    }
                    if let output = detail.output, !output.isEmpty {
                        ScrollView {
                            Text(output)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundColor(palette.secondaryText)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6)
                        }
                        .frame(maxHeight: 160)
                        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    }
                    if !detail.paths.isEmpty {
                        AgentAttachPillsView(paths: detail.paths)
                    }
                }
            } else {
                // Transcript grouping missed this row (interrupted turn).
                Text("—")
                    .font(.system(size: 10))
                    .foregroundColor(palette.secondaryText)
            }
        } else if loadingDetails {
            ProgressView().controlSize(.small)
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

/// The step journal WHILE the turn runs, rendered inside the thinking pill:
/// the steps appear as the agent takes them instead of arriving all at once
/// with the answer. Collapsed by default, exactly like the journal on a
/// delivered reply — a 40-step turn must not inflate the pill to half the
/// screen.
///
/// The disclosure state is OWNED BY THE CALLER on purpose: the pill's row is
/// rebuilt on every step (transcript revision pass swaps the hosting view's
/// rootView), so a `@State` here would be at the mercy of that rebuild and
/// could snap shut mid-turn. No per-step detail level either — details only
/// exist in the gateway transcript once the turn has been recorded; the full
/// journal attaches to the reply at delivery (`AgentStepJournalView`).
struct AgentLiveStepsView: View {
    @Environment(\.themePalette) private var palette

    let steps: [AgentStep]
    let expanded: Bool
    let toggle: () -> Void

    /// Newest steps rendered when expanded; everything older collapses into
    /// one counting line, so even an open journal stays bounded.
    private static let visibleLimit = 12

    var body: some View {
        let earlier = max(0, steps.count - Self.visibleLimit)
        VStack(alignment: .leading, spacing: 3) {
            Button(action: toggle) {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text("\(AGL("agent.steps.title")) · \(steps.count)")
                        .font(.system(size: 11, design: palette.fontDesign))
                }
                .foregroundColor(palette.secondaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            if expanded {
                if earlier > 0 {
                    Text(String(format: AGL("agent.steps.earlier"), earlier))
                        .font(.system(size: 10, design: palette.fontDesign))
                        .foregroundColor(palette.secondaryText)
                }
                ForEach(steps.suffix(Self.visibleLimit)) { step in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: symbol(step.status))
                            .font(.system(size: 9))
                            .foregroundColor(step.status == .failed ? .red : palette.ink)
                        Text(step.toolName)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(palette.primaryText)
                        Text(detail(step))
                            .font(.system(size: 10.5, design: palette.fontDesign))
                            .foregroundColor(palette.secondaryText)
                            .lineLimit(1)
                    }
                }
                .padding(.leading, 14)
            }
        }
    }

    private func symbol(_ status: AgentStep.Status) -> String {
        switch status {
        case .completed: return "checkmark.circle"
        case .failed: return "xmark.circle"
        case .running: return "circle.dotted"
        }
    }

    /// Duration once the step is over, its state while it is not — the row
    /// must never look identical before and after a tool returns.
    private func detail(_ step: AgentStep) -> String {
        switch step.status {
        case .running: return AGL("agent.steps.running")
        case .completed, .failed:
            let word = step.status == .failed
                ? AGL("agent.steps.failed") : AGL("agent.steps.completed")
            guard let duration = step.duration else { return word }
            return String(format: "%@ · %.1fs", word, duration)
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
