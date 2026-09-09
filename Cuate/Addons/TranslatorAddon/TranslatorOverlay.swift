import AppKit
import Combine
import SwiftUI

/// What the bubble shows. Owned by the controller, observed by the view.
@MainActor
final class TranslatorBubbleModel: ObservableObject {
    enum Phase: Equatable {
        case thinking
        case streaming
        case done
        case failed
        case nothing
    }

    let original: String
    let opensDown: Bool
    let alignRight: Bool
    @Published var phase: Phase = .thinking
    @Published var text = ""
    @Published var chunkIndex = 0
    @Published var chunkCount = 0
    @Published var targetLanguage: String
    @Published var copied = false
    @Published var hovering = false
    /// 1 → 0 as the linger clock runs out.
    @Published var remaining: Double = 1
    @Published var bubbleSize = CGSize(width: TranslatorPlacement.minWidth, height: 60)
    @Published var bodyHeight: CGFloat = 20
    /// Flips on the turn of the loop after the panel appears: the spring.
    @Published var revealed = false

    init(original: String, targetLanguage: String, opensDown: Bool, alignRight: Bool) {
        self.original = original
        self.targetLanguage = targetLanguage
        self.opensDown = opensDown
        self.alignRight = alignRight
    }
}

/// What the bubble's controls do; the controller fills them in.
struct TranslatorBubbleActions {
    var copy: () -> Void
    var openInChat: () -> Void
    var switchLanguage: (String) -> Void
    var dismiss: () -> Void
}

/// The bubble's size from its text, measured with AppKit so the panel can be
/// framed in the same turn as the text changes (SwiftUI reports sizes a
/// beat later). The body is capped by the placement and scrolls past it.
@MainActor
enum TranslatorBubbleMetrics {
    static let font = NSFont.systemFont(ofSize: 13)
    static let headerHeight: CGFloat = 32
    static let sidePadding: CGFloat = 12
    static let bodyTop: CGFloat = 2
    static let bodyBottom: CGFloat = 10
    static let dotsHeight: CGFloat = 20

    static func measure(text: String, placement: TranslatorPlacement) -> (bubble: CGSize, body: CGFloat) {
        let maxBody = max(dotsHeight, placement.maxHeight - headerHeight - bodyTop - bodyBottom)
        guard !text.isEmpty else {
            let height = headerHeight + bodyTop + dotsHeight + bodyBottom
            return (CGSize(width: TranslatorPlacement.minWidth, height: height), dotsHeight)
        }
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: placement.maxWidth - 2 * sidePadding, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let width = min(placement.maxWidth, max(TranslatorPlacement.minWidth, ceil(bounds.width) + 2 * sidePadding))
        let body = min(maxBody, ceil(bounds.height) + 2)
        return (CGSize(width: width, height: headerHeight + bodyTop + body + bodyBottom), body)
    }
}

/// The translation bubble on screen: a non-activating panel next to the
/// selection (the frontmost app keeps its focus and its selection), the
/// text streamed into it chunk by chunk, a linger clock once the
/// translation is complete, Esc or a click anywhere else to close.
@MainActor
final class TranslatorOverlayController {
    private let settings = TranslatorSettings.shared
    private var panel: NSPanel?
    private var hosting: BubbleHostingView?
    private var model: TranslatorBubbleModel?
    private var placement: TranslatorPlacement?
    private var runTask: Task<Void, Never>?
    private var lingerTimer: Timer?
    private var lingerTotal: Double = 0
    private var lingerLeft: Double = 0
    private var relayoutTimer: Timer?
    private var eventMonitors: [Any] = []
    /// The shaped translations of the chunks done so far, joined.
    private var shapedPrefix = ""
    /// Bumped on every show/dismiss so late events of an earlier run are dropped.
    private var generation = 0

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Creates the panel at launch: a panel born while the Settings window
    /// holds the app at `.regular` never joins all Spaces (see
    /// `AppDelegate.makeWorldTimePanel`).
    func prepare() {
        _ = ensurePanel()
    }

    func show(text: String, at location: SelectionLocator.Location) {
        let placement = TranslatorPlacement.compute(selection: location.rect, screen: location.screen.visibleFrame)
        present(original: text, placement: placement, phase: .thinking)
        startRun()
    }

    func showNothingSelected(at location: SelectionLocator.Location) {
        let placement = TranslatorPlacement.compute(selection: location.rect, screen: location.screen.visibleFrame)
        present(original: "", placement: placement, phase: .nothing)
        model?.text = TRL("tr.bubble.nothing")
        relayout()
        startLinger(4)
    }

    func dismiss(animated: Bool = true) {
        generation += 1
        runTask?.cancel()
        runTask = nil
        stopLinger()
        relayoutTimer?.invalidate()
        relayoutTimer = nil
        removeMonitors()
        guard let panel, panel.isVisible else { return }
        if animated {
            let expected = generation
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self, self.generation == expected, let panel = self.panel else { return }
                    panel.orderOut(nil)
                    panel.alphaValue = 1
                }
            })
        } else {
            panel.orderOut(nil)
            panel.alphaValue = 1
        }
    }

    // MARK: - Presenting

    private func present(original: String, placement: TranslatorPlacement, phase: TranslatorBubbleModel.Phase) {
        dismiss(animated: false)
        generation += 1
        self.placement = placement
        shapedPrefix = ""
        let model = TranslatorBubbleModel(
            original: original,
            targetLanguage: settings.targetLanguage,
            opensDown: placement.opensDown,
            alignRight: placement.alignRight
        )
        model.phase = phase
        self.model = model

        let panel = ensurePanel()
        let actions = TranslatorBubbleActions(
            copy: { [weak self] in self?.copy() },
            openInChat: { [weak self] in self?.openInChat() },
            switchLanguage: { [weak self] language in self?.switchLanguage(language) },
            dismiss: { [weak self] in
                Diagnostics.log("translator", "bubble.dismiss via=button")
                self?.dismiss()
            }
        )
        let root = TranslatorBubbleRoot(model: model, actions: actions)
        if let hosting {
            hosting.rootView = root
        } else {
            let hosting = BubbleHostingView(rootView: root)
            hosting.wantsLayer = true
            hosting.layer?.backgroundColor = NSColor.clear.cgColor
            panel.contentView = hosting
            self.hosting = hosting
        }
        relayout()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        installMonitors()
        DispatchQueue.main.async { [weak model] in model?.revealed = true }
        Diagnostics.log("translator", "bubble.show down=\(placement.opensDown) right=\(placement.alignRight) chars=\(original.count)")
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 100),
            // .nonactivatingPanel: showing the bubble never takes focus from
            // the app whose text was selected; a click inside makes it key
            // (like a popover) so the translation can be selected and copied,
            // without activating Cuate.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        // The bubble draws its own shadow; a window shadow would wrap the
        // transparent margin around it.
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // The bubble is the dictation island's material: dark in both appearances.
        panel.appearance = NSAppearance(named: .darkAqua)
        self.panel = panel
        return panel
    }

    /// Frames the panel for the current text. Streaming calls this often;
    /// `scheduleRelayout` coalesces the measurements.
    private func relayout() {
        guard let model, let placement, let panel else { return }
        let measured = TranslatorBubbleMetrics.measure(text: model.text, placement: placement)
        model.bubbleSize = measured.bubble
        model.bodyHeight = measured.body
        panel.setFrame(placement.panelFrame(size: measured.bubble), display: true)
    }

    private func scheduleRelayout() {
        guard relayoutTimer == nil else { return }
        relayoutTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.relayoutTimer = nil
                self.relayout()
            }
        }
    }

    // MARK: - The run

    private func startRun() {
        guard let model else { return }
        let expected = generation
        let original = model.original
        runTask = Task { [weak self] in
            await TranslatorService.run(text: original, settings: TranslatorSettings.shared) { [weak self] event in
                guard let self, self.generation == expected else { return }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: TranslatorService.Event) {
        guard let model else { return }
        switch event {
        case .started(let count):
            model.chunkCount = count
        case .chunkBegan(let index):
            model.chunkIndex = index
        case .partial(let partial):
            let preview = TranslatorPrompt.livePreview(partial)
            guard !preview.isEmpty || !shapedPrefix.isEmpty else { return }
            model.phase = .streaming
            model.text = Self.join(shapedPrefix, preview)
            scheduleRelayout()
        case .chunkEnded(let shaped):
            shapedPrefix = Self.join(shapedPrefix, shaped)
            model.phase = .streaming
            model.text = shapedPrefix
            scheduleRelayout()
        case .finished:
            model.phase = .done
            model.text = shapedPrefix
            relayoutTimer?.invalidate()
            relayoutTimer = nil
            relayout()
            startLinger(settings.lingerSeconds)
        case .failed(let message):
            model.phase = .failed
            model.text = message
            relayoutTimer?.invalidate()
            relayoutTimer = nil
            relayout()
            startLinger(8)
        }
    }

    private static func join(_ prefix: String, _ piece: String) -> String {
        if prefix.isEmpty { return piece }
        if piece.isEmpty { return prefix }
        return prefix + "\n\n" + piece
    }

    // MARK: - The linger clock

    private func startLinger(_ seconds: Double) {
        stopLinger()
        lingerTotal = max(1, seconds)
        lingerLeft = lingerTotal
        model?.remaining = 1
        lingerTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickLinger() }
        }
    }

    private func stopLinger() {
        lingerTimer?.invalidate()
        lingerTimer = nil
    }

    private func tickLinger() {
        guard let model else { return }
        // The pointer on the bubble holds the clock: the user is reading.
        if model.hovering { return }
        lingerLeft -= 0.1
        model.remaining = max(0, lingerLeft / lingerTotal)
        if lingerLeft <= 0 {
            Diagnostics.log("translator", "bubble.dismiss via=timeout")
            dismiss()
        }
    }

    // MARK: - Esc and clicks elsewhere

    private func installMonitors() {
        removeMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            Task { @MainActor in self?.handleEvent(event, global: true) }
        }) {
            eventMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            Task { @MainActor in self?.handleEvent(event, global: false) }
            return event
        }) {
            eventMonitors.append(monitor)
        }
    }

    private func removeMonitors() {
        eventMonitors.forEach { NSEvent.removeMonitor($0) }
        eventMonitors.removeAll()
    }

    private func handleEvent(_ event: NSEvent, global: Bool) {
        guard let panel, panel.isVisible else { return }
        if event.type == .keyDown {
            if event.keyCode == 53 { // Esc
                Diagnostics.log("translator", "bubble.dismiss via=esc")
                dismiss()
            }
            return
        }
        // A click inside the bubble is the bubble's business.
        if event.window === panel { return }
        if !panel.frame.contains(NSEvent.mouseLocation) {
            Diagnostics.log("translator", "bubble.dismiss via=clickOutside")
            dismiss()
        }
    }

    // MARK: - Actions

    private func copy() {
        guard let model, !model.text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(model.text, forType: .string)
        model.copied = true
        Diagnostics.log("translator", "bubble.copy chars=\(model.text.count)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak model] in model?.copied = false }
    }

    private func openInChat() {
        guard let model, !model.original.isEmpty else { return }
        Diagnostics.log("translator", "bubble.openInChat chars=\(model.original.count)")
        NotificationCenter.default.post(name: .translatorOpenInChat, object: model.original)
        dismiss()
    }

    /// Re-runs the same selection into another language; the choice sticks.
    private func switchLanguage(_ language: String) {
        guard let model, !model.original.isEmpty, language != model.targetLanguage else { return }
        settings.targetLanguage = language
        Diagnostics.log("translator", "bubble.language")
        runTask?.cancel()
        stopLinger()
        generation += 1
        shapedPrefix = ""
        model.targetLanguage = language
        model.phase = .thinking
        model.text = ""
        model.chunkIndex = 0
        model.chunkCount = 0
        model.remaining = 1
        relayout()
        startRun()
    }
}

private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The header's buttons react to the very click that makes the panel key.
/// Deliberately not generic: a generic NSHostingView subclass crashed the
/// Release optimizer (Swift 6.3.2, EarlyPerfInliner on its deinit).
final class BubbleHostingView: NSHostingView<TranslatorBubbleRoot> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    required init(rootView: TranslatorBubbleRoot) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
