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
    private static let backfillThreshold: CGFloat = 300

    // MARK: Callbacks (wired by the representable)

    var onNearBottomChange: ((Bool) -> Void)?
    var onContentFitsChange: ((Bool) -> Void)?
    var onViewportWidthChange: ((CGFloat) -> Void)?
    var onNeedOlder: (() -> Void)?

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

    // MARK: Applying row updates (point updates, not diff-the-world)

    /// Reconciles the transcript to `items`. Rows are matched by id: kept
    /// rows keep their hosting view (and all transient SwiftUI state in it),
    /// changed revisions swap only that row's rootView, insertions and
    /// removals touch only their own positions. When `resetToken` changes
    /// (conversation switch) the transcript is rebuilt and pinned to the
    /// bottom.
    func apply(items: [TranscriptItem], resetToken newToken: String) {
        let isReset = newToken != resetToken
        resetToken = newToken

        // Visual anchor for offset compensation: the first on-screen row
        // that survives the update keeps its screen position when content
        // is prepended above it (the "reading history while a backfill
        // lands" case).
        let newIDs = Set(items.map(\.id))
        var anchor: (id: String, offsetInViewport: CGFloat)?
        if !isPinnedToBottom, !isReset {
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
            for row in rows { stack.removeArrangedSubview(row.host); row.host.removeFromSuperview() }
            rows = items.map { makeRow($0) }
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
        } else if let anchor,
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
                    let row = recycled[id] ?? makeRow(itemsByID[id]!)
                    rows.insert(row, at: offset)
                    stack.insertArrangedSubview(row.host, at: offset)
                }
            }
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
    override func scrollWheel(with event: NSEvent) {
        if event.scrollingDeltaY > 0, documentHeight > viewportHeight, isPinnedToBottom {
            isPinnedToBottom = false
            reportNearBottom(false)
        }
        super.scrollWheel(with: event)
    }

    /// Clip bounds moved. Our own (programmatic) moves are flagged; anything
    /// else is the user, and the pin state follows their position with
    /// hysteresis.
    @objc private func clipBoundsChanged(_ note: Notification) {
        guard programmaticScrollDepth == 0 else { return }
        if isPinnedToBottom {
            if distanceFromBottom > Self.unpinDistance {
                isPinnedToBottom = false
                reportNearBottom(false)
            }
        } else if distanceFromBottom < Self.repinDistance {
            isPinnedToBottom = true
            reportNearBottom(true)
        }

        if contentView.bounds.origin.y < Self.backfillThreshold,
           documentHeight > viewportHeight,
           Date().timeIntervalSince(lastBackfillRequest) > 0.2 {
            lastBackfillRequest = Date()
            onNeedOlder?()
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
