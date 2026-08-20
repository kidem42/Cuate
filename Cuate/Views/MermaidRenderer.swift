import SwiftUI
import WebKit

// MARK: - Diagram theme

/// Colors and fonts handed to mermaid's `base` theme so diagrams match the
/// app: the current theme's accent for node fills/borders, neutral Apple-ish
/// grays for text and lines, and a solid light/dark card background (solid so
/// snapshot antialiasing stays crisp). All values are hex strings because they
/// travel into the webview as `themeVariables`.
struct MermaidTheme: Equatable {
    let variables: [String: String]
    /// Card/page background, also used by the SwiftUI card behind the image.
    let backgroundHex: String
    /// Cache key component: two themes with equal keys render identically.
    let key: String

    var backgroundColor: Color { Color(hexString: backgroundHex) }

    /// Builds the theme from the chat palette's accent and the current
    /// appearance. Kept deliberately neutral: exotic chat themes keep their
    /// accent, but diagram text/lines stay high-contrast and readable.
    /// Categorical series colors for pie/timeline sections. Validated
    /// (dataviz six-checks: CVD ΔE, normal-vision floor, contrast) against
    /// the light #FFFFFF and dark #26262B card surfaces; the ORDER is the
    /// colorblind-safety mechanism, do not reshuffle. Mermaid's own base
    /// theme derives near-identical pale fills for adjacent slices, which is
    /// why these are pinned explicitly.
    private static let categoricalLight = [
        "#2A78D6", "#008300", "#E87BA4", "#EDA100",
        "#1BAF7A", "#EB6834", "#4A3AA7", "#E34948",
    ]
    private static let categoricalDark = [
        "#3987E5", "#008300", "#D55181", "#C98500",
        "#199E70", "#D95926", "#9085E9", "#E66767",
    ]

    static func make(accent: Color, dark: Bool) -> MermaidTheme {
        let accentHex = accent.hexString(dark: dark)
        let bg = dark ? "#26262B" : "#FFFFFF"
        let text = dark ? "#F0F0F3" : "#1D1D1F"
        let line = dark ? "#94949C" : "#6E6E73"
        var variables: [String: String] = [
            "background": bg,
            "primaryColor": blendHex(accentHex, bg, 0.16),
            "primaryBorderColor": blendHex(accentHex, bg, 0.60),
            "primaryTextColor": text,
            "secondaryColor": blendHex(accentHex, bg, 0.09),
            "tertiaryColor": blendHex(text, bg, 0.05),
            "lineColor": line,
            "textColor": text,
            "titleColor": text,
            "edgeLabelBackground": bg,
            "clusterBkg": blendHex(text, bg, 0.035),
            "clusterBorder": blendHex(text, bg, 0.22),
            "noteBkgColor": blendHex(accentHex, bg, 0.10),
            "noteTextColor": text,
            "errorBkgColor": bg,
            "errorTextColor": text,
            "fontSize": "14px",
            // Pie chrome: full-strength fills (the 0.7 default washes them
            // out), background-colored strokes as the "2px surface gap"
            // between slices, no heavy outer ring.
            "pieOpacity": "1",
            "pieStrokeColor": bg,
            "pieStrokeWidth": "2px",
            "pieOuterStrokeWidth": "2px",
            "pieOuterStrokeColor": bg,
            "pieTitleTextColor": text,
            "pieSectionTextColor": dark ? "#FFFFFF" : "#1D1D1F",
            "pieLegendTextColor": text,
        ]
        let series = dark ? categoricalDark : categoricalLight
        for (index, color) in series.enumerated() {
            variables["pie\(index + 1)"] = color      // pie slices
            variables["cScale\(index)"] = color       // timeline/mindmap sections
        }
        return MermaidTheme(
            variables: variables,
            backgroundHex: bg,
            key: "\(accentHex)|\(dark ? "d" : "l")"
        )
    }

    /// `top` over `base` at `alpha`, both "#RRGGBB" → "#RRGGBB".
    private static func blendHex(_ top: String, _ base: String, _ alpha: Double) -> String {
        let t = rgb(top), b = rgb(base)
        func mix(_ a: Double, _ c: Double) -> Int { Int((a * alpha + c * (1 - alpha)).rounded()) }
        return String(format: "#%02X%02X%02X", mix(t.0, b.0), mix(t.1, b.1), mix(t.2, b.2))
    }

    private static func rgb(_ hex: String) -> (Double, Double, Double) {
        var value: UInt64 = 0
        Scanner(string: String(hex.dropFirst())).scanHexInt64(&value)
        return (Double((value >> 16) & 0xff), Double((value >> 8) & 0xff), Double(value & 0xff))
    }
}

extension Color {
    /// "#RRGGBB" → Color (sRGB, opaque).
    init(hexString: String) {
        var value: UInt64 = 0
        Scanner(string: String(hexString.dropFirst())).scanHexInt64(&value)
        self.init(rgb: UInt(value))
    }

    /// Resolves the color under the given appearance to "#RRGGBB" (dynamic
    /// colors like `.accentColor` differ between light and dark).
    func hexString(dark: Bool) -> String {
        var result = "#8E8E93"
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
        appearance.performAsCurrentDrawingAppearance {
            if let srgb = NSColor(self).usingColorSpace(.sRGB) {
                result = String(
                    format: "#%02X%02X%02X",
                    Int((srgb.redComponent * 255).rounded()),
                    Int((srgb.greenComponent * 255).rounded()),
                    Int((srgb.blueComponent * 255).rounded())
                )
            }
        }
        return result
    }
}

// MARK: - Renderer

/// Offscreen mermaid engine: one hidden WKWebView loaded once with the bundled
/// mermaid.min.js (no network). A diagram is validated (`mermaid.parse`),
/// rendered to SVG, measured, then snapshotted at 2x page zoom so the inline
/// image is retina-crisp. Renders are serialized (single DOM) and cached by
/// (code, theme, scale); syntax errors come back as a typed failure so the UI
/// can fall back to the source instead of showing mermaid's error bomb.
@MainActor
final class MermaidRenderer: NSObject, WKNavigationDelegate {
    static let shared = MermaidRenderer()

    struct Rendered {
        let image: NSImage
        let svg: String
        /// Logical size in points (the image backing is `scale`× that).
        let size: CGSize
    }

    enum RenderError: Error {
        case syntax(String)
        case engine(String)

        var message: String {
            switch self {
            case .syntax(let detail): return detail
            case .engine(let detail): return detail
            }
        }
    }

    private final class CacheEntry {
        let result: Result<Rendered, RenderError>
        init(_ result: Result<Rendered, RenderError>) { self.result = result }
    }

    private enum EngineState { case idle, loading, ready, failed }

    private var webView: WKWebView?
    private var hostWindow: NSWindow?
    private var state: EngineState = .idle
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []
    private var chain: Task<Void, Never>?
    private var idleTeardown: Task<Void, Never>?
    private let cache: NSCache<NSString, CacheEntry> = {
        let cache = NSCache<NSString, CacheEntry>()
        cache.countLimit = 64
        return cache
    }()

    /// Longest side of the snapshot in pixels; the zoom is reduced for huge
    /// diagrams so snapshot surfaces stay bounded.
    private static let maxSnapshotPixels: CGFloat = 4200

    // MARK: Public API

    func render(code: String, theme: MermaidTheme, scale: CGFloat = 2) async -> Result<Rendered, RenderError> {
        let key = "\(theme.key)|\(scale)|\(code)" as NSString
        if let hit = cache.object(forKey: key) { return hit.result }
        // A render is coming — the engine must not vanish mid-queue.
        idleTeardown?.cancel()
        // Serialize: the engine has a single DOM shared by all renders.
        let previous = chain
        let work = Task { [weak self] () -> Result<Rendered, RenderError> in
            _ = await previous?.value
            guard let self else { return .failure(.engine("renderer gone")) }
            if let hit = self.cache.object(forKey: key) { return hit.result }
            let result = await self.performRender(code: code, theme: theme, scale: scale)
            self.cache.setObject(CacheEntry(result), forKey: key)
            return result
        }
        chain = Task { [weak self] in
            _ = await work.value
            self?.scheduleIdleTeardown()
        }
        return await work.value
    }

    /// The engine exists to SNAPSHOT — once the queue drains, a whole
    /// WKWebView (a web content process) plus its host window would sit idle
    /// until the next diagram, which in a background app can be days away;
    /// the window itself outlived its last render by a week (live,
    /// 2026-08-19). One quiet minute and both are gone — the image cache
    /// keeps already-rendered diagrams instant, and the next new render just
    /// re-boots the engine (~0.5 s, serialized as usual).
    private func scheduleIdleTeardown() {
        idleTeardown?.cancel()
        idleTeardown = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard !Task.isCancelled, let self, self.state == .ready else { return }
            Diagnostics.log("mermaid", "engine.teardown idle")
            self.webView?.navigationDelegate = nil
            self.hostWindow?.orderOut(nil)
            self.hostWindow?.contentView = nil
            self.webView = nil
            self.hostWindow = nil
            self.state = .idle
        }
    }

    // MARK: Engine lifecycle

    /// The bundled mermaid.min.js, read once. Empty string when missing —
    /// the engine then fails cleanly instead of crashing.
    static let mermaidJS: String = {
        guard let url = Bundle.main.url(forResource: "mermaid.min", withExtension: "js"),
              let js = try? String(contentsOf: url, encoding: .utf8) else {
            Diagnostics.log("mermaid", "bundle.missing mermaid.min.js")
            return ""
        }
        return js
    }()

    private func ensureEngine() async -> WKWebView? {
        switch state {
        case .ready: return webView
        case .failed: return nil
        case .loading:
            await withCheckedContinuation { readyWaiters.append($0) }
            return state == .ready ? webView : nil
        case .idle:
            guard !Self.mermaidJS.isEmpty else {
                state = .failed
                return nil
            }
            state = .loading
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
            view.navigationDelegate = self
            // A real (far offscreen, borderless) window: WKWebView snapshots
            // are unreliable without a window to draw into.
            let window = NSWindow(
                contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 600),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.isExcludedFromWindowsMenu = true
            window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
            // The far-offscreen origin is NOT enough to keep this window out
            // of sight: macOS relocates fully-offscreen windows onto a screen
            // when the display arrangement changes (monitor plug/unplug,
            // wake), and the borderless white band then parked over the
            // desktop with no way to close it, re-appearing every launch that
            // re-rendered a diagram (live, 2026-08-19). Fully transparent and
            // click-through keeps it harmless wherever AppKit drops it —
            // WKWebView snapshots are painted by the web process, not read
            // off the screen, so zero alpha costs the renderer nothing.
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.contentView = view
            window.orderBack(nil)
            webView = view
            hostWindow = window
            view.loadHTMLString(Self.engineHTML(), baseURL: nil)
            await withCheckedContinuation { readyWaiters.append($0) }
            return state == .ready ? webView : nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            // Confirm the library actually initialized before declaring ready.
            let type = try? await webView.evaluateJavaScript("typeof mermaid")
            self.state = (type as? String == "object" || type as? String == "function") ? .ready : .failed
            if self.state == .failed {
                Diagnostics.log("mermaid", "engine.boot failed: mermaid global missing")
            }
            self.resumeWaiters()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            Diagnostics.log("mermaid", "engine.load failed \(error.localizedDescription)")
            self.state = .failed
            self.resumeWaiters()
        }
    }

    private func resumeWaiters() {
        let waiters = readyWaiters
        readyWaiters = []
        waiters.forEach { $0.resume() }
    }

    // MARK: Render

    private func performRender(code: String, theme: MermaidTheme, scale: CGFloat) async -> Result<Rendered, RenderError> {
        guard let webView = await ensureEngine() else {
            return .failure(.engine("mermaid engine unavailable"))
        }
        do {
            let raw = try await withTimeout(seconds: 12) { @MainActor in
                try await webView.callAsyncJavaScript(
                    "return await window.renderDiagram(code, vars);",
                    arguments: ["code": code, "vars": theme.variables],
                    in: nil,
                    contentWorld: .page
                ) as? String
            }
            guard let raw,
                  let data = raw.data(using: .utf8),
                  let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(.engine("malformed engine reply"))
            }
            guard reply["ok"] as? Bool == true,
                  let svg = reply["svg"] as? String,
                  let width = (reply["w"] as? NSNumber)?.doubleValue,
                  let height = (reply["h"] as? NSNumber)?.doubleValue,
                  width > 0, height > 0 else {
                let detail = (reply["error"] as? String) ?? "empty diagram"
                Diagnostics.log("mermaid", "render.syntax \(detail.prefix(200))")
                return .failure(.syntax(detail))
            }

            // Retina snapshot: zoom the page, size the window to the zoomed
            // content, capture, then stamp the logical size back on the image.
            let effectiveScale = min(scale, Self.maxSnapshotPixels / max(width, height, 1))
            let pixelSize = NSSize(
                width: ceil(width * effectiveScale),
                height: ceil(height * effectiveScale)
            )
            webView.pageZoom = effectiveScale
            hostWindow?.setContentSize(pixelSize)
            // Re-pin after every resize: if the system moved the window onto
            // a screen (see ensureEngine), the next render sends it back out.
            hostWindow?.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            webView.frame = NSRect(origin: .zero, size: pixelSize)
            try? await Task.sleep(nanoseconds: 60_000_000) // let layout settle

            let snapshotConfiguration = WKSnapshotConfiguration()
            snapshotConfiguration.rect = CGRect(origin: .zero, size: pixelSize)
            snapshotConfiguration.afterScreenUpdates = true
            let image = try await withTimeout(seconds: 8) { @MainActor in
                try await webView.takeSnapshot(configuration: snapshotConfiguration)
            }
            webView.pageZoom = 1
            image.size = NSSize(width: width, height: height)
            Diagnostics.log("mermaid", "render.ok \(Int(width))x\(Int(height)) @\(effectiveScale)x")
            return .success(Rendered(image: image, svg: svg, size: CGSize(width: width, height: height)))
        } catch {
            Diagnostics.log("mermaid", "render.failed \(error.localizedDescription)")
            return .failure(.engine(error.localizedDescription))
        }
    }

    private func withTimeout<T: Sendable>(
        seconds: Double,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw RenderError.engine("render timed out")
            }
            guard let first = try await group.next() else {
                throw RenderError.engine("render cancelled")
            }
            group.cancelAll()
            return first
        }
    }

    // MARK: HTML

    private static func engineHTML() -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <style>
            html, body { margin: 0; padding: 0; }
            #c { display: inline-block; }
        </style>
        <script>\(mermaidJS)</script>
        </head><body><div id="c"></div>
        <script>
        let seq = 0;
        window.renderDiagram = async function(code, vars) {
            try {
                mermaid.initialize(Object.assign(JSON.parse(window.__baseConfig), { themeVariables: vars }));
                document.body.style.background = vars.background || '#FFFFFF';
                await mermaid.parse(code);
                const { svg } = await mermaid.render('m' + (++seq), code);
                const holder = document.getElementById('c');
                holder.innerHTML = svg;
                const el = holder.querySelector('svg');
                el.style.maxWidth = 'none';
                if (el.viewBox && el.viewBox.baseVal && el.viewBox.baseVal.width > 0) {
                    el.setAttribute('width', el.viewBox.baseVal.width + 'px');
                    el.setAttribute('height', el.viewBox.baseVal.height + 'px');
                }
                const rect = el.getBoundingClientRect();
                return JSON.stringify({ ok: true, svg: svg, w: rect.width, h: rect.height });
            } catch (e) {
                return JSON.stringify({ ok: false, error: String((e && e.message) || e) });
            }
        };
        window.__baseConfig = JSON.stringify({
            startOnLoad: false,
            securityLevel: 'strict',
            theme: 'base',
            fontFamily: "-apple-system, 'SF Pro Text', 'Helvetica Neue', Helvetica, Arial, sans-serif",
            flowchart: { curve: 'basis' }
        });
        </script></body></html>
        """
    }

    /// Full standalone page for the preview window: live SVG (text selectable,
    /// pinch-zoomable via `allowsMagnification`) rendered with the same config
    /// as the inline snapshot.
    static func previewHTML(code: String, theme: MermaidTheme) -> String {
        let codeJSON = jsonLiteral(code)
        let varsJSON = jsonLiteral(theme.variables)
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <style>
            html, body { margin: 0; padding: 0; background: \(theme.backgroundHex); }
            body { display: flex; justify-content: center; padding: 28px; box-sizing: border-box; }
            #c svg { max-width: 100%; height: auto; }
            #err { font: 13px -apple-system, sans-serif; color: #B45309; white-space: pre-wrap; max-width: 720px; }
            #err pre { font: 12px ui-monospace, Menlo, monospace; color: \(theme.variables["textColor"] ?? "#1D1D1F"); }
        </style>
        <script>\(mermaidJS)</script>
        </head><body><div id="c"></div>
        <script>
        (async function() {
            const code = \(codeJSON);
            try {
                mermaid.initialize({
                    startOnLoad: false,
                    securityLevel: 'strict',
                    theme: 'base',
                    themeVariables: \(varsJSON),
                    fontFamily: "-apple-system, 'SF Pro Text', 'Helvetica Neue', Helvetica, Arial, sans-serif",
                    flowchart: { curve: 'basis' }
                });
                await mermaid.parse(code);
                const { svg } = await mermaid.render('preview', code);
                document.getElementById('c').innerHTML = svg;
            } catch (e) {
                const err = document.createElement('div');
                err.id = 'err';
                const message = document.createTextNode(String((e && e.message) || e) + '\\n\\n');
                const pre = document.createElement('pre');
                pre.textContent = code;
                err.appendChild(message);
                err.appendChild(pre);
                document.body.replaceChildren(err);
            }
        })();
        </script></body></html>
        """
    }

    /// JSON-encodes a value for safe embedding inside a <script> block
    /// ("</" escaped so a literal "</script>" in diagram source can't break out).
    private static func jsonLiteral<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let json = String(data: data, encoding: .utf8) else { return "null" }
        return json.replacingOccurrences(of: "</", with: "<\\/")
    }
}
