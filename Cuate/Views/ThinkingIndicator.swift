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
    /// Freezes the wave (and its 30 fps invalidation stream). The transcript's
    /// backfill spinner lives at the TOP of every long chat — without this it
    /// kept ticking the whole session while parked far off-screen.
    var paused: Bool = false
    @Environment(\.themePalette) private var palette

    private let barCount = 5
    private let period: Double = 1.1
    private let cascade: Double = 0.15
    private let minHeight: CGFloat = 4
    private let maxHeight: CGFloat = 15

    var body: some View {
        if palette.themeID == .yule {
            // Yule: карамельный цилиндр — спираль крутится «на боку».
            CandyCaneSpinner(paused: paused)
        } else {
            equalizer
        }
    }

    private var equalizer: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { context in
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

/// Yule's "thinking" spinner: a candy-cane cylinder lying on its side, its
/// red/cream spiral turning (the barber-pole read). Port of the approved mock:
/// 45° stripes, 6px perpendicular width, one full period (12·√2 ≈ 16.97px of
/// horizontal travel) every 0.8s — the loop closes on itself exactly, so the
/// motion never hiccups. Gloss (top highlight, bottom shade) is drawn OVER the
/// stripes so the shine stays put while the spiral moves.
struct CandyCaneSpinner: View {
    var paused: Bool = false

    private let size = CGSize(width: 44, height: 11)
    private let turnPeriod: Double = 0.8
    /// Horizontal travel per turn: perpendicular stripe period 12px at 45°.
    private let travel: CGFloat = 16.9706

    private let red = Color(rgb: 0xE5484D)
    private let cream = Color(rgb: 0xFFF6EC)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: paused)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = CGFloat(t.truncatingRemainder(dividingBy: turnPeriod) / turnPeriod) * travel
            Canvas { ctx, canvasSize in
                let rect = CGRect(origin: .zero, size: canvasSize)
                let capsule = Path(roundedRect: rect, cornerRadius: canvasSize.height / 2)
                ctx.clip(to: capsule)
                ctx.fill(capsule, with: .color(cream))

                // Диагональные полосы «/», едут вправо на phase; запас по краям
                // покрывает диагональный свес.
                let h = canvasSize.height
                var x = -h - travel + phase
                while x < canvasSize.width + h {
                    var stripe = Path()
                    stripe.move(to: CGPoint(x: x, y: h))
                    stripe.addLine(to: CGPoint(x: x + h, y: 0))
                    stripe.addLine(to: CGPoint(x: x + h + travel / 2, y: 0))
                    stripe.addLine(to: CGPoint(x: x + travel / 2, y: h))
                    stripe.closeSubpath()
                    ctx.fill(stripe, with: .color(red))
                    x += travel
                }

                // Глянец цилиндра: блик сверху, тень снизу — неподвижные.
                ctx.fill(capsule, with: .linearGradient(
                    Gradient(stops: [
                        .init(color: .white.opacity(0.45), location: 0),
                        .init(color: .white.opacity(0), location: 0.42),
                        .init(color: .black.opacity(0), location: 0.62),
                        .init(color: .black.opacity(0.22), location: 1),
                    ]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: canvasSize.height)))
            }
            .frame(width: size.width, height: size.height)
        }
        .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
    }
}
