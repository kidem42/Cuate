import SwiftUI

/// Tool consent is independent of the background-continuation consent card.
struct HermesApprovalCard: View {
    @Environment(\.themePalette) private var palette
    let entry: HermesApprovalLedger.Entry
    let stopping: Bool
    let resolve: (Bool) -> Void
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(HL("hermes.approval.title"))
            Text(entry.request.command)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .foregroundColor(palette.codeText)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.codeFill, in: RoundedRectangle(cornerRadius: 6))
            Text(URL(string: entry.request.endpoint)?.host ?? entry.request.endpoint)
                .font(.caption).foregroundColor(palette.secondaryText)
            if entry.phase == .uncertain {
                Text(HL("hermes.approval.uncertain")).font(.caption)
                Button(HL("hermes.approval.refresh"), action: refresh)
                    .help(HL("hermes.approval.refresh"))
                    .disabled(stopping)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack { actions }
                    VStack(alignment: .leading) { actions }
                }
                .disabled(entry.phase != .ready || stopping)
            }
        }
        .foregroundColor(palette.primaryText)
        .padding(12)
        .modifier(ThemedBubble(palette: palette, isUser: false))
    }

    @ViewBuilder private var actions: some View {
        Button(HL("hermes.approval.once")) { resolve(true) }
            .buttonStyle(.borderedProminent).tint(palette.accent)
            .help(HL("hermes.approval.once"))
        Button(HL("hermes.approval.deny")) { resolve(false) }
            .buttonStyle(.bordered).tint(palette.accent)
            .help(HL("hermes.approval.deny"))
    }
}
