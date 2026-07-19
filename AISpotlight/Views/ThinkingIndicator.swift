import SwiftUI

/// Themed replacement for the system spinner in the "Thinking…" pill:
/// five equalizer bars waving — the same visual language as the dictation
/// window, so "listening" and "thinking" speak in one style.
///
/// Driven by `TimelineView` with a per-bar phase-shifted sine (period 1.1s,
/// 0.15s cascade between neighbors, height 4→15 with the opacity dimming on
/// the low end) — a deterministic port of the approved CSS keyframe. A
/// state-toggled `repeatForever` animation was tried first and drifts: the
/// pill re-renders on every streamed status update, restarting phases.
///
/// Colors come from the theme: `dictationColors` cycled per bar when the
/// theme defines them (Synthwave, Sakura, Día, …), otherwise the accent
/// (system tint for glass).
struct ThinkingEqualizer: View {
    @Environment(\.themePalette) private var palette

    private let barCount = 5
    private let period: Double = 1.1
    private let cascade: Double = 0.15
    private let minHeight: CGFloat = 4
    private let maxHeight: CGFloat = 15

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let now = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<barCount, id: \.self) { index in
                    // 0…1 wave, phase-shifted per bar like the CSS delays.
                    let phase = (now - Double(index) * cascade) * 2 * .pi / period
                    let wave = (1 - cos(phase)) / 2
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(barColor(index))
                        .frame(width: 3, height: minHeight + (maxHeight - minHeight) * wave)
                        .opacity(0.5 + 0.5 * wave)
                }
            }
            .frame(width: CGFloat(barCount) * 3 + CGFloat(barCount - 1) * 3,
                   height: maxHeight + 1)
        }
    }

    private func barColor(_ index: Int) -> Color {
        let colors = palette.dictationColors
        if colors.isEmpty {
            return palette.isGlass ? .accentColor : palette.accent
        }
        return colors[index % colors.count]
    }
}
