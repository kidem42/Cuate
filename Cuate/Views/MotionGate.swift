import AppKit
import SwiftUI

// MARK: - Why this exists
//
// Ambient animations (theme decorations, thinking bars, the composer caret)
// used to stop on their own once their window was ordered out. Since macOS 27
// SwiftUI drives frames through the UpdateCycle driver, which keeps ticking
// `TimelineView(.animation)` and `repeatForever` animations in windows that
// are not on screen — a hidden Yule panel kept falling snow at 30 fps for
// days (field sample 2026-11-17: 230 % CPU, every window off screen).
//
// The rule: an endless animation runs on `MotionTimeline`, which pauses while
// its window is not visible. Animations are pure functions of absolute time,
// so a resumed one is exactly where it would have been — no restart, no jump
// in rhythm.

/// Whether the enclosing window is actually visible. `nil` = no gate above
/// this view (a `MotionTimeline` then installs its own probe).
private struct MotionLiveKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    var motionLive: Bool? {
        get { self[MotionLiveKey.self] }
        set { self[MotionLiveKey.self] = newValue }
    }
}

extension View {
    /// Publishes the window's visibility to every `MotionTimeline` below —
    /// one probe for a whole subtree instead of one per animation.
    func motionGate() -> some View { modifier(MotionGateModifier()) }
}

private struct MotionGateModifier: ViewModifier {
    @State private var live = true

    func body(content: Content) -> some View {
        content
            .environment(\.motionLive, live)
            .background(WindowVisibilityProbe(live: $live))
    }
}

/// `TimelineView(.animation)` that stops while its window is hidden, the
/// screens sleep or the session is switched away. Same schedule and context
/// as the system view, so call sites swap one for the other.
struct MotionTimeline<Content: View>: View {
    var minimumInterval: Double?
    var paused: Bool = false
    let content: (TimelineViewDefaultContext) -> Content

    init(minimumInterval: Double? = nil, paused: Bool = false,
         @ViewBuilder content: @escaping (TimelineViewDefaultContext) -> Content) {
        self.minimumInterval = minimumInterval
        self.paused = paused
        self.content = content
    }

    @Environment(\.motionLive) private var live

    var body: some View {
        if live == nil {
            core.motionGate()
        } else {
            core
        }
    }

    private var core: some View {
        MotionTimelineCore(minimumInterval: minimumInterval, paused: paused, content: content)
    }
}

private struct MotionTimelineCore<Content: View>: View {
    let minimumInterval: Double?
    let paused: Bool
    let content: (TimelineViewDefaultContext) -> Content
    @Environment(\.motionLive) private var live

    var body: some View {
        TimelineView(.animation(minimumInterval: minimumInterval, paused: paused || live == false)) { context in
            content(context)
        }
    }
}

/// Where an ornament sits on a frame, relative to its resting placement
/// (see `OrnamentEngine`).
struct MotionPose {
    var offset: CGSize = .zero
    var rotation: Angle = .zero
    var scale: CGFloat = 1
    var opacity: Double = 1
}

// MARK: - Curves

nonisolated enum MotionCurve {
    /// Harness hook: every loop held at this phase (0 = resting, 1 =
    /// toggled). Never set in the app.
    nonisolated(unsafe) static var frozen: Double?

    /// SwiftUI's `.easeInOut` — cubic Bézier (0.42, 0, 0.58, 1).
    static func easeInOut(_ x: Double) -> Double {
        let x = min(1, max(0, x))
        // Solve bx(s) = x for the curve parameter (Newton, then a bisection
        // guard), then evaluate by(s).
        func bx(_ s: Double) -> Double { 3 * (1 - s) * (1 - s) * s * 0.42 + 3 * (1 - s) * s * s * 0.58 + s * s * s }
        func dbx(_ s: Double) -> Double {
            3 * 0.42 * (1 - s) * (1 - 3 * s) + 3 * 0.58 * s * (2 - 3 * s) + 3 * s * s
        }
        var s = x
        for _ in 0..<6 {
            let d = dbx(s)
            guard abs(d) > 1e-6 else { break }
            s -= (bx(s) - x) / d
        }
        if abs(bx(s) - x) > 1e-4 {
            var lo = 0.0, hi = 1.0
            s = x
            for _ in 0..<30 {
                if bx(s) < x { lo = s } else { hi = s }
                s = (lo + hi) / 2
            }
        }
        return 3 * (1 - s) * s * s + s * s * s
    }

    /// The value `withAnimation(.easeInOut(duration: half).repeatForever(autoreverses: true).delay(delay)) { flag = true }`
    /// gives a 0 → 1 flag at time `t`: 0 is the resting state, 1 the toggled one.
    static func pingPong(_ t: Double, half: Double, delay: Double = 0) -> Double {
        if let frozen { return frozen }
        guard half > 0 else { return 0 }
        let u = (t - delay) / half
        let cycle = u - 2 * (u / 2).rounded(.down)        // 0 ..< 2
        return easeInOut(cycle <= 1 ? cycle : 2 - cycle)
    }

    static func lerp(_ a: Double, _ b: Double, _ p: Double) -> Double { a + (b - a) * p }
}

// MARK: - Pre-rendered blurs

/// A blurred shape rendered once and reused as an image. Animating a live
/// `.blur` re-runs the Gaussian on an offscreen surface every frame (and on
/// macOS 27 floods RenderBox's surface pool with collection timers); scaling
/// or fading the finished pixels is a plain texture draw. Output is the same
/// renderer's blur, so the picture is unchanged.
@MainActor
enum BlurSprite {
    private static var cache: [String: CGImage] = [:]

    /// `content` laid out at `size`, blurred by `radius`, on a canvas padded
    /// by the blur's reach. The image is `size + 2 × padding(radius)` points.
    static func image(key: String, size: CGSize, radius: CGFloat, scale: CGFloat,
                      @ViewBuilder content: () -> some View) -> CGImage? {
        let full = "\(key)|\(Int(size.width * 2))x\(Int(size.height * 2))|\(radius)|\(scale)"
        if let hit = cache[full] { return hit }
        let pad = padding(radius)
        let renderer = ImageRenderer(content:
            content()
                .frame(width: size.width, height: size.height)
                .blur(radius: radius)
                .frame(width: size.width + 2 * pad, height: size.height + 2 * pad))
        renderer.scale = scale
        guard let image = renderer.cgImage else { return nil }
        // Sizes follow the panel (Aurora ribbons): keep the cache bounded
        // across live resizes.
        if cache.count > 64 { cache.removeAll(keepingCapacity: true) }
        cache[full] = image
        return image
    }

    /// How far a Gaussian of `radius` visibly reaches past the shape.
    static func padding(_ radius: CGFloat) -> CGFloat { ceil(radius * 3) }
}

// MARK: - Visibility probe

/// Screen sleep and fast-user-switching, shared by every probe.
@MainActor
private final class SystemMotionState {
    static let shared = SystemMotionState()
    static let changed = Notification.Name("CuateSystemMotionStateChanged")

    private(set) var screensAsleep = false
    private(set) var sessionActive = true
    private var tokens: [NSObjectProtocol] = []

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        let pairs: [(Notification.Name, (SystemMotionState) -> Void)] = [
            (NSWorkspace.screensDidSleepNotification, { $0.screensAsleep = true }),
            (NSWorkspace.screensDidWakeNotification, { $0.screensAsleep = false }),
            (NSWorkspace.sessionDidResignActiveNotification, { $0.sessionActive = false }),
            (NSWorkspace.sessionDidBecomeActiveNotification, { $0.sessionActive = true }),
        ]
        for (name, apply) in pairs {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    apply(SystemMotionState.shared)
                    NotificationCenter.default.post(name: SystemMotionState.changed, object: nil)
                }
            })
        }
    }

    var allowsMotion: Bool { !screensAsleep && sessionActive }
}

/// A zero-size view that reports whether its window is on screen.
private struct WindowVisibilityProbe: NSViewRepresentable {
    @Binding var live: Bool

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = { value in
            if live != value { live = value }
        }
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.onChange = { value in
            if live != value { live = value }
        }
    }

    final class ProbeView: NSView {
        var onChange: ((Bool) -> Void)?
        private var tokens: [NSObjectProtocol] = []
        private var reported: Bool?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            guard let window else {
                if reported == true { PowerTelemetry.motionGateVisibilityChanged(visible: false) }
                reported = nil
                return
            }
            _ = SystemMotionState.shared
            tokens.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.evaluate() } })
            tokens.append(NotificationCenter.default.addObserver(
                forName: SystemMotionState.changed, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.evaluate() } })
            evaluate()
        }

        private func evaluate() {
            guard let window else { return }
            let visible = window.occlusionState.contains(.visible) && SystemMotionState.shared.allowsMotion
            guard visible != reported else { return }
            if visible { PowerTelemetry.motionGateVisibilityChanged(visible: true) }
            else if reported == true { PowerTelemetry.motionGateVisibilityChanged(visible: false) }
            reported = visible
            // Never mutate SwiftUI state from inside its own update pass.
            DispatchQueue.main.async { [weak self] in self?.onChange?(visible) }
        }
        // Observers go in `viewDidMoveToWindow(nil)`, which AppKit always
        // calls before a view leaves its window; their blocks hold the view
        // weakly.
    }
}
