import SwiftUI
import AppKit

/// File-path chips under an agent reply (notes §7.2 п.6–7): the agent
/// creates files on ITS host and answers with paths. With a LOCAL gateway
/// (host = this Mac — the common setup) the file is right here, so the chip
/// opens it; with a remote gateway Hermes serves no file-download API, so
/// the chip copies the path and says where the file lives.
enum AgentFilePaths {
    // /root, /srv, /mnt: a remote gateway commonly runs as root on a
    // VPS — its files live under /root and never matched (e2e
    // 2026-07-27: "/root/toluca_map.html" rendered as plain prose).
    // Compiled ONCE — extract() runs in row bodies, and re-compiling the
    // regex per call was measurable during history backfill.
    private static let pathRegex = try? NSRegularExpression(
        pattern: #"(?:^|[\s`'"(\[])((?:~|/Users|/home|/root|/srv|/mnt|/tmp|/private|/var|/opt|/etc)/[A-Za-z0-9._\-/~]+)"#)

    /// Memoized extraction — the result depends only on the text, and the
    /// same reply is re-scanned on every row rebuild.
    private final class PathsBox {
        let paths: [String]
        init(_ paths: [String]) { self.paths = paths }
    }
    private static let extractCache: NSCache<NSString, PathsBox> = {
        let cache = NSCache<NSString, PathsBox>()
        cache.countLimit = 512
        return cache
    }()

    /// Absolute (or ~-based) paths mentioned in the reply. Conservative:
    /// only common root prefixes, punctuation/quotes trimmed, capped.
    static func extract(from text: String) -> [String] {
        let cacheKey = text as NSString
        if let cached = extractCache.object(forKey: cacheKey) { return cached.paths }
        guard let regex = pathRegex else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        var result: [String] = []
        for match in regex.matches(in: text, range: range) {
            guard let pathRange = Range(match.range(at: 1), in: text) else { continue }
            var path = String(text[pathRange])
            // Trailing sentence punctuation clings to paths in prose.
            while let last = path.last, ".,;:!?)".contains(last) { path.removeLast() }
            // Bare directories and one-segment matches are mostly noise.
            guard path.contains("/"), path.split(separator: "/").count > 1,
                  seen.insert(path).inserted else { continue }
            result.append(path)
            if result.count >= 5 { break }
        }
        extractCache.setObject(PathsBox(result), forKey: cacheKey)
        return result
    }

    /// Resolves a mentioned path against the LOCAL filesystem (the gateway
    /// host is this Mac): ~ expands to the real home. nil when the file
    /// does not exist locally (remote gateway, or the path is prose).
    /// Paths already reported missing (debug breadcrumb fires once each).
    private static var loggedMisses = Set<String>()

    static func localURL(for path: String) -> URL? {
        let expanded = path.hasPrefix("~")
            ? NSHomeDirectory() + path.dropFirst()
            : path
        if FileManager.default.fileExists(atPath: expanded) {
            return URL(fileURLWithPath: expanded)
        }
        // Breadcrumb for "the preview vanished" reports: the EXACT string
        // that failed, hex-dumped head, so invisible characters show.
        if loggedMisses.insert(path).inserted {
            let hexHead = expanded.utf8.prefix(80).map { String(format: "%02x", $0) }.joined()
            Diagnostics.log("agent", "file.miss path=\(expanded) hex=\(hexHead)")
        }
        return nil
    }

    /// Whether a mentioned path is a FILE worth listing in the chat-wide
    /// files popover (preview / download / open). Local directories and
    /// extension-less prose paths are chatter there — but the per-bubble
    /// chips keep them (a directory chip revealing in Finder is useful in
    /// context; e2e 2026-07-26).
    static func isListableFile(_ path: String) -> Bool {
        let expanded = path.hasPrefix("~") ? NSHomeDirectory() + path.dropFirst() : path
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory)
        if exists { return !isDirectory.boolValue }
        return !(path as NSString).pathExtension.isEmpty
    }
}

/// ONE visual language for file pills in both directions — files the user
/// sends to the agent and files coming back from it: capsule, small icon
/// slot (or a spinner while the courier works), mono filename. Direction
/// and state speak through the icon only, so the transcript reads as one
/// family of chips.
struct AgentFilePill: View {
    @Environment(\.themePalette) private var palette

    let filename: String
    let systemImage: String
    var isBusy: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            if isBusy {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 12, height: 12)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 10))
            }
            Text(filename)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
        }
        .foregroundColor(palette.ink)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.14), in: Capsule())
    }
}

/// The chip row itself. Renders nothing when the reply mentions no paths.
/// HTML/Markdown files the agent produced open as full ARTIFACT cards with
/// the in-app preview (same card as fenced deliverables — e2e feedback
/// 2026-07-25: "просматривать не переходя в папки"); everything else stays
/// a chip that reveals in Finder / copies the remote path.
struct AgentFileChipsView: View {
    @Environment(\.themePalette) private var palette

    let messageText: String
    /// Timestamp of the message mentioning these paths — the freshness the
    /// auto-fetch must satisfy: a newer mention of a path refreshes its
    /// cached copy (the agent edited the file and said so).
    var messageDate: Date = .distantPast
    @State private var copiedPath: String?
    @State private var fetchingPath: String?
    @State private var failedPath: String?
    /// Bumped when a silent auto-fetch lands — re-renders the row so the
    /// download chip graduates into the artifact preview card.
    @State private var autoFetchTick = 0

    /// Extensions that render as artifact preview cards.
    private static let artifactExtensions: [String: ArtifactKind] = [
        "html": .html, "htm": .html, "md": .markdown, "markdown": .markdown
    ]

    var body: some View {
        // Directories earn a chip only when they exist HERE (local gateway:
        // click opens Finder). On a remote gateway a directory chip is pure
        // noise — nothing to fetch, nothing to open (e2e 2026-07-27).
        let paths = AgentFilePaths.extract(from: messageText).filter { path in
            AgentFilePaths.localURL(for: path) != nil || AgentFilePaths.isListableFile(path)
        }
        if !paths.isEmpty {
            // A copy the reverse courier already pulled down counts as
            // local: HTML/Markdown graduate from a download chip to the
            // full artifact preview card, same as on a local gateway.
            let split = paths.map { path -> (path: String, artifact: (URL, ArtifactKind)?) in
                let ext = (path as NSString).pathExtension.lowercased()
                if let kind = Self.artifactExtensions[ext],
                   let url = AgentFilePaths.localURL(for: path)
                       ?? HermesFileCourier.fetchedCopy(forRemotePath: path) {
                    return (path, (url, kind))
                }
                return (path, nil)
            }
            let _ = autoFetchTick
            VStack(alignment: .leading, spacing: 6) {
                ForEach(split.filter { $0.artifact != nil }, id: \.path) { item in
                    HStack(spacing: 6) {
                        AgentFileArtifactCard(url: item.artifact!.0, kind: item.artifact!.1,
                                              reload: autoFetchTick)
                        // Its own reveal-in-Finder affordance: the card's
                        // click is the PREVIEW; the file on disk is a
                        // separate destination (e2e feedback 2026-07-25).
                        Button {
                            AgentFetchedFileOpener.reveal(item.artifact!.0)
                        } label: {
                            Image(systemName: "folder")
                                .font(.system(size: 13))
                                .foregroundColor(palette.secondaryText)
                                .frame(width: 26, height: 26)
                                .background(Color.secondary.opacity(0.10), in: Circle())
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help(String(format: AGL("agent.file.reveal"), item.path))
                    }
                }
                let plain = split.filter { $0.artifact == nil }
                if !plain.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(plain, id: \.path) { item in
                            chip(for: item.path)
                        }
                    }
                }
            }
            // Remote HTML/Markdown fetch themselves (into the app cache, so
            // ~/Downloads stays clean): the preview card appears on its own
            // instead of waiting for a click (e2e 2026-07-27). Keyed on the
            // tick too: rows render BEFORE the background keychain warm-up
            // delivers the dashboard token — the apiKeysDidChange bump below
            // re-runs the fetch that silently skipped (e2e 2026-07-27: no
            // card, and the first chip click fell back to copy-the-path).
            .task(id: "\(messageText)#\(autoFetchTick)") {
                var landed = false
                for path in paths {
                    let ext = (path as NSString).pathExtension.lowercased()
                    guard Self.artifactExtensions[ext] != nil,
                          AgentFilePaths.localURL(for: path) == nil,
                          !HermesFileCourier.hasFreshCopy(forRemotePath: path, asOf: messageDate),
                          await HermesFileCourier.autoFetchArtifact(path: path, asOf: messageDate) != nil
                    else { continue }
                    landed = true
                }
                if landed { autoFetchTick += 1 }
            }
            .onReceive(NotificationCenter.default.publisher(for: .apiKeysDidChange)) { _ in
                autoFetchTick += 1
            }
        }
    }

    @ViewBuilder
    private func chip(for path: String) -> some View {
        // A file is "here" when the gateway host is this Mac OR the reverse
        // courier already pulled a copy — both open locally.
        let local = AgentFilePaths.localURL(for: path)
            ?? HermesFileCourier.fetchedCopy(forRemotePath: path)
        // Reverse courier: a remote gateway with the dashboard configured
        // can pull the file down — the chip becomes a download, not a
        // copy-the-path consolation prize (e2e 2026-07-27: "как получить
        // файл то?" — the agent offered ITS OWN localhost).
        // Directories stay download-free on a remote gateway: there is
        // nothing to fetch through the files API — the chip only offers
        // the path (on a LOCAL gateway the same chip opens the folder in
        // Finder, which is the affordance worth keeping).
        let canFetch = AgentFilePaths.localURL(for: path) == nil && HermesFileCourier.canFetchRemote
            && AgentFilePaths.isListableFile(path)
        Button {
            if let trulyLocal = AgentFilePaths.localURL(for: path) {
                // Show, don't blindly launch: preview for HTML/Markdown,
                // reveal in Finder otherwise (the user decides what to do).
                AgentFetchedFileOpener.open(trulyLocal)
            } else if canFetch {
                // Fresh-first even when a cached copy exists: the agent may
                // have edited the file since (e2e 2026-07-27); the stale
                // copy is only the offline fallback.
                fetchRemote(path)
            } else if let cached = HermesFileCourier.fetchedCopy(forRemotePath: path) {
                AgentFetchedFileOpener.open(cached)
            } else {
                copyPath(path)
            }
        } label: {
            AgentFilePill(
                filename: (path as NSString).lastPathComponent,
                systemImage: chipIcon(path: path, local: local != nil, canFetch: canFetch),
                isBusy: fetchingPath == path
            )
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(fetchingPath == path)
        .help(chipHelp(path: path, local: local != nil, canFetch: canFetch))
    }

    private func chipIcon(path: String, local: Bool, canFetch: Bool) -> String {
        if local { return "doc.fill" }
        if copiedPath == path { return "checkmark.circle" }
        if failedPath == path { return "exclamationmark.circle" }
        return canFetch ? "arrow.down.circle" : "doc.on.doc"
    }

    private func chipHelp(path: String, local: Bool, canFetch: Bool) -> String {
        if local { return String(format: AGL("agent.file.reveal"), path) }
        if failedPath == path { return AGL("agent.file.fetchFailed") }
        return String(format: AGL(canFetch ? "agent.file.fetch" : "agent.file.remote"), path)
    }

    private func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        copiedPath = path
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copiedPath = nil }
    }

    /// Downloads through the dashboard files API into the app cache, then
    /// opens like a local file: HTML/Markdown in the in-app preview,
    /// everything else exported to ~/Downloads and revealed. Failure falls
    /// back to the cached copy if one exists, else copies the path.
    private func fetchRemote(_ path: String) {
        guard fetchingPath == nil else { return }
        fetchingPath = path
        failedPath = nil
        Task { @MainActor in
            let fetched = await HermesFileCourier.fetchRemoteFile(path: path, to: .cache)
            fetchingPath = nil
            if let fetched {
                autoFetchTick += 1
                AgentFetchedFileOpener.open(fetched)
            } else if let cached = HermesFileCourier.fetchedCopy(forRemotePath: path) {
                // Offline / transient failure: the stale copy beats nothing.
                AgentFetchedFileOpener.open(cached)
            } else {
                failedPath = path
                copyPath(path)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if failedPath == path { failedPath = nil }
                }
            }
        }
    }
}

/// Opens a file the reverse courier just dropped into ~/Downloads: HTML and
/// Markdown go to the in-app artifact preview (the chat's convention for
/// agent deliverables), everything else is revealed in Finder — same
/// "show, don't blindly launch" rule as local chips.
enum AgentFetchedFileOpener {
    private static let previewKinds: [String: ArtifactKind] = [
        "html": .html, "htm": .html, "md": .markdown, "markdown": .markdown
    ]

    static func open(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        if let kind = previewKinds[ext],
           let data = try? Data(contentsOf: url), data.count <= 4 * 1024 * 1024,
           let content = String(data: data, encoding: .utf8) {
            ArtifactPreview.show(kind: kind, content: content, title: url.lastPathComponent)
            return
        }
        reveal(url)
    }

    /// Reveal in Finder — with one twist: an auto-fetched CACHE copy is
    /// first exported to ~/Downloads (revealing the app's private cache
    /// would be noise; asking for the file in Finder is the "give it to
    /// me" moment the silent fetch deliberately skipped).
    static func reveal(_ url: URL) {
        let target = HermesFileCourier.isCacheCopy(url)
            ? (HermesFileCourier.exportToDownloads(url) ?? url)
            : url
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }
}

/// In-TEXT file mentions: a path the agent wrote in prose becomes a
/// clickable link (custom scheme, same idea as CopyLink) that runs the
/// chip's action — open the local/fetched copy, or pull it through the
/// reverse courier first. Enabled per-bubble via the environment flag so
/// ordinary chats never rewrite their text.
enum AgentFileLink {
    static let scheme = "cuate-agentfile"

    static func encode(_ path: String) -> URL? {
        let base64 = Data(path.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return URL(string: "\(scheme):\(base64)")
    }

    static func decode(_ url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        var base64 = url.absoluteString
            .replacingOccurrences(of: "\(scheme):", with: "")
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The click action — mirrors the chip, fresh-first: a truly local file
    /// opens as is; a remote one is re-fetched even when a cached copy
    /// exists (the agent may have edited it — e2e 2026-07-27), the stale
    /// copy serving only as the offline fallback; no courier → copy path.
    @MainActor
    static func open(_ path: String) {
        if let local = AgentFilePaths.localURL(for: path) {
            AgentFetchedFileOpener.open(local)
        } else if HermesFileCourier.canFetchRemote, AgentFilePaths.isListableFile(path) {
            Task { @MainActor in
                if let fetched = await HermesFileCourier.fetchRemoteFile(path: path, to: .cache) {
                    AgentFetchedFileOpener.open(fetched)
                } else if let cached = HermesFileCourier.fetchedCopy(forRemotePath: path) {
                    AgentFetchedFileOpener.open(cached)
                }
            }
        } else if let cached = HermesFileCourier.fetchedCopy(forRemotePath: path) {
            AgentFetchedFileOpener.open(cached)
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        }
    }
}

/// Per-bubble switch for AgentFileLink rewriting (agent replies only).
private struct AgentFileLinksEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var agentFileLinksEnabled: Bool {
        get { self[AgentFileLinksEnabledKey.self] }
        set { self[AgentFileLinksEnabledKey.self] = newValue }
    }
}

// AgentAttachNote — the note contract shared with Android — lives in its
// own dependency-free file (AgentAttachNote.swift): the cross-platform
// contract tests compile it standalone.

/// Pills for the files of an outgoing message (user bubble): filename chip,
/// click reveals a local file in Finder, full path in the tooltip.
struct AgentAttachPillsView: View {
    @Environment(\.themePalette) private var palette

    let paths: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(paths, id: \.self) { path in
                Button {
                    if let local = AgentFilePaths.localURL(for: path) {
                        NSWorkspace.shared.activateFileViewerSelecting([local])
                    }
                } label: {
                    AgentFilePill(filename: (path as NSString).lastPathComponent,
                                  systemImage: "doc.fill")
                }
                .buttonStyle(PlainButtonStyle())
                .help(path)
            }
        }
    }
}

/// Popover with EVERY file the agent handed over in this conversation
/// (header folder button, e2e feedback 2026-07-25): open with the default
/// app, reveal in Finder, or copy the path when the file lives on a remote
/// gateway host.
struct AgentChatFilesView: View {
    @Environment(\.themePalette) private var palette

    /// Deduped paths, newest first: files the AGENT produced, and files the
    /// USER attached (a separate group; e2e request 2026-07-26).
    let paths: [String]
    var userPaths: [String] = []
    @State private var copiedPath: String?
    @State private var fetchingPath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AGL("agent.files.title"))
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .foregroundColor(.secondary)
            if paths.isEmpty, userPaths.isEmpty {
                Text(AGL("agent.files.empty"))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(paths, id: \.self) { path in
                            row(for: path)
                        }
                        if !userPaths.isEmpty {
                            Text(AGL("agent.files.fromUser"))
                                .font(.system(size: 10, weight: .semibold))
                                .textCase(.uppercase)
                                .foregroundColor(.secondary)
                                .padding(.top, 6)
                            ForEach(userPaths, id: \.self) { path in
                                row(for: path)
                            }
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .padding(12)
        .frame(width: 340)
    }

    /// Preview kinds the in-app artifact window renders.
    private static let previewKinds: [String: ArtifactKind] = [
        "html": .html, "htm": .html, "md": .markdown, "markdown": .markdown
    ]

    /// Opens a local file the way the chat does: HTML/Markdown in the
    /// in-app preview window (placed on the panel's screen), everything
    /// else with the default app.
    private func openFile(_ url: URL, path: String) {
        let ext = (path as NSString).pathExtension.lowercased()
        if let kind = Self.previewKinds[ext],
           let data = try? Data(contentsOf: url), data.count <= 4 * 1024 * 1024,
           let content = String(data: data, encoding: .utf8) {
            ArtifactPreview.show(kind: kind, content: content,
                                 title: (path as NSString).lastPathComponent)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    @ViewBuilder
    private func row(for path: String) -> some View {
        // A reverse-courier copy makes the row behave like a local file:
        // open/reveal the copy instead of offering the download again.
        let local = AgentFilePaths.localURL(for: path)
            ?? HermesFileCourier.fetchedCopy(forRemotePath: path)
        HStack(spacing: 8) {
            // The row itself opens the preview — the buttons are shortcuts.
            Button {
                if let local { openFile(local, path: path) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: iconName(for: path))
                        .font(.system(size: 13))
                        .foregroundColor(palette.ink)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text((path as NSString).lastPathComponent)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Text(path)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            Spacer(minLength: 8)
            if let local {
                Button {
                    openFile(local, path: path)
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .help(AGL("agent.files.open"))
                Button {
                    AgentFetchedFileOpener.reveal(local)
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .help(String(format: AGL("agent.file.reveal"), path))
            } else {
                if HermesFileCourier.canFetchRemote {
                    // Reverse courier: pull the file down from the agent's
                    // host and open it like a local one.
                    Button {
                        guard fetchingPath == nil else { return }
                        fetchingPath = path
                        Task { @MainActor in
                            let fetched = await HermesFileCourier.fetchRemoteFile(path: path)
                            fetchingPath = nil
                            if let fetched { AgentFetchedFileOpener.open(fetched) }
                        }
                    } label: {
                        if fetchingPath == path {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(fetchingPath != nil)
                    .help(String(format: AGL("agent.file.fetch"), path))
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                    copiedPath = path
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copiedPath = nil }
                } label: {
                    Image(systemName: copiedPath == path ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .help(String(format: AGL("agent.file.remote"), path))
            }
        }
        .padding(.vertical, 3)
    }

    private func iconName(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": return "globe"
        case "md", "markdown": return "doc.text"
        case "png", "jpg", "jpeg", "gif", "webp", "heic": return "photo"
        case "pdf": return "doc.richtext"
        case "csv", "tsv", "xlsx": return "tablecells"
        default: return "doc"
        }
    }
}

/// Artifact preview card for a FILE on the local gateway host: reads the
/// content off the main thread and hands it to the same `ArtifactCardView`
/// fenced deliverables use — full in-app preview, save, open.
private struct AgentFileArtifactCard: View {
    let url: URL
    let kind: ArtifactKind
    /// Bumped by the chips row when the reverse courier refreshed the copy
    /// in place (same URL, new bytes) — re-reads the content.
    var reload: Int = 0

    private static let maxBytes = 4 * 1024 * 1024

    @State private var content: String?

    var body: some View {
        Group {
            if let content {
                ArtifactCardView(kind: kind, content: content, complete: true, truncated: false)
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.secondary.opacity(0.08))
                    .frame(width: 260, height: 56)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .task(id: "\(url.path)#\(reload)") {
            let fileURL = url
            let loaded = await Task.detached(priority: .userInitiated) { () -> String? in
                guard let data = try? Data(contentsOf: fileURL), data.count <= Self.maxBytes else { return nil }
                return String(data: data, encoding: .utf8)
            }.value
            content = loaded ?? ""
        }
    }
}
