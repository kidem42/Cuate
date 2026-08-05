import AppKit
import SwiftUI

// MARK: - Transcript engine (AppKit)
//
// The chat transcript is the one place where SwiftUI's declarative scrolling
// model fought us on every release: `ScrollViewReader.scrollTo` on a lazy
// list is a silent no-op for unrendered ids, the bottom anchor and animated
// scrolls raced each other, and every fix was another `asyncAfter`. This
// engine replaces the container with the architecture every production chat
// client uses (Telegram macOS, Slack, iMessage):
//
//  1. POINT UPDATES — the view is told "row N changed / rows prepended",
//     never "here is the new array, diff it yourself".
//  2. OWNED OFFSET — scrolling is a number we set synchronously; there is
//     no "scroll to an id that may not exist yet".
//  3. PIN-TO-BOTTOM AS AN INVARIANT — "if the user was at the bottom, stay
//     at the bottom" is re-asserted after every layout change, instantly.
//     It is not an animation chasing a moving target.
//  4. Bubbles stay SwiftUI (`MessageRow`, themes, markdown) inside
//     `NSHostingView` rows — only the container is AppKit.
//
// The row set is windowed (ChatWindow keeps ~30..90 rows alive), so rows are
// not virtualized: every windowed row has a live hosting view, Auto Layout
// owns the heights, and prepending compensates the offset by re-anchoring
// the first visible row. That is deterministic and removes the entire
// "estimated height landed short" class of bugs.

/// One row of the transcript. `revision` cheaply answers "did this row's
/// content change?" — the SwiftUI view is only rebuilt when it differs.
struct TranscriptItem {
    let id: String
    let revision: AnyHashable
    let content: () -> AnyView
}

/// Handle ChatWindow uses to command the transcript (scroll to bottom on
/// send/summon). A plain class on purpose: commands are imperative events,
/// not state, and must not trigger SwiftUI invalidation.
final class TranscriptController {
    weak var engine: TranscriptEngineView?

    func scrollToBottom(animated: Bool) {
        engine?.scrollToBottom(animated: animated)
    }

    /// Scrolls a specific row (message id) into view — pinned-message
    /// navigation. Drops the bottom pin like a manual scroll would.
    func scrollTo(id: String, animated: Bool = true) {
        if engine == nil { Diagnostics.log("transcript", "scrollTo no-engine id=\(id)") }
        engine?.scrollTo(id: id, animated: animated)
    }

    /// Whether the row is meaningfully on screen right now. The pinned bar
    /// uses it for Telegram-style clicks: jump to the shown pin first, and
    /// only cycle onward once that pin is in view.
    func isRowVisible(id: String) -> Bool {
        engine?.isRowVisible(id: id) ?? false
    }

    /// Whether the viewport is currently pinned to the newest content.
    var isPinnedToBottom: Bool { engine?.isPinnedToBottom ?? true }
}

final class TranscriptEngineView: NSScrollView {
    // MARK: Configuration

    /// Hysteresis for the pin. Losing the pin takes a deliberate move away
    /// (> unpin distance); regaining it means actually parking at the bottom
    /// (< repin distance). Symmetric thresholds oscillated: a small nudge up
    /// stayed "near enough" and the next flush yanked the view back down.
    private static let unpinDistance: CGFloat = 44
    private static let repinDistance: CGFloat = 8
    /// Scrolling within this distance of the top asks for older history.
    /// Generous on purpose: the page should be trickling in BEFORE the user
    /// reaches the top, so the prepend never lands under their thumb.
    private static let backfillThreshold: CGFloat = 900

    // MARK: Callbacks (wired by the representable)

    var onNearBottomChange: ((Bool) -> Void)?
    var onContentFitsChange: ((Bool) -> Void)?
    var onViewportWidthChange: ((CGFloat) -> Void)?
    var onNeedOlder: (() -> Void)?
    /// Nearing the BOTTOM edge of a window whose newest rows were dropped
    /// (capped deep-history reading) asks for them back. Fires whenever the
    /// viewport is close to the bottom — the owner no-ops when nothing is
    /// dropped, so there is no pin guard here (the drain must run even as
    /// momentum carries the user onto the temporary bottom).
    var onNeedNewer: (() -> Void)?

    // MARK: State

    /// The invariant: while true, every content-height change snaps the
    /// viewport back to the bottom (instantly — smoothness during streaming
    /// comes from small frequent steps, not from animating the scroll).
    private(set) var isPinnedToBottom = true

    private final class FlippedStackView: NSStackView {
        override var isFlipped: Bool { true }
    }

    private struct Row {
        let id: String
        var revision: AnyHashable
        let host: NSHostingView<AnyView>
    }

    private let stack = FlippedStackView()
    private var rows: [Row] = []
    /// Telegram-style row recycling: rows dropped by the sliding window are
    /// PARKED here instead of discarded — scrolling back re-attaches the
    /// same hosting view, skipping the SwiftUI re-create + platform-view
    /// layout that dominated the scroll profile (2026-07-28: ~13% of the
    /// main thread in `NSHostingView.layout` re-building rows whose content
    /// had not changed). LRU-capped; a stale revision on the way back in
    /// just swaps the rootView, same as any row update.
    private var retiredRows: [String: Row] = [:]
    private var retiredOrder: [String] = []
    private static let retiredCap = 120
    /// Conversation identity of the current row set. When it changes the
    /// whole transcript is replaced and the pin re-engages (a freshly opened
    /// conversation always lands on its newest message).
    private var resetToken: String = ""
    /// Non-zero while WE move the clip view — user-scroll classification
    /// must ignore those bounds changes.
    private var programmaticScrollDepth = 0
    private var lastReportedNearBottom = true
    private var lastReportedFits = true
    private var lastReportedWidth: CGFloat = 0
    private var lastBackfillRequest = Date.distantPast
    private var lastRestoreRequest = Date.distantPast
    /// Distinguishes viewport resizes from user scrolls in
    /// `clipBoundsChanged` — only origin moves classify the pin.
    private var lastViewportSize = NSSize.zero
    /// Origin at the last clip-bounds notification (programmatic moves
    /// update it too — their notifications fire inside the depth guard).
    /// Classification compares against it: a bounds event whose origin did
    /// NOT move is the DOCUMENT changing under a stationary viewport, never
    /// the user scrolling.
    private var lastObservedOriginY: CGFloat = 0
    /// Freshest row set that arrived while the panel was ordered out. A
    /// hidden window must not pay for reconciliation, row body evaluation
    /// and Auto Layout — that work ran at full tilt off screen and, combined
    /// with the measure loop (see ChatTranscriptView.sizeThatFits), burned a
    /// core for hours (2026-08-03). ONLY the view work is deferred: stores,
    /// stream slots, Hermes mirror sync and agent turns keep running —
    /// showing the panel flushes this in one coalesced apply.
    private var pendingWhileHidden: (items: [TranscriptItem], resetToken: String)?
    /// The document changed under the frozen (hidden) viewport with no row
    /// update pending — the live streaming bubble grows PAST `apply` (its
    /// SwiftUI content observes the stream model directly). The flush at
    /// show must re-assert the pin exactly once for that case.
    private var needsPinReassertOnShow = false

    /// "On screen" for the freeze: attached to a window that is ordered in.
    /// `isVisible` (not occlusion) on purpose — it flips synchronously with
    /// orderFront/orderOut, so a summon never shows a stale frame while
    /// WindowServer's occlusion callback is still in flight.
    private var isWindowOnScreen: Bool { window?.isVisible == true }

    // MARK: Init

    init() {
        super.init(frame: .zero)

        drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        verticalScrollElasticity = .allowed
        horizontalScrollElasticity = .none
        automaticallyAdjustsContentInsets = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        documentView = stack
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.widthAnchor.constraint(equalTo: contentView.widthAnchor),
        ])

        // Content growth (a streaming bubble getting taller, a row appended)
        // arrives here — this is where the pin invariant lives.
        stack.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(documentFrameChanged),
            name: NSView.frameDidChangeNotification, object: stack)

        // User scrolling arrives as clip-view bounds changes.
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipBoundsChanged),
            name: NSView.boundsDidChangeNotification, object: contentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unsupported") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Geometry helpers

    private var documentHeight: CGFloat { stack.frame.height }
    private var viewportHeight: CGFloat { contentView.bounds.height }
    private var bottomOriginY: CGFloat { max(0, documentHeight - viewportHeight) }
    private var distanceFromBottom: CGFloat {
        documentHeight - (contentView.bounds.origin.y + viewportHeight)
    }

    override func layout() {
        super.layout()
        let width = contentView.bounds.width
        if width > 0, abs(width - lastReportedWidth) > 0.5 {
            lastReportedWidth = width
            onViewportWidthChange?(width)
        }
        reportContentFits()
    }

    // MARK: Hidden-panel freeze

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Track our own window's ordering in/out. Re-subscribed per window —
        // the engine lives in one panel for its whole life, but stay correct
        // if that ever changes.
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowOcclusionChanged),
                name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        flushPendingIfVisible()
    }

    @objc private func windowOcclusionChanged(_ note: Notification) {
        flushPendingIfVisible()
    }

    /// Synchronous backstop: runs before the first frame of a freshly
    /// ordered-in window draws, so a summon can never flash frozen content
    /// even if no notification has landed yet.
    override func viewWillDraw() {
        flushPendingIfVisible()
        super.viewWillDraw()
    }

    private func flushPendingIfVisible() {
        guard isWindowOnScreen else { return }
        if let pending = pendingWhileHidden {
            pendingWhileHidden = nil
            needsPinReassertOnShow = false
            // The apply re-asserts the pin itself (and re-anchors when the
            // user had scrolled away).
            apply(items: pending.items, resetToken: pending.resetToken)
        } else if needsPinReassertOnShow {
            // One-shot, only for the "grew while hidden" transition — this
            // hook also runs on every ordinary draw (viewWillDraw), where a
            // blanket re-assert would snap the viewport mid-glide and kill
            // animated scrolls.
            needsPinReassertOnShow = false
            layoutSubtreeIfNeeded()
            if isPinnedToBottom { scrollToBottomInstant() }
            reportContentFits()
        }
    }

    // MARK: Applying row updates (point updates, not diff-the-world)

    /// Reconciles the transcript to `items`. Rows are matched by id: kept
    /// rows keep their hosting view (and all transient SwiftUI state in it),
    /// changed revisions swap only that row's rootView, insertions and
    /// removals touch only their own positions. When `resetToken` changes
    /// (conversation switch) the transcript is rebuilt and pinned to the
    /// bottom.
    func apply(items: [TranscriptItem], resetToken newToken: String) {
        // Hidden panel: park the freshest set and do nothing. Every path
        // that puts the window back on screen flushes it (viewDidMoveToWindow,
        // occlusion change, viewWillDraw) before the first visible frame.
        guard isWindowOnScreen else {
            pendingWhileHidden = (items, newToken)
            return
        }
        pendingWhileHidden = nil
        let isReset = newToken != resetToken
        resetToken = newToken

        // Visual anchor for offset compensation: the first on-screen row
        // that survives the update keeps its screen position when content
        // is prepended above it (the "reading history while a backfill
        // lands" case).
        let newIDs = Set(items.map(\.id))
        var anchor: (id: String, offsetInViewport: CGFloat)?
        // Skip while a programmatic glide is in flight (pinned-message jump):
        // anchoring to the not-yet-moved origin would cancel the animation
        // and snap the view right back.
        if !isPinnedToBottom, !isReset, programmaticScrollDepth == 0 {
            let visibleTop = contentView.bounds.origin.y
            for row in rows where newIDs.contains(row.id) {
                let rowMaxY = row.host.frame.maxY
                if rowMaxY > visibleTop {
                    anchor = (row.id, row.host.frame.minY - visibleTop)
                    break
                }
            }
        }

        if isReset {
            for row in rows { retire(row) }
            // Coming BACK to a recently viewed conversation reuses its
            // parked rows (message ids are stable across the switch).
            rows = items.map { dequeueRetired($0) ?? makeRow($0) }
            for row in rows { stack.addArrangedSubview(row.host) }
            isPinnedToBottom = true
        } else {
            reconcile(items)
        }

        // Resolve the new layout NOW — offset math needs real frames, and
        // deferring it is exactly the "scroll before layout settles" bug
        // class this engine exists to kill.
        layoutSubtreeIfNeeded()

        if isPinnedToBottom {
            scrollToBottomInstant()
        } else if programmaticScrollDepth == 0, let anchor,
                  let row = rows.first(where: { $0.id == anchor.id }) {
            setOriginY(row.host.frame.minY - anchor.offsetInViewport)
        }
        reportContentFits()
    }

    private func reconcile(_ items: [TranscriptItem]) {
        let oldIDs = rows.map(\.id)
        let newIDs = items.map(\.id)

        if oldIDs != newIDs {
            let diff = newIDs.difference(from: oldIDs)
            // A moved id surfaces as removal+insertion — recycle its hosting
            // view so the row keeps its SwiftUI state across the move.
            var recycled: [String: Row] = [:]
            for change in diff.removals.reversed() {
                if case let .remove(offset, id, _) = change {
                    let row = rows.remove(at: offset)
                    stack.removeArrangedSubview(row.host)
                    row.host.removeFromSuperview()
                    recycled[id] = row
                }
            }
            let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            for change in diff.insertions {
                if case let .insert(offset, id, _) = change {
                    let row = recycled.removeValue(forKey: id)
                        ?? dequeueRetired(itemsByID[id]!)
                        ?? makeRow(itemsByID[id]!)
                    rows.insert(row, at: offset)
                    stack.insertArrangedSubview(row.host, at: offset)
                }
            }
            // Rows that actually left the window park in the retirement
            // pool — the sliding window drops exactly the rows most likely
            // to scroll right back in.
            for (_, row) in recycled { retire(row) }
        }

        // Revision pass: swap rootView only where content actually changed.
        for (index, item) in items.enumerated() where rows[index].revision != item.revision {
            rows[index].revision = item.revision
            rows[index].host.rootView = item.content()
        }
    }

    private func makeRow(_ item: TranscriptItem) -> Row {
        let host = NSHostingView(rootView: item.content())
        host.translatesAutoresizingMaskIntoConstraints = false
        host.sizingOptions = [.intrinsicContentSize]
        return Row(id: item.id, revision: item.revision, host: host)
    }

    /// Parks a detached row for likely reuse (LRU-capped). Detachment is
    /// idempotent ON PURPOSE: reconcile's removal loop has usually detached
    /// the row already, and NSStackView RAISES on removing a non-arranged
    /// view — that exception, thrown mid-update, is exactly what wedged the
    /// whole window before the apply was deferred (frozen panel after the
    /// first message; crash report 2026-07-28-122750 once it could surface).
    private func retire(_ row: Row) {
        if row.host.superview != nil {
            if stack.arrangedSubviews.contains(row.host) {
                stack.removeArrangedSubview(row.host)
            }
            row.host.removeFromSuperview()
        }
        if retiredRows.updateValue(row, forKey: row.id) == nil {
            retiredOrder.append(row.id)
        }
        while retiredOrder.count > Self.retiredCap {
            retiredRows.removeValue(forKey: retiredOrder.removeFirst())
        }
    }

    /// Takes a parked row back out; a changed revision (theme switch, width
    /// change, edited content) swaps the rootView on the way — same cost as
    /// any row update, still far cheaper than a fresh hosting view.
    private func dequeueRetired(_ item: TranscriptItem) -> Row? {
        guard var row = retiredRows.removeValue(forKey: item.id) else { return nil }
        retiredOrder.removeAll { $0 == item.id }
        if row.revision != item.revision {
            row.revision = item.revision
            row.host.rootView = item.content()
        }
        return row
    }

    // MARK: Scrolling

    func scrollToBottom(animated: Bool) {
        isPinnedToBottom = true
        reportNearBottom(true)
        guard animated else {
            scrollToBottomInstant()
            return
        }
        programmaticScrollDepth += 1
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: bottomOriginY))
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.programmaticScrollDepth -= 1
            // Content may have grown mid-glide; the invariant catches up.
            if self.isPinnedToBottom { self.scrollToBottomInstant() }
        }
    }

    private func scrollToBottomInstant() {
        setOriginY(bottomOriginY)
    }

    /// Brings a row to (near) the top of the viewport — the pinned-message
    /// jump. Behaves like a user scroll: the bottom pin is dropped so the
    /// next stream flush cannot yank the view back down.
    func scrollTo(id: String, animated: Bool) {
        guard let row = rows.first(where: { $0.id == id }) else {
            Diagnostics.log("transcript", "scrollTo miss id=\(id) rows=\(rows.count)")
            return
        }
        stack.layoutSubtreeIfNeeded()
        let target = max(0, min(row.host.frame.minY - 24, bottomOriginY))
        if target >= bottomOriginY - Self.repinDistance {
            // The pinned row IS the newest content — the jump stays at the
            // bottom, so the pin (and the hidden jump-to-latest button)
            // keep their state.
            isPinnedToBottom = true
        } else {
            isPinnedToBottom = false
            // Programmatic move: clipBoundsChanged won't classify it — the
            // report must be explicit, or the jump-to-latest button never
            // appears after a pinned-message jump and the only way back
            // down is the wheel (e2e 2026-07-27).
            reportNearBottom(false)
            Diagnostics.log("transcript", "pin.drop jump id=\(id)")
        }
        guard animated else {
            setOriginY(target)
            return
        }
        programmaticScrollDepth += 1
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: target))
        } completionHandler: { [weak self] in
            self?.programmaticScrollDepth -= 1
        }
        reflectScrolledClipView(contentView)
    }

    /// A row counts as visible when a meaningful slice of it (32pt, or the
    /// whole row if shorter) is inside the viewport — a sliver peeking from
    /// an edge shouldn't satisfy "I'm looking at it".
    func isRowVisible(id: String) -> Bool {
        guard let row = rows.first(where: { $0.id == id }) else { return false }
        stack.layoutSubtreeIfNeeded()
        let overlap = row.host.frame.intersection(contentView.documentVisibleRect)
        guard !overlap.isNull else { return false }
        return overlap.height >= min(row.host.frame.height, 32)
    }

    private func setOriginY(_ y: CGFloat) {
        programmaticScrollDepth += 1
        contentView.setBoundsOrigin(NSPoint(x: 0, y: max(0, min(y, bottomOriginY))))
        reflectScrolledClipView(contentView)
        programmaticScrollDepth -= 1
    }

    // MARK: Change classification

    /// Document grew or shrank (streamed text, image loaded, row swapped).
    /// While pinned, the viewport follows instantly — THE streaming
    /// auto-follow, with no animation to retarget and nothing to race.
    @objc private func documentFrameChanged(_ note: Notification) {
        // Hidden panel: the streaming bubble can still grow the document off
        // screen — don't chase it, the flush at show re-asserts the pin.
        guard isWindowOnScreen else {
            if isPinnedToBottom { needsPinReassertOnShow = true }
            return
        }
        if isPinnedToBottom {
            scrollToBottomInstant()
        }
        reportContentFits()
    }

    /// An upward wheel/trackpad scroll over scrollable content is an
    /// explicit "let me read history" gesture — it drops the pin BEFORE the
    /// next flush can re-assert the bottom, so streaming never overrides the
    /// user's hand. (The old SwiftUI transcript needed a global NSEvent
    /// monitor for this; owning the scroll view makes it one override.)
    ///
    /// Momentum-tail events are NOT that gesture: the inertia after a flick
    /// down and the elastic bounce at the bottom both deliver stray positive
    /// deltas. If those unpinned, auto-follow died silently right after the
    /// user parked at the bottom — the document grows before the 8pt repin
    /// window can catch, so the pin never came back.
    override func scrollWheel(with event: NSEvent) {
        if event.scrollingDeltaY > 0, event.momentumPhase == [],
           documentHeight > viewportHeight, isPinnedToBottom {
            isPinnedToBottom = false
            reportNearBottom(false)
            Diagnostics.log("transcript", "pin.drop wheel dy=\(String(format: "%.1f", event.scrollingDeltaY))")
        }
        super.scrollWheel(with: event)
    }

    /// Clip bounds moved. Our own (programmatic) moves are flagged; anything
    /// else is the user, and the pin state follows their position with
    /// hysteresis.
    @objc private func clipBoundsChanged(_ note: Notification) {
        // Origin tracking feeds classification below; programmatic moves
        // consume their own delta here too (their notifications arrive
        // synchronously inside the depth guard).
        let originY = contentView.bounds.origin.y
        let originMoved = abs(originY - lastObservedOriginY) > 0.5
        lastObservedOriginY = originY
        // Hidden panel: keep the baselines fresh (above) but classify
        // nothing — there is no user hand off screen, and pin/backfill
        // decisions from stale geometry would be wrong anyway.
        guard isWindowOnScreen else {
            lastViewportSize = contentView.bounds.size
            return
        }
        // A bounds SIZE change is geometry, not scrolling: the composer grew
        // (file pills, slash suggestions, recording bar), the pinned bar
        // toggled, the window resized. Re-assert the pin instead of
        // classifying it — a viewport shrink used to read as "the user moved
        // 44pt away" and silently killed auto-follow.
        let viewportSize = contentView.bounds.size
        if viewportSize != lastViewportSize {
            lastViewportSize = viewportSize
            if isPinnedToBottom { scrollToBottomInstant() }
            reportContentFits()
            return
        }
        guard programmaticScrollDepth == 0 else { return }
        if isPinnedToBottom {
            // Unpin needs BOTH: the viewport actually moved (the user's
            // hand) AND it ended far from the bottom. Distance alone also
            // grows when the STREAMING BUBBLE grows under a stationary
            // viewport — classifying that as "user scrolled away" killed
            // auto-follow the moment 30 Hz growth outran the follow
            // (pin.drop bounds distance=50, 2026-07-29 11:29).
            if originMoved, distanceFromBottom > Self.unpinDistance {
                isPinnedToBottom = false
                reportNearBottom(false)
                Diagnostics.log("transcript", "pin.drop bounds distance=\(Int(distanceFromBottom)) doc=\(Int(documentHeight))")
            }
        } else if distanceFromBottom < Self.repinDistance {
            isPinnedToBottom = true
            reportNearBottom(true)
            Diagnostics.log("transcript", "pin.gain bounds")
        }

        // Only while actually reading history: at the bottom the wide
        // threshold would otherwise start paging the moment a short chat
        // opens, loading rows nobody asked to see.
        if !isPinnedToBottom,
           contentView.bounds.origin.y < Self.backfillThreshold,
           documentHeight > viewportHeight,
           Date().timeIntervalSince(lastBackfillRequest) > 0.2 {
            lastBackfillRequest = Date()
            onNeedOlder?()
        }

        // Symmetric bottom trigger for the capped window (dropped newest
        // rows re-enter as the user comes back down).
        if distanceFromBottom < Self.backfillThreshold,
           documentHeight > viewportHeight,
           Date().timeIntervalSince(lastRestoreRequest) > 0.2 {
            lastRestoreRequest = Date()
            onNeedNewer?()
        }
    }

    // MARK: Reporting

    private func reportNearBottom(_ nearBottom: Bool) {
        guard nearBottom != lastReportedNearBottom else { return }
        lastReportedNearBottom = nearBottom
        onNearBottomChange?(nearBottom)
    }

    private func reportContentFits() {
        let fits = documentHeight <= viewportHeight + 1
        guard fits != lastReportedFits else { return }
        lastReportedFits = fits
        onContentFitsChange?(fits)
    }
}
