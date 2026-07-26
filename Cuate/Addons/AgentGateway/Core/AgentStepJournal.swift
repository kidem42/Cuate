import Foundation

/// Collects the tool steps of one agent turn and serializes the compact
/// summary persisted on the reply (`ChatMessage.agentSteps`). The full event
/// stream is deliberately not stored — one agent turn can emit hundreds of
/// tool events (AGENT-ADDONS-NOTES.md §6.1 p.5); the summary (tool · status
/// · duration) is what the collapsible journal renders after a restart.
@MainActor
final class AgentStepJournal {
    private(set) var steps: [AgentStep] = []

    var isEmpty: Bool { steps.isEmpty }

    /// Upserts a step: a `.running` event appends, its completion updates the
    /// matching entry (last running step with the same tool name — Hermes
    /// completion frames carry no args to match on, and tools run
    /// sequentially within a turn).
    func record(_ step: AgentStep) {
        if step.status != .running,
           let index = steps.lastIndex(where: { $0.toolName == step.toolName && $0.status == .running }) {
            steps[index].status = step.status
            steps[index].finishedAt = step.finishedAt ?? Date()
        } else if !steps.contains(where: { $0.id == step.id }) {
            steps.append(step)
        }
    }

    /// One line per step: "toolName · status · 1.2s" (+ preview when present).
    /// Parsed back by `parse` for rendering, so the format is a contract.
    func summary() -> String? {
        guard !steps.isEmpty else { return nil }
        return steps.map { step in
            var parts = [step.toolName, step.status.rawValue]
            if let duration = step.duration {
                parts.append(String(format: "%.1fs", duration))
            }
            if let preview = step.preview, !preview.isEmpty {
                // Single line, bounded — the summary must stay small.
                parts.append(String(preview.replacingOccurrences(of: "\n", with: " ").prefix(120)))
            }
            return parts.joined(separator: " · ")
        }.joined(separator: "\n")
    }

    /// Parses a persisted summary back into displayable rows.
    nonisolated static func parse(_ summary: String) -> [(toolName: String, status: String, detail: String?)] {
        summary.split(separator: "\n").map { line in
            let parts = line.split(separator: " · ", maxSplits: 3).map(String.init)
            let tool = parts.first ?? String(line)
            let status = parts.count > 1 ? parts[1] : ""
            // Detail = duration and/or preview, joined back for display.
            let detail = parts.count > 2 ? parts[2...].joined(separator: " · ") : nil
            return (tool, status, detail)
        }
    }
}
