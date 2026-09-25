import SwiftUI

/// App-wide compression controls, available only in Settings > Chat.
struct ContextCompressionSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    private var threshold: Binding<Int> {
        Binding(get: { settings.compressionTokenThreshold }, set: {
            settings.compressionTokenThreshold = ContextCompressionPolicy.normalized($0)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent(L("compression.threshold")) {
                HStack(spacing: 8) {
                    TextField(L("compression.threshold"), value: threshold, format: .number.grouping(.never))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 110)
                        .help(L("compression.thresholdHelp"))
                    Stepper(L("compression.threshold"), value: threshold,
                            in: ContextCompressionPolicy.range, step: 500)
                        .labelsHidden()
                        .fixedSize()
                        .help(L("compression.thresholdHelp"))
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            Text(L("compression.explanation"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
