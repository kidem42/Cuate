import SwiftUI
import AppKit
import AVFoundation
import Combine
import MediaPlayer

extension Notification.Name {
    /// Posted when the Plaud preview window closes — the hosted view stays
    /// alive inside the retained window, so onDisappear alone never fires
    /// and the audio would keep playing into the void.
    static let plaudNotePreviewDidClose = Notification.Name("plaudNotePreviewDidClose")
}

/// Floating preview window for ONE Plaud recording: every summary tab the
/// recording has, the full transcript with clickable timecodes, and inline
/// audio streaming (the presigned S3 link supports range requests, so
/// seeking is free). Opens instantly from the disk cache and refreshes live
/// in the background.
///
/// Window mechanics mirror `ArtifactPreview`: floating level + joins all
/// spaces, so it appears on whatever screen/space the chat panel is on.
@MainActor
enum PlaudNotePreview {
    private static var window: NSWindow?
    private static var closeObserver: NSObjectProtocol?
    /// Width = the 720pt reading column + its 32pt side paddings — the
    /// window hugs the content instead of opening with dead margins.
    private static let previewSize = NSSize(width: 784, height: 640)

    static func show(fileID: String, fallbackTitle: String) {
        let hosting = NSHostingController(
            rootView: PlaudNotePreviewView(fileID: fileID, fallbackTitle: fallbackTitle)
                .id(fileID) // fresh state when switching recordings
        )
        if let window {
            window.contentViewController = hosting
            window.title = fallbackTitle
            window.setContentSize(previewSize) // reopen at content width
            place(window)
            window.makeKeyAndOrderFront(nil)
        } else {
            let newWindow = NSWindow(contentViewController: hosting)
            newWindow.title = fallbackTitle
            newWindow.styleMask = [.titled, .closable, .resizable]
            newWindow.setContentSize(previewSize)
            newWindow.isReleasedWhenClosed = false
            newWindow.level = .floating
            newWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            place(newWindow)
            window = newWindow
            // Closing the window must stop playback: the retained window
            // keeps the view alive, so the view listens for this instead
            // of onDisappear.
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: newWindow, queue: .main
            ) { _ in
                NotificationCenter.default.post(name: .plaudNotePreviewDidClose, object: nil)
            }
            newWindow.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Centers on the screen the user is currently on (mouse screen), like
    /// the chat panel summon.
    private static func place(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let bounds = screen?.visibleFrame else { return }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2
        ))
    }
}

// MARK: - Audio player model

/// Streams the recording's mp3 straight from the presigned S3 URL (range
/// requests → instant seeking; the traffic is on Plaud's storage bill, not
/// the user's tokens). The URL expires in 24h so it is fetched fresh per
/// preview session, never persisted.
@MainActor
private final class PlaudAudioPlayer: ObservableObject {
    @Published var isPlaying = false
    @Published var currentSeconds: Double = 0
    @Published var durationSeconds: Double = 0
    @Published var loading = false
    @Published var available = true
    /// Shown next to the transport when a tap could not produce audio for a
    /// reason worth naming (Plaud has not signed the mp3 yet).
    @Published var notice: String?

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private let fileID: String

    /// Recording name for the system Now Playing widget (menu bar / Control
    /// Center) — set by the view once meta is known.
    var nowPlayingTitle: String = "Plaud"

    init(fileID: String) {
        self.fileID = fileID
    }

    /// Lazily builds the AVPlayer on first use (fresh presigned URL).
    private func ensurePlayer() async -> AVPlayer? {
        if let player { return player }
        loading = true
        defer { loading = false }
        guard let file = try? await PlaudClient.shared.getFile(fileID) else {
            // A failed request says nothing about the audio — leave the
            // control alone so the next tap can try again.
            return nil
        }
        guard let presigned = file["presigned_url"] as? String,
              let url = URL(string: presigned) else {
            // Plaud signs the mp3 lazily: on an otherwise-synced recording a
            // missing URL is their transient signing hiccup (their own client
            // says "retry in a few minutes"), NOT "this recording is silent".
            // Hiding the player forever was wrong — keep it, note why, and
            // let the next tap re-ask.
            let synced = (file["duration"] as? Double ?? 0) > 0
                || !(file["source_list"] as? [[String: Any]] ?? []).isEmpty
            available = synced
            notice = synced ? PLL("plaud.preview.audioPending") : nil
            return nil
        }
        notice = nil
        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        timeObserver = newPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 10), queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentSeconds = time.seconds
                if let duration = self.player?.currentItem?.duration.seconds,
                   duration.isFinite, duration > 0 {
                    self.durationSeconds = duration
                }
                self.pushNowPlaying()
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isPlaying = false
                self?.pushNowPlaying()
            }
        }
        player = newPlayer
        setupRemoteCommands()
        return newPlayer
    }

    // MARK: - System Now Playing (menu bar / Control Center)

    /// Registers with the system media widget so the recording shows up next
    /// to Music/Chrome and reacts to the media keys.
    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isPlaying else { return }
                self.toggle()
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying else { return }
                self.toggle()
            }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.toggle() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor [weak self] in self?.scrub(to: event.positionTime) }
            return .success
        }
    }

    private func pushNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: nowPlayingTitle,
            MPMediaItemPropertyArtist: "Plaud",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentSeconds,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if durationSeconds > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = durationSeconds
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    private func clearNowPlaying() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    func toggle() {
        Task { @MainActor in
            guard let player = await ensurePlayer() else { return }
            if isPlaying {
                player.pause()
                isPlaying = false
            } else {
                player.play()
                isPlaying = true
            }
            pushNowPlaying()
        }
    }

    /// Jump to a transcript timecode and play from there.
    func seek(toMs ms: Double) {
        Task { @MainActor in
            guard let player = await ensurePlayer() else { return }
            await player.seek(
                to: CMTime(seconds: ms / 1000, preferredTimescale: 600),
                toleranceBefore: .zero, toleranceAfter: .zero
            )
            player.play()
            isPlaying = true
            pushNowPlaying()
        }
    }

    /// Slider scrub (seconds).
    func scrub(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        currentSeconds = seconds
    }

    func stop() {
        player?.pause()
        isPlaying = false
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        player = nil
        clearNowPlaying()
    }
}

// MARK: - Preview view

private struct PlaudNotePreviewView: View {
    let fileID: String
    let fallbackTitle: String

    struct Tab: Identifiable, Equatable {
        let slug: String
        let title: String
        var id: String { slug }
    }

    struct Segment: Identifiable {
        let id = UUID()
        let startMs: Double
        /// nil in the outline — it has topics, not speakers.
        let speaker: String?
        let text: String
    }

    @State private var meta: PlaudNoteCache.Meta?
    @State private var tabs: [Tab] = []
    @State private var selected: String = ""
    @State private var contents: [String: String] = [:]
    /// Utterance rows per tab — the transcript blocks render as clickable
    /// timecodes, everything else as Markdown.
    @State private var segmentsByTab: [String: [Segment]] = [:]
    @State private var refreshing = false
    @StateObject private var audio: PlaudAudioPlayer

    init(fileID: String, fallbackTitle: String) {
        self.fileID = fileID
        self.fallbackTitle = fallbackTitle
        _audio = StateObject(wrappedValue: PlaudAudioPlayer(fileID: fileID))
    }

    /// The verbatim transcript's slug — one definition, so the legacy-cache
    /// fold-in below can never drift from the block enum.
    private static let transcriptSlug = PlaudSourceBlock.transaction.slug

    var body: some View {
        VStack(spacing: 0) {
            header
            playerBar
            Divider()
            if tabs.count > 1 {
                Picker("", selection: $selected) {
                    ForEach(tabs) { tab in
                        Text(tab.title).tag(tab.slug)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
            }
            content
        }
        .frame(minWidth: 480, minHeight: 360)
        .task(id: fileID) {
            loadFromDisk()
            await refresh()
        }
        // The preview window is reused between recordings (onDisappear
        // covers the content swap) and survives closing (the retained
        // window keeps the view alive — the notification covers that).
        .onDisappear { audio.stop() }
        .onReceive(NotificationCenter.default.publisher(for: .plaudNotePreviewDidClose)) { _ in
            audio.stop()
        }
        .onChange(of: meta?.name) { _, name in
            if let name, !name.isEmpty { audio.nowPlayingTitle = name }
        }
    }

    private var windowTitle: String {
        meta?.name.isEmpty == false ? meta!.name : fallbackTitle
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            PlaudBadge(size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(windowTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let meta, !meta.day.isEmpty {
                    Text("\(meta.day) · \(meta.duration)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            if refreshing {
                ProgressView().controlSize(.small)
            }
            Button(action: { PlaudAddon.openRecording(fileID) }) {
                Image(systemName: "arrow.up.forward.app")
            }
            .help(PLL("plaud.chip.openInPlaud"))
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Player bar

    @ViewBuilder
    private var playerBar: some View {
        if audio.available {
            HStack(spacing: 10) {
                Button(action: audio.toggle) {
                    if audio.loading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: audio.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 20))
                    }
                }
                .disabled(audio.loading)
                .help(PLL("plaud.preview.audio"))
                Text(PlaudFormat.clockString(ms: audio.currentSeconds * 1000))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                Slider(
                    value: Binding(
                        get: { audio.currentSeconds },
                        set: { audio.scrub(to: $0) }
                    ),
                    in: 0...max(audio.durationSeconds, 1)
                )
                .controlSize(.small)
                .disabled(audio.durationSeconds <= 0)
                Text(audio.durationSeconds > 0
                    ? PlaudFormat.clockString(ms: audio.durationSeconds * 1000)
                    : (meta?.duration ?? ""))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                if let notice = audio.notice {
                    Text(notice)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let rows = segmentsByTab[selected], !rows.isEmpty {
            transcriptList(rows)
        } else if let text = contents[selected], !text.isEmpty {
            ScrollView {
                MarkdownBlocksView(text: text, linkColor: .accentColor, style: .document)
                    .textSelection(.enabled)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 28)
                    .frame(maxWidth: 720, alignment: .topLeading)
                    .frame(maxWidth: .infinity)
            }
        } else {
            VStack(spacing: 10) {
                if refreshing {
                    ProgressView()
                    Text(PLL("plaud.preview.loading"))
                        .font(.callout)
                        .foregroundColor(.secondary)
                } else {
                    Text(PLL("plaud.preview.empty"))
                        .font(.callout)
                        .foregroundColor(.secondary)
                    Button(PLL("plaud.chip.openInPlaud")) {
                        PlaudAddon.openRecording(fileID)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Transcript as rows with CLICKABLE timecodes — a click streams the
    /// audio from that exact moment.
    private func transcriptList(_ rows: [Segment]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(rows) { segment in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Button(PlaudFormat.clockString(ms: segment.startMs)) {
                            audio.seek(toMs: segment.startMs)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.accentColor)
                        .help(PLL("plaud.preview.seekHelp"))
                        VStack(alignment: .leading, spacing: 1) {
                            // No speaker caption for the outline — there is
                            // nobody speaking, only the topic of that stretch.
                            if let speaker = segment.speaker {
                                Text(speaker)
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(.secondary)
                            }
                            Text(segment.text)
                                .font(.body)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: 720, alignment: .topLeading)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Data

    private func loadFromDisk() {
        meta = PlaudNoteCache.meta(fileID: fileID)
        if let name = meta?.name, !name.isEmpty { audio.nowPlayingTitle = name }
        var list: [Tab] = (meta?.tabs ?? []).map { Tab(slug: $0.slug, title: $0.title) }

        // Caches written before the transcript became an ordinary tab keep it
        // outside `tabs` — fold it in so old chips do not lose their text.
        var segmentSlugs = Set(meta?.segmentTabs ?? [])
        if meta?.hasTranscript == true {
            segmentSlugs.insert(Self.transcriptSlug)
            if !list.contains(where: { $0.slug == Self.transcriptSlug }) {
                list.append(Tab(slug: Self.transcriptSlug, title: PLL("plaud.preview.transcriptTab")))
            }
        }

        var loadedContents: [String: String] = [:]
        var loadedSegments: [String: [Segment]] = [:]
        for tab in list {
            loadedContents[tab.slug] = PlaudNoteCache.tabContent(fileID: fileID, slug: tab.slug)
            if segmentSlugs.contains(tab.slug),
               let raw = PlaudNoteCache.segmentsRaw(fileID: fileID, slug: tab.slug) {
                loadedSegments[tab.slug] = Self.parseSegments(raw)
            }
        }
        contents = loadedContents
        segmentsByTab = loadedSegments

        // Transcript blocks lead in a FIXED order (clean, verbatim, outline)
        // so muscle memory works across recordings; Plaud's own note tabs
        // follow in their original order.
        let blockSlugs = PlaudSourceBlock.displayOrder.map(\.slug)
        let leading = blockSlugs.compactMap { slug in list.first { $0.slug == slug } }
        tabs = leading + list.filter { !blockSlugs.contains($0.slug) }

        if selected.isEmpty || !tabs.contains(where: { $0.slug == selected }) {
            // Default to the first NOTE tab (summary reads first); the
            // transcripts stay one click away on the left.
            selected = tabs.first(where: { PlaudSourceBlock.from(slug: $0.slug) == nil })?.slug
                ?? tabs.first?.slug ?? ""
        }
    }

    private static func parseSegments(_ raw: String?) -> [Segment] {
        guard let raw, let parsed = PlaudFormat.transcriptSegments(fromRaw: raw) else { return [] }
        return PlaudFormat.rows(from: parsed).map {
            Segment(startMs: $0.startMs, speaker: $0.speaker, text: $0.text)
        }
    }

    /// Live refresh: re-reads the whole recording from Plaud — every note
    /// tab AND the transcript — so the preview always offers the full set,
    /// not just what the model read into the chat.
    private func refresh() async {
        refreshing = true
        defer { refreshing = false }
        guard let file = try? await PlaudClient.shared.getFile(fileID) else { return }
        PlaudNoteCache.updateMeta(
            fileID: fileID,
            name: file["name"] as? String ?? fallbackTitle,
            day: String((file["created_at"] as? String ?? "").prefix(10)),
            duration: PlaudFormat.durationString(file["duration"])
        )
        for item in file["note_list"] as? [[String: Any]] ?? [] {
            let tabName = item["data_tab_name"] as? String
                ?? item["data_title"] as? String
                ?? item["data_type"] as? String
                ?? "Note"
            if let content = await PlaudClient.resolveContent(of: item), !content.isEmpty {
                PlaudNoteCache.writeTab(
                    fileID: fileID,
                    tabName: tabName,
                    content: PlaudFormat.noteMarkdown(fromRaw: content)
                )
            }
        }
        // Every version Plaud made for this recording, not just the verbatim
        // one: the cleaned-up transcript and the outline become their own
        // tabs when they exist, and quietly stay absent when they don't.
        let sourceList = file["source_list"] as? [[String: Any]] ?? []
        for block in PlaudSourceBlock.allCases {
            guard let item = sourceList.first(where: { ($0["data_type"] as? String) == block.rawValue }),
                  let raw = await PlaudClient.resolveContent(of: item), !raw.isEmpty else { continue }
            if let parsed = PlaudFormat.transcriptSegments(fromRaw: raw) {
                PlaudNoteCache.writeSegmentTab(
                    fileID: fileID,
                    slug: block.slug,
                    title: block.title,
                    markdown: PlaudFormat.transcriptMarkdown(from: parsed),
                    rawSegments: raw
                )
            } else {
                // Prose rather than utterances (the outline usually) — still
                // a perfectly good tab.
                PlaudNoteCache.writeTab(
                    fileID: fileID, tabName: block.title, content: raw, slug: block.slug
                )
            }
        }
        loadFromDisk()
    }
}
