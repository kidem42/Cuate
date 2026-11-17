import Combine
import SwiftUI

// MARK: - Ornament engine
//
// Every theme's panel ornaments are DATA: a scene of ornaments, each with
// what to draw, where it rests (relative to the live panel size, so resizing
// just works) and how it moves (a pose as a function of time). One engine
// per panel draws the whole scene in ONE Canvas on ONE motion clock:
// - fractional coordinates everywhere (a timeline-fed `.offset` snaps to
//   whole pixels — slow floats turned into ~5 fps staircases);
// - one pause rule (`MotionTimeline`: off screen = no frames);
// - blurred art is pre-rendered once (`BlurSprite`) and only moved.
// Themes never own timelines or views of their own.

/// Where an ornament's anchor point rests, given the panel size.
struct OrnamentPlacement {
    let point: (CGSize) -> CGPoint

    /// A point measured from the panel's top-leading corner.
    static func topLeading(_ x: CGFloat, _ y: CGFloat) -> OrnamentPlacement {
        OrnamentPlacement { _ in CGPoint(x: x, y: y) }
    }
    /// `x` measured leftwards from the trailing edge, `y` down from the top.
    static func topTrailing(_ x: CGFloat, _ y: CGFloat) -> OrnamentPlacement {
        OrnamentPlacement { size in CGPoint(x: size.width - x, y: y) }
    }
    /// `x` leftwards from the trailing edge, `y` up from the bottom.
    static func bottomTrailing(_ x: CGFloat, _ y: CGFloat) -> OrnamentPlacement {
        OrnamentPlacement { size in CGPoint(x: size.width - x, y: size.height - y) }
    }
    /// Fractions of the panel plus a point offset.
    static func fraction(_ fx: CGFloat, _ fy: CGFloat, dx: CGFloat = 0, dy: CGFloat = 0) -> OrnamentPlacement {
        OrnamentPlacement { size in CGPoint(x: size.width * fx + dx, y: size.height * fy + dy) }
    }
    static func custom(_ point: @escaping (CGSize) -> CGPoint) -> OrnamentPlacement {
        OrnamentPlacement(point: point)
    }
}

/// One thing in a scene.
struct Ornament {
    enum Art {
        /// Vector art, drawn as a Canvas symbol at its own size (it stays
        /// vector).
        case symbol(AnyView)
        /// Free drawing (particle fields, sprites). Gets the whole frame.
        case draw((inout GraphicsContext, OrnamentFrame) -> Void)
    }

    var art: Art
    /// Rest position of the art's `anchor` point (ignored by `.draw`).
    var at: OrnamentPlacement = .topLeading(0, 0)
    /// Which point of the art sits on `at`; the pivot for rotation/scale.
    var anchor: UnitPoint = .center
    var pose: ((Double) -> MotionPose)?

    /// `view` is drawn at its ideal size (give it a `.frame` when it has
    /// none of its own); `anchor` picks which of its points sits on `at`.
    static func symbol<V: View>(at: OrnamentPlacement, anchor: UnitPoint = .center,
                                pose: ((Double) -> MotionPose)? = nil,
                                @ViewBuilder _ view: () -> V) -> Ornament {
        Ornament(art: .symbol(AnyView(view().fixedSize())), at: at, anchor: anchor, pose: pose)
    }

    static func draw(_ body: @escaping (inout GraphicsContext, OrnamentFrame) -> Void) -> Ornament {
        Ornament(art: .draw(body))
    }
}

/// What a `.draw` ornament gets each frame.
struct OrnamentFrame {
    let size: CGSize
    let t: Double
    let displayScale: CGFloat
    let sprites: [String: OrnamentSprites.Entry]

    /// A prepared sprite and the size it was rendered for.
    func sprite(_ id: String) -> OrnamentSprites.Entry? { sprites[id] }
}

/// A blurred image a scene needs. `size` may follow the panel (Aurora's
/// ribbons): while the panel is being resized the last image is stretched,
/// and it is re-rendered exactly once the size has settled.
struct OrnamentSpriteSpec {
    let id: String
    let radius: CGFloat
    let size: (CGSize) -> CGSize
    let content: (CGSize) -> AnyView

    init<V: View>(_ id: String, radius: CGFloat, size: @escaping (CGSize) -> CGSize,
                  @ViewBuilder content: @escaping (CGSize) -> V) {
        self.id = id
        self.radius = radius
        self.size = size
        self.content = { AnyView(content($0)) }
    }

    /// A sprite whose size never changes.
    init<V: View>(_ id: String, radius: CGFloat, fixed: CGSize, @ViewBuilder content: @escaping () -> V) {
        self.init(id, radius: radius, size: { _ in fixed }, content: { _ in content() })
    }
}

struct OrnamentScene {
    /// Frames per second while visible.
    var fps: Double = 60
    var sprites: [OrnamentSpriteSpec] = []
    var ornaments: [Ornament] = []
}

/// Sprite cache for one engine, with the settle-then-render resize rule.
@MainActor
final class OrnamentSprites: ObservableObject {
    struct Entry {
        let image: CGImage
        /// The art size (before blur padding) the image was rendered for.
        let size: CGSize
        let padding: CGFloat
    }

    private var entries: [String: Entry] = [:]
    private var settle: DispatchWorkItem?
    @Published private var generation = 0

    func resolve(_ specs: [OrnamentSpriteSpec], panel: CGSize, scale: CGFloat,
                 keyPrefix: String) -> [String: Entry] {
        var out: [String: Entry] = [:]
        var stale = false
        for spec in specs {
            let size = spec.size(panel)
            guard size.width > 0, size.height > 0 else { continue }
            let key = keyPrefix + spec.id
            if let entry = entries[key], abs(entry.size.width - size.width) < 0.5,
               abs(entry.size.height - size.height) < 0.5 {
                out[spec.id] = entry
            } else if let entry = entries[key] {
                // Mid-resize: stretch what we have, render once it settles.
                out[spec.id] = entry
                stale = true
            } else if let entry = render(spec, size: size, scale: scale) {
                entries[key] = entry
                out[spec.id] = entry
            }
        }
        if stale { scheduleSettle(specs, panel: panel, scale: scale, keyPrefix: keyPrefix) }
        return out
    }

    private func render(_ spec: OrnamentSpriteSpec, size: CGSize, scale: CGFloat) -> Entry? {
        guard let image = BlurSprite.image(key: spec.id, size: size, radius: spec.radius, scale: scale,
                                           content: { spec.content(size) }) else { return nil }
        return Entry(image: image, size: size, padding: BlurSprite.padding(spec.radius))
    }

    private func scheduleSettle(_ specs: [OrnamentSpriteSpec], panel: CGSize, scale: CGFloat,
                                keyPrefix: String) {
        settle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            for spec in specs {
                let size = spec.size(panel)
                if let entry = self.render(spec, size: size, scale: scale) {
                    self.entries[keyPrefix + spec.id] = entry
                }
            }
            self.generation += 1
        }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}

/// Draws a scene: one Canvas, one clock. Sprites are only prepared while
/// the panel is visible (a hidden window switching theme renders nothing).
struct OrnamentLayer: View {
    let scene: OrnamentScene
    /// Distinguishes sprite variants (theme, scheme, context) in the cache.
    let spriteKey: String
    @Environment(\.displayScale) private var displayScale
    @Environment(\.motionLive) private var live
    @StateObject private var bank = OrnamentSprites()

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            if live != false {
                let sprites = bank.resolve(scene.sprites, panel: size, scale: displayScale,
                                           keyPrefix: spriteKey + "|")
                canvas(size: size, sprites: sprites)
            }
        }
        .allowsHitTesting(false)
    }

    private func canvas(size: CGSize, sprites: [String: OrnamentSprites.Entry]) -> some View {
        let scene = scene
        let scale = displayScale
        return MotionTimeline(minimumInterval: 1 / scene.fps) { context in
            let t = OrnamentClock.override ?? context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, canvasSize in
                let frame = OrnamentFrame(size: canvasSize, t: t, displayScale: scale, sprites: sprites)
                for (index, ornament) in scene.ornaments.enumerated() {
                    switch ornament.art {
                    case .draw(let body):
                        var layer = ctx
                        body(&layer, frame)
                    case .symbol:
                        guard let symbol = ctx.resolveSymbol(id: index) else { continue }
                        let pose = ornament.pose?(t) ?? MotionPose()
                        let rest = ornament.at.point(canvasSize)
                        var layer = ctx
                        layer.opacity = pose.opacity
                        layer.translateBy(x: rest.x + pose.offset.width, y: rest.y + pose.offset.height)
                        layer.rotate(by: pose.rotation)
                        layer.scaleBy(x: pose.scale, y: pose.scale)
                        layer.draw(symbol, at: .zero, anchor: ornament.anchor)
                    }
                }
            } symbols: {
                ForEach(Array(scene.ornaments.enumerated()), id: \.offset) { index, ornament in
                    if case .symbol(let view) = ornament.art {
                        view.tag(index)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
        }
    }
}

/// Harness hook: a fixed clock for offscreen comparison renders. Never set
/// in the app.
nonisolated enum OrnamentClock {
    nonisolated(unsafe) static var override: Double?
}
