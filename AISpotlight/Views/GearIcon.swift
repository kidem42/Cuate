import SwiftUI

/// The settings gear, drawn rather than borrowed.
///
/// Every other glyph in the panel chrome is an SF Symbol and every preset chip
/// is an emoji; a gear had to be neither. Vector art keeps it on-brand with the
/// themed icons (SugarSkull, JackOLantern, MarigoldFlower) while reading at the
/// same optical weight as the SF Symbols beside it, at any size and in any
/// theme — the tooth count and proportions are fixed, so it stays legible down
/// to the 11pt header row.
struct GearIcon: View {
    var color: Color
    var size: CGFloat = 12

    /// Outline by default. A solid body reads unmistakably as a gear, but it
    /// also lands noticeably darker than the outline symbols it shares the
    /// header with — the strip stops looking like one row of controls and the
    /// gear starts looking like a badge. The legibility that the fill was
    /// bought for came from the tooth geometry instead (see `GearShape`), so
    /// the outline can stay.
    var filled: Bool = false

    var body: some View {
        let line = max(1, size * (filled ? 0.09 : 0.085))
        Group {
            if filled {
                GearShape()
                    .fill(color, style: FillStyle(eoFill: true))
                    // Same colour, round joins: rounds every corner without
                    // hand-built fillets.
                    .overlay(GearShape().stroke(color, style: StrokeStyle(
                        lineWidth: line, lineCap: .round, lineJoin: .round)))
            } else {
                GearShape().stroke(color, style: StrokeStyle(
                    lineWidth: line, lineCap: .round, lineJoin: .round))
            }
        }
        // Inset by half the stroke so the icon stays inside its frame instead
        // of bleeding into the neighbouring controls.
        .padding(line / 2)
        .frame(width: size, height: size)
    }
}

/// Eight-tooth gear with a hollow hub, drawn with the even-odd rule so the hub
/// punches a hole instead of covering the centre.
///
/// The teeth TAPER — each one is a trapezoid, wider at the root than at the
/// tip. That single property is what makes a gear read as a gear: the first
/// version used parallel flanks (constant angular width) and at 12pt it looked
/// like a sun or a flower, not machinery. Both references this is measured
/// against — Bootstrap's `gear-fill` and Lucide's `settings` — taper their
/// teeth and round the tips, and put roughly 40% of the radius into the hub.
struct GearShape: Shape {
    var teeth: Int = 8
    /// Radii as fractions of the icon's half-size.
    private let outerRatio: CGFloat = 1.0
    private let rootRatio: CGFloat = 0.70
    private let hubRatio: CGFloat = 0.42
    /// Half-widths of a tooth in fractions of one tooth pitch: the root is
    /// wider than the tip, which is the taper.
    private let rootHalfWidth: Double = 0.30
    private let tipHalfWidth: Double = 0.17

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let half = min(rect.width, rect.height) / 2
        let outer = half * outerRatio
        let root = half * rootRatio
        let hub = half * hubRatio
        let pitch = (.pi * 2) / Double(teeth)
        let rootHalf = pitch * rootHalfWidth
        let tipHalf = pitch * tipHalfWidth

        func point(_ angle: Double, _ radius: CGFloat) -> CGPoint {
            CGPoint(x: center.x + radius * CGFloat(cos(angle)),
                    y: center.y + radius * CGFloat(sin(angle)))
        }

        path.move(to: point(-rootHalf, root))
        for index in 0..<teeth {
            let axis = Double(index) * pitch
            // Up the leading flank, across the tip, down the trailing flank…
            path.addLine(to: point(axis - tipHalf, outer))
            path.addArc(center: center, radius: outer,
                        startAngle: .radians(axis - tipHalf),
                        endAngle: .radians(axis + tipHalf), clockwise: false)
            path.addLine(to: point(axis + rootHalf, root))
            // …then along the valley to where the next tooth starts.
            path.addArc(center: center, radius: root,
                        startAngle: .radians(axis + rootHalf),
                        endAngle: .radians(axis + pitch - rootHalf), clockwise: false)
        }
        path.closeSubpath()
        path.addEllipse(in: CGRect(
            x: center.x - hub, y: center.y - hub, width: hub * 2, height: hub * 2
        ))
        return path
    }
}

/// The gear as a header control: a plain button sized like the SF Symbol
/// buttons around it, opening Settings on the given tab.
struct SettingsGearButton: View {
    /// Tab to reveal — the chat panel lands on General, World Time on its own.
    var tab: SettingsTab = .general
    var color: Color
    var size: CGFloat = 12
    var help: String

    var body: some View {
        Button {
            NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
            // Posted after the window request so the tab selection lands on a
            // Settings window that already exists (the ImageAddon pattern).
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .selectSettingsTab, object: tab.rawValue)
            }
        } label: {
            GearIcon(color: color, size: size)
                // Same 20pt row as the other header controls, so the strip
                // keeps its rhythm and the hit target stays comfortable.
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .help(help)
    }
}

#if DEBUG
#Preview("Gear sizes") {
    HStack(spacing: 16) {
        GearIcon(color: .secondary, size: 11)
        GearIcon(color: .secondary, size: 12)
        GearIcon(color: .primary, size: 16)
        GearIcon(color: .accentColor, size: 24)
        GearIcon(color: .primary, size: 48)
    }
    .padding()
}
#endif
