import AppKit
import Carbon
import Combine

/// Automatic, deterministic keyboard-layout corrector (AutoSwitcher).
///
/// Detection is primarily *statistical* (see NgramScorer/DecisionEngine):
/// character-trigram probabilities plus word frequencies decide which layout
/// the user meant — the system dictionary is only a supporting signal. This is
/// why it handles names, word forms and even typos that a dictionary-only
/// approach cannot.
///
/// Corrections fire on three paths:
///  - space boundary (async off the tap),
///  - plain Enter (sync — the Enter is deferred, fixed text is committed),
///  - mid-word "early switch" once the typed prefix is impossible in its
///    layout (optional).
final class AutoSwitcher {

    struct Config {
        var switchSystemLayout = true
        var minWordLength = 2
        var earlySwitch = true
        var autoCapitalize = true
        var debug = false
    }

    var config = Config() {
        didSet { monitor.autoCapitalize = config.autoCapitalize }
    }

    private let monitor = KeystrokeMonitor()
    private let engine = SystemLayoutEngine()
    private let validator = LanguageValidator()
    /// Lazy: the bundled models (file I/O + parse) shouldn't load at app
    /// launch for users who never enable auto mode; `start()` touches it so
    /// the cost is paid on activation, not inside the first tap decision.
    private lazy var scorers = NgramScorer.loadBundled()

    /// Guards the state shared between the tap thread (sync decision paths)
    /// and the main thread (boundary path, observers): layout cache, learned
    /// exceptions snapshot, frontmost-app cache, last correction.
    private let lock = NSLock()

    private var cachedLayouts: [SystemLayoutEngine.Layout]?
    private var layoutObserver: NSObjectProtocol?

    /// Snapshot of `LayoutFixSettings.exceptions` — the settings object is
    /// main-actor, and the tap thread must not touch it (nor block on main).
    private var exceptionsSnapshot: Set<String> = []
    private var exceptionsCancellable: AnyCancellable?

    /// Frontmost app's bundle id, maintained on the main thread via workspace
    /// notifications — `NSWorkspace.frontmostApplication` is not something the
    /// tap thread should query per keystroke.
    private var frontmostBundleID: String?
    private var frontmostObserver: NSObjectProtocol?

    /// Enough to revert the last correction on an immediate Backspace.
    private struct LastCorrection {
        let original: String
        let converted: String
        let boundary: String
        let previousLayoutID: String
    }
    private var lastCorrection: LastCorrection?

    /// Apps where auto-fix must never fire (terminals: commands, and Secure
    /// Keyboard Entry hides keystrokes there anyway).
    private static let blockedApps: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "org.alacritty",
        "net.kovidgoyal.kitty", "dev.warp.Warp-Stable", "co.zeit.hyper"
    ]

    var isRunning: Bool { monitor.isRunning }

    // MARK: - Logging (plain file, readable directly)

    static var logFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/AISpotlight-LayoutFix.log")
    }

    private func log(_ message: @autoclosure () -> String) {
        guard config.debug else { return }
        let line = "[LayoutFix] \(message())\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = Self.logFileURL
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: url)
        }
    }

    // MARK: - Lifecycle

    @discardableResult
    func start() -> Bool {
        monitor.onWord = { [weak self] word, keys, _ in
            // Hop off the tap callback so detection never blocks it.
            DispatchQueue.main.async { self?.handleBoundary(word, keys: keys) }
        }
        monitor.onCommitDecision = { [weak self] word, keys in
            self?.decideForCommit(word, keys: keys)
        }
        monitor.onEarlyCheck = { [weak self] word, keys in
            guard let self, self.config.earlySwitch else { return nil }
            return self.decideEarly(word, keys: keys)
        }
        monitor.onUndoRequested = { [weak self] in
            DispatchQueue.main.async { self?.undoLast() }
        }
        monitor.onTapAutoReenabled = { [weak self] in
            self?.log("!! tap was disabled by the system and re-enabled (keystrokes lost in the gap)")
        }
        monitor.autoCapitalize = config.autoCapitalize
        monitor.capitalizationAllowed = { [weak self] in
            self?.guardsPass(verbose: false) ?? false
        }
        guard monitor.start() else {
            log("tap failed to start — Accessibility permission missing?")
            return false
        }
        _ = scorers   // load the ngram models now, not inside a tap decision
        refreshLayoutsOnMain()      // prefill so the tap thread only ever reads
        observeLayoutChanges()
        observeFrontmostApp()
        observeExceptions()
        warmDictionaries()
        if config.debug { try? Data().write(to: Self.logFileURL) }   // fresh session
        log("monitor started; layouts: \(layouts().map { "\($0.localizedName)(\(languageOf($0) ?? "?"))" }); models: \(scorers.keys.sorted())")
        return true
    }

    func stop() {
        monitor.stop()
        if let layoutObserver {
            DistributedNotificationCenter.default().removeObserver(layoutObserver)
        }
        layoutObserver = nil
        if let frontmostObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(frontmostObserver)
        }
        frontmostObserver = nil
        exceptionsCancellable = nil
        lock.lock()
        cachedLayouts = nil
        lastCorrection = nil
        lock.unlock()
    }

    // MARK: - Layout cache + language mapping + dictionary warmup

    /// TIS enumeration happens on the main thread only; the tap thread reads
    /// the cached list. If the cache is momentarily empty (layout change mid-
    /// word), the decision is skipped rather than blocking on the main thread.
    private func layouts() -> [SystemLayoutEngine.Layout] {
        lock.lock()
        let cached = cachedLayouts
        lock.unlock()
        if let cached { return cached }

        if Thread.isMainThread {
            return refreshLayoutsOnMain()
        }
        DispatchQueue.main.async { [weak self] in _ = self?.refreshLayoutsOnMain() }
        return []
    }

    @discardableResult
    private func refreshLayoutsOnMain() -> [SystemLayoutEngine.Layout] {
        let list = engine.enabledKeyboardLayouts()
        lock.lock()
        cachedLayouts = list
        lock.unlock()
        return list
    }

    private func observeLayoutChanges() {
        let name = Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String)
        layoutObserver = DistributedNotificationCenter.default().addObserver(
            forName: name, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.cachedLayouts = nil
            self.lock.unlock()
            self.refreshLayoutsOnMain()
            self.warmDictionaries()
        }
    }

    private func observeFrontmostApp() {
        lock.lock()
        frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        lock.unlock()
        frontmostObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let bundle = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            self.lock.lock()
            self.frontmostBundleID = bundle
            self.lock.unlock()
        }
    }

    private func observeExceptions() {
        exceptionsCancellable = LayoutFixSettings.shared.$exceptions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] list in
                guard let self else { return }
                let snapshot = Set(list)
                self.lock.lock()
                self.exceptionsSnapshot = snapshot
                self.lock.unlock()
            }
    }

    private func isLearnedException(_ word: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return exceptionsSnapshot.contains(word.lowercased())
    }

    /// Moment of the last auto layout switch — used to suppress *early*
    /// (mid-word) fixes right after one. The switch lands asynchronously while
    /// the user keeps typing, so the next few keystrokes can render in the old
    /// layout; early-fixing that transient garbage causes switch ping-pong.
    private var lastSwitchAt: Date?

    private var inSwitchCooldown: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let at = lastSwitchAt else { return false }
        return Date().timeIntervalSince(at) < 1.0
    }

    /// `TISSelectInputSource` is a main-thread API — the tap thread hands the
    /// switch off instead of calling it in the keystroke path.
    private func selectLayoutOnMain(_ layout: SystemLayoutEngine.Layout) {
        lock.lock()
        lastSwitchAt = Date()
        lock.unlock()
        if Thread.isMainThread {
            engine.select(layout)
        } else {
            DispatchQueue.main.async { [engine] in engine.select(layout) }
        }
    }

    /// Two-letter language of a layout ("ru"/"en"/"es"/…).
    private func languageOf(_ layout: SystemLayoutEngine.Layout) -> String? {
        if let code = layout.languages.first?.prefix(2).lowercased() { return code }
        return nil
    }

    private func warmDictionaries() {
        let languages = Array(Set(layouts().compactMap { validator.bestLanguage(for: $0.languages) }))
        DispatchQueue.main.async { [validator] in validator.warm(languages: languages) }
    }

    // MARK: - Decision core

    private struct Decision {
        let layout: SystemLayoutEngine.Layout
        let rendered: String
        let sourceLayoutID: String
        let sourceImpossible: Int
    }

    /// Builds per-layout hypotheses for the typed window and asks the
    /// DecisionEngine which (if any) single reading should replace it.
    /// `useDictionary` adds NSSpellChecker as a supporting signal — boundary
    /// path only (it runs async on the main thread); the synchronous tap-thread
    /// paths (early + commit) stay pure-statistical, since a spell check is an
    /// XPC round-trip that would add latency to system-wide keystroke delivery.
    private func decide(_ word: String, keys: [KeystrokeMonitor.Key], useDictionary: Bool) -> Decision? {
        guard word.count >= config.minWordLength, word.count == keys.count else { return nil }

        let strokes = keys.map { (keyCode: $0.keyCode, modifierByte: $0.modifierByte) }
        let all = layouts()
        guard all.count >= 2 else { return nil }

        var source: DecisionEngine.Hypothesis?
        var sourceLayoutID = ""
        var alternatives: [DecisionEngine.Hypothesis] = []
        var renderings: [String: String] = [:]

        for layout in all {
            let rendered = engine.render(keyStrokes: strokes, using: layout)
            let isSource = (rendered == word)
            // The source is whichever layout reproduces the typed window — even
            // if it contains keys that are punctuation there (ж/э/х… sit on ;'[
            // in US-QWERTY), so "нежно"→"ye;yj" is still recognized as source.
            // Alternatives must be clean words (letters only).
            guard let core = DecisionEngine.coreExtract(rendered) ?? (isSource ? lettersOnly(rendered) : nil)
            else { continue }
            let lang = languageOf(layout)
            let scorer = lang.flatMap { scorers[$0] }
            let score = scorer?.charScore(core)
            var dictValid: Bool?
            if useDictionary, let dictLang = validator.bestLanguage(for: layout.languages) {
                dictValid = validator.isValidWord(core, language: dictLang)
            }
            let hypo = DecisionEngine.Hypothesis(
                id: layout.id, core: core,
                charAvgQ: score?.avgQ, impossible: score?.impossible ?? 0,
                freqQ: scorer?.freqQ(core), dictValid: dictValid
            )
            renderings[layout.id] = rendered
            if isSource {
                source = hypo
                sourceLayoutID = layout.id
            } else {
                alternatives.append(hypo)
            }
        }

        guard let source else { log("  no source layout reproduces the window"); return nil }

        guard let winnerID = DecisionEngine.verdict(source: source, alternatives: alternatives),
              let winner = all.first(where: { $0.id == winnerID }),
              let rendered = renderings[winnerID] else {
            log("  skip: verdict nil (src core='\(source.core)' q=\(source.charAvgQ.map { String(format: "%.0f", $0) } ?? "—") imp=\(source.impossible))")
            return nil
        }
        return Decision(layout: winner, rendered: rendered,
                        sourceLayoutID: sourceLayoutID, sourceImpossible: source.impossible)
    }

    /// Letters-only projection of a rendering, used to score the source window
    /// when it contains punctuation-position keys (ж/э/х/ъ/б/ю mid-word).
    private func lettersOnly(_ s: String) -> String? {
        let letters = String(s.filter { $0.isLetter })
        return letters.count >= 2 ? letters : nil
    }

    /// `verbose: false` for per-keystroke checks (capitalization) so the log
    /// isn't spammed on every letter.
    private func guardsPass(verbose: Bool = true) -> Bool {
        if IsSecureEventInputEnabled() {                  // thread-safe C API
            if verbose { log("  skip: SECURE INPUT active (some app is capturing passwords)") }
            return false
        }
        lock.lock()
        let bundle = frontmostBundleID
        lock.unlock()
        if let bundle, Self.blockedApps.contains(bundle) {
            if verbose { log("  skip: blocked app \(bundle)") }
            return false
        }
        return true
    }

    // MARK: - Paths

    /// Space boundary (async): fix word + boundary space.
    private func handleBoundary(_ word: String, keys: [KeystrokeMonitor.Key]) {
        log("word='\(word)' (\(word.count) keys)")
        guard guardsPass() else { log("  skip: guarded app/secure input"); return }
        guard let d = decide(word, keys: keys, useDictionary: true) else { return }

        log("  FIX '\(word)' → '\(d.rendered)' (\(d.layout.localizedName))")
        monitor.applyCorrection(deleteCount: word.count + 1, insert: d.rendered + " ")
        if config.switchSystemLayout { selectLayoutOnMain(d.layout) }
        setLastCorrection(LastCorrection(original: word, converted: d.rendered,
                                         boundary: " ", previousLayoutID: d.sourceLayoutID))
        monitor.armUndo()
    }

    /// Plain Enter (sync, in the tap): decide now so the fixed text is sent.
    /// Pure-statistical like the early path — NSSpellChecker is an XPC call
    /// to the spell server, and a synchronous XPC round-trip inside the tap
    /// callback would add latency to every Enter keystroke system-wide.
    private func decideForCommit(_ word: String, keys: [KeystrokeMonitor.Key]) -> KeystrokeMonitor.Correction? {
        guard guardsPass() else { return nil }
        guard let d = decide(word, keys: keys, useDictionary: false) else { return nil }
        log("COMMIT FIX '\(word)' → '\(d.rendered)' (\(d.layout.localizedName))")
        if config.switchSystemLayout { selectLayoutOnMain(d.layout) }
        // No undo: the Enter sends the text right after the correction.
        return .init(deleteCount: word.count, insert: d.rendered)
    }

    /// Mid-word (sync, pure statistics): only on strong evidence — the typed
    /// prefix must contain ≥2 impossible trigrams for its own layout.
    private func decideEarly(_ word: String, keys: [KeystrokeMonitor.Key]) -> KeystrokeMonitor.Correction? {
        guard guardsPass() else { return nil }
        // Right after an auto layout switch a few keystrokes may still render
        // in the old layout — early-fixing that transient garbage causes
        // switch ping-pong, so early mode sits out the cooldown.
        guard !inSwitchCooldown else { return nil }
        guard let d = decide(word, keys: keys, useDictionary: false),
              d.sourceImpossible >= 2 else { return nil }

        log("EARLY FIX '\(word)' → '\(d.rendered)' (\(d.layout.localizedName))")
        if config.switchSystemLayout { selectLayoutOnMain(d.layout) }
        let rebased = keys.map {
            engine.render(keyStrokes: [(keyCode: $0.keyCode, modifierByte: $0.modifierByte)], using: d.layout)
        }
        setLastCorrection(LastCorrection(original: word, converted: d.rendered,
                                         boundary: "", previousLayoutID: d.sourceLayoutID))
        monitor.armUndo()
        return .init(deleteCount: word.count, insert: d.rendered, rebasedChars: rebased)
    }

    private func setLastCorrection(_ correction: LastCorrection?) {
        lock.lock()
        lastCorrection = correction
        lock.unlock()
    }

    // MARK: - Undo (Backspace right after a correction)

    /// Runs on the main thread (hopped from the tap) — settings access is fine here.
    private func undoLast() {
        lock.lock()
        let last = lastCorrection
        lastCorrection = nil
        lock.unlock()
        guard let last else { return }

        monitor.applyCorrection(
            deleteCount: last.converted.count + last.boundary.count,
            insert: last.original + last.boundary
        )
        if config.switchSystemLayout,
           let previous = layouts().first(where: { $0.id == last.previousLayoutID }) {
            selectLayoutOnMain(previous)
        }
        // NB: exception learning is disabled for now — undo only reverts.
        log("UNDO → '\(last.original)'")
    }
}
