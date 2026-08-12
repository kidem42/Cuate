import SwiftUI

// MARK: - Card view

/// Collapsed service card on the assistant side: one summary line closed
/// (kind, ✓/✗ tally, duration), the structured report on demand. Visual
/// language follows `AgentStepJournalView` (chevron disclosure, 11pt
/// secondary), on a whisper of a backing so it reads as service chrome, not
/// as a reply bubble.
struct HermesServiceNoticeView: View {
    @Environment(\.themePalette) private var palette

    let notice: HermesServiceNotice
    @State private var expanded = false
    @State private var expandedTasks: Set<Int> = []

    private var linkTint: Color { palette.isGlass ? .accentColor : palette.ink }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                headerLine
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            if expanded {
                expandedContent
                    .padding(.leading, 14)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.14), lineWidth: 1)
        )
    }

    private var headerLine: some View {
        HStack(spacing: 5) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(palette.secondaryText)
            Image(systemName: notice.kind == .delegation
                  ? "arrow.triangle.branch" : "terminal")
                .font(.system(size: 10))
                .foregroundColor(palette.ink)
            Text(notice.kind == .delegation
                 ? HL("hermes.notice.delegation") : HL("hermes.notice.process"))
                .font(.system(size: 11, weight: .medium, design: palette.fontDesign))
                .foregroundColor(palette.secondaryText)

            if notice.okCount > 0 {
                tally("checkmark.circle", notice.okCount, color: palette.ink)
            }
            if notice.failCount > 0 {
                tally("xmark.circle", notice.failCount, color: .red)
            }
            if let duration = notice.durationText {
                Text(duration)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(palette.secondaryText)
            }
            if let exit = notice.exitText {
                Text(exit)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(exit == "exit 0" ? palette.secondaryText : .red)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.10), in: Capsule())
            }
        }
    }

    private func tally(_ symbol: String, _ count: Int, color: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 9))
            Text("\(count)")
                .font(.system(size: 10, design: .monospaced))
        }
        .foregroundColor(color)
    }

    @ViewBuilder
    private var expandedContent: some View {
        if !notice.metaLines.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(notice.metaLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(palette.secondaryText)
                        .textSelection(.enabled)
                }
            }
        }

        ForEach(notice.tasks) { task in
            taskRow(task)
        }

        if let body = notice.body, !body.isEmpty {
            MarkdownBlocksView(text: body, linkColor: linkTint, isStreaming: false)
                .font(.system(size: 12))
                .foregroundColor(palette.isGlass ? .primary : palette.primaryText)
                .textSelection(.enabled)
                .environment(\.agentFileLinksEnabled, true)
        }
    }

    @ViewBuilder
    private func taskRow(_ task: HermesServiceNotice.TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if expandedTasks.contains(task.id) {
                        expandedTasks.remove(task.id)
                    } else {
                        expandedTasks.insert(task.id)
                    }
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: expandedTasks.contains(task.id)
                          ? "chevron.down" : "chevron.right")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundColor(palette.secondaryText)
                    Image(systemName: task.ok ? "checkmark.circle" : "xmark.circle")
                        .font(.system(size: 9))
                        .foregroundColor(task.ok ? palette.ink : .red)
                    if !task.label.isEmpty {
                        Text(String(format: HL("hermes.notice.task"), task.label))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(palette.primaryText)
                    }
                    Text(task.goal)
                        .font(.system(size: 11, design: palette.fontDesign))
                        .foregroundColor(palette.secondaryText)
                        .lineLimit(expandedTasks.contains(task.id) ? nil : 2)
                        .multilineTextAlignment(.leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            if expandedTasks.contains(task.id) {
                VStack(alignment: .leading, spacing: 4) {
                    if let stats = task.stats {
                        Text(stats)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(palette.secondaryText)
                            .textSelection(.enabled)
                    }
                    if !task.body.isEmpty {
                        MarkdownBlocksView(text: task.body, linkColor: linkTint,
                                           isStreaming: false)
                            .font(.system(size: 12))
                            .foregroundColor(palette.isGlass ? .primary : palette.primaryText)
                            .textSelection(.enabled)
                            .environment(\.agentFileLinksEnabled, true)
                    }
                }
                .padding(.leading, 18)
            }
        }
    }
}
