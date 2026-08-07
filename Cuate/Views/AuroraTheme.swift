import SwiftUI

/// Aurora's decorations, 1:1 with the approved mock (Cuate New Themes, §2a):
/// blurred aurora ribbons breathing across the panel's top, twinkling stars
/// (dark only) and a shooting star streaking down-left once every 12 s.
struct AuroraDecorations: View {
    /// Мировое время: ленты и звёзды остаются, падающие звёзды — только в чате
    /// (штрих поперёк данных читался бы как артефакт).
    var worldTime: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    private var dark: Bool { colorScheme == .dark }

    /// Mock's star field: (x fraction, y px, diameter px).
    private static let stars: [(x: CGFloat, y: CGFloat, d: CGFloat)] = [
        (0.12, 34, 2), (0.30, 16, 1.5), (0.52, 28, 2), (0.76, 20, 1.5), (0.88, 48, 2),
        (0.22, 66, 1.5), (0.64, 58, 1.5), (0.41, 46, 1.5), (0.83, 84, 1.5), (0.08, 96, 1.5),
    ]

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if dark {
                    AuroraRibbon(color: drgba(61, 232, 176, 0.40), period: 11, phase: 0)
                        .frame(width: geo.size.width * 0.85, height: geo.size.height * 0.48)
                        .offset(x: -geo.size.width * 0.18, y: -geo.size.height * 0.10)
                    AuroraRibbon(color: drgba(125, 108, 255, 0.34), period: 14, phase: 2.5)
                        .frame(width: geo.size.width * 0.90, height: geo.size.height * 0.54)
                        .offset(x: geo.size.width * 0.32, y: -geo.size.height * 0.06)
                    AuroraRibbon(color: drgba(111, 227, 255, 0.22), period: 9, phase: 5)
                        .frame(width: geo.size.width * 0.70, height: geo.size.height * 0.36)
                        .offset(x: geo.size.width * 0.16, y: -geo.size.height * 0.04)
                    ForEach(0..<Self.stars.count, id: \.self) { i in
                        let star = Self.stars[i]
                        TwinklingStar(diameter: star.d,
                                      period: 2 + Double(i % 4) * 0.7,
                                      phase: Double(i) * 0.5)
                            .offset(x: geo.size.width * star.x, y: star.y)
                    }
                    if !worldTime {
                        // Две падающие звезды на сдвинутых циклах: каждая
                        // вспыхивает в СЛУЧАЙНОЙ точке всего окна.
                        ShootingStar(area: geo.size, cycle: 12, seed: 0)
                        ShootingStar(area: geo.size, cycle: 12, seed: 7)
                    }
                } else {
                    AuroraRibbon(color: drgba(64, 196, 160, 0.26), period: 12, phase: 0)
                        .frame(width: geo.size.width * 0.80, height: geo.size.height * 0.42)
                        .offset(x: -geo.size.width * 0.14, y: -geo.size.height * 0.08)
                    AuroraRibbon(color: drgba(150, 130, 255, 0.24), period: 15, phase: 3)
                        .frame(width: geo.size.width * 0.85, height: geo.size.height * 0.48)
                        .offset(x: geo.size.width * 0.33, y: -geo.size.height * 0.02)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// 0–255 rgba helper (local copy — AppTheme's is file-private).
private func drgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> Color {
    Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
}

/// One blurred curtain of light, drifting and swelling on its own slow period
/// (the mock's `ribbon` keyframe: x ±14, slight skew read as scale, opacity
/// breathing 0.65…1).
private struct AuroraRibbon: View {
    let color: Color
    let period: Double
    let phase: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
            let t = (context.date.timeIntervalSinceReferenceDate + phase)
                .truncatingRemainder(dividingBy: period) / period
            // Один плавный цикл: 0 → 1/3 → 2/3 → 1 (как 0/33/66/100% в CSS).
            let angle = t * 2 * .pi
            let drift = sin(angle) * 14
            let swell = 1 + sin(angle + .pi / 3) * 0.10
            let breath = 0.82 + sin(angle + .pi / 6) * 0.18
            Ellipse()
                .fill(RadialGradient(colors: [color, .clear],
                                     center: .center, startRadius: 0, endRadius: 130))
                .blur(radius: 11)
                .scaleEffect(x: 1, y: swell)
                .offset(x: drift)
                .opacity(breath)
        }
    }
}

/// A pin-prick star pulsing between bright and faint (mock's `starTw`).
private struct TwinklingStar: View {
    let diameter: CGFloat
    let period: Double
    let phase: Double
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(Color.white)
            .frame(width: diameter, height: diameter)
            .scaleEffect(dim ? 0.75 : 1)
            .opacity(dim ? 0.25 : 0.9)
            .onAppear {
                withAnimation(.easeInOut(duration: period / 2)
                    .repeatForever(autoreverses: true)
                    .delay(phase)) {
                    dim = true
                }
            }
    }
}

/// A shooting star: invisible for most of its cycle, then a bright streak
/// slides down-left (−90, +54) and fades. Each flight starts at a NEW
/// pseudo-random point of the panel — the cycle index seeds a hash, so the
/// spot changes every pass without any stored state.
private struct ShootingStar: View {
    let area: CGSize
    var cycle: Double = 12
    var seed: Double = 0
    /// The visible tail of the cycle (last 8%, as in the mock).
    private let visibleFrom: Double = 0.92

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let raw = context.date.timeIntervalSinceReferenceDate + seed * cycle / 2
            let pass = (raw / cycle).rounded(.down)              // номер пролёта
            let t = raw.truncatingRemainder(dividingBy: cycle) / cycle
            let p = max(0, (t - visibleFrom) / (1 - visibleFrom))   // 0…1 полёта
            let opacity = p == 0 ? 0 : (p < 0.2 ? p * 5 * 0.9 : 0.9 * (1 - (p - 0.2) / 0.8))
            // Псевдослучайная точка старта этого пролёта (fract-sin hash).
            let rx = hash(pass * 12.9898 + seed)
            let ry = hash(pass * 78.233 + seed * 3)
            let startX = area.width * (0.18 + 0.72 * rx)
            let startY = area.height * (0.06 + 0.72 * ry)
            Rectangle()
                .fill(LinearGradient(colors: [.white.opacity(0.9), .clear],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: 46, height: 1.5)
                .cornerRadius(1)
                .rotationEffect(.degrees(150), anchor: .trailing)
                .offset(x: startX - 90 * p, y: startY + 54 * p)
                .opacity(opacity)
        }
    }

    private func hash(_ v: Double) -> CGFloat {
        let s = sin(v) * 43758.5453
        return CGFloat(s - s.rounded(.down))
    }
}
