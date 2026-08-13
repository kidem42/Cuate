import Combine
import SwiftUI

/// The "working…" pill at the foot of the transcript: status line plus the
/// agent's step journal as it fills.
///
/// It exists as its own observable for the same reason `StreamingReplyModel`
/// does — to keep a constantly-changing row OUT of the transcript's rebuild
/// path. The pill's content changes on every step, every step completion and
/// every status line; when those rode the row's revision, each one rebuilt the
/// hosting view, and `TranscriptEngineView.apply` answered with a full Auto
/// Layout + SwiftUI sizing pass over the ENTIRE transcript. On a long agent
/// turn (14 steps, a 6000 pt document) that pass measured in seconds and the
/// main thread sat at 100% for the whole turn — hang-20260812-175339,
/// spin-20260812-175422.
///
/// Now the row's revision is constant for the turn and only this object
/// publishes, so a step lands in the pill's own subtree and nothing else in
/// the transcript is touched.
@MainActor
final class LiveTurnPillModel: ObservableObject {
    @Published var status: String?
    @Published var steps: [AgentStep] = []
    /// Disclosure of the journal. Held here rather than in the window because
    /// the pill must not snap shut when its content updates.
    @Published var expanded = false

    /// Identity of the turn the pill is showing. The transcript row keys its
    /// revision on this: it changes once per turn (so a new turn gets a clean
    /// row) and never during one.
    private(set) var turnID: String = ""

    /// Starts a fresh turn — collapsed, empty, whatever the caller knows so far.
    func begin(turnID: String, status: String?, steps: [AgentStep]) {
        self.turnID = turnID
        self.status = status
        self.steps = steps
        expanded = false
    }

    func clear() {
        turnID = ""
        guard !steps.isEmpty || status != nil || expanded else { return }
        status = nil
        steps = []
        expanded = false
    }
}

/// The pill itself. Subscribes to the model, so a step redraws this subtree
/// alone.
struct LiveTurnPill: View {
    @ObservedObject var model: LiveTurnPillModel
    let fallbackStatus: String
    let rowWidth: CGFloat
    @Environment(\.themePalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ThinkingEqualizer()
                Text(model.status ?? fallbackStatus)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                // ImageAddon: cancels a running image operation; hidden
                // otherwise. Agent turns are stopped from the composer
                // (send↔stop swap) — ONE affordance, not two.
                ImageOperationCancelButton()
            }
            // The journal as it fills. Lives here for the whole turn (including
            // after the agent's interim text has started a bubble above), then
            // attaches to the reply at delivery.
            if !model.steps.isEmpty {
                AgentLiveStepsView(steps: model.steps, expanded: model.expanded) {
                    model.expanded.toggle()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // Hairline stroke in the input field's color (theme mockup): glass
        // stays as it was, with no border.
        .overlay {
            if !palette.isGlass {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(palette.inputStroke, lineWidth: 1)
            }
        }
        .frame(width: rowWidth, alignment: .leading)
    }
}
