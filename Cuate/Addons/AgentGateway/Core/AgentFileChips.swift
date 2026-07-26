import SwiftUI
import AppKit

/// File-path chips under an agent reply (notes §7.2 п.6–7): the agent
/// creates files on ITS host and answers with paths. With a LOCAL gateway
/// (host = this Mac — the common setup) the file is right here, so the chip
/// opens it; with a remote gateway Hermes serves no file-download API, so
/// the chip copies the path and says where the file lives.
enum AgentFilePaths {
    /// Absolute (or ~-based) paths mentioned in the reply. Conservative:
    /// only common root prefixes, punctuation/quotes trimmed, capped.
    static func extract(from text: String) -> [String] {
        let pattern = #"(?:^|[\s`'"(\[])((?:~|/Users|/home|/tmp|/private|/var|/opt|/etc)/[A-Za-z0-9._\-/~]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
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

/// The chip row itself. Renders nothing when the reply mentions no paths.
/// HTML/Markdown files the agent produced open as full ARTIFACT cards with
/// the in-app preview (same card as fenced deliverables — e2e feedback
/// 2026-07-25: "просматривать не переходя в папки"); everything else stays
/// a chip that reveals in Finder / copies the remote path.
struct AgentFileChipsView: View {
    @Environment(\.themePalette) private var palette

    let messageText: String
    @State private var copiedPath: String?

    /// Extensions that render as artifact preview cards.
    private static let artifactExtensions: [String: ArtifactKind] = [
        "html": .html, "htm": .html, "md": .markdown, "markdown": .markdown
    ]

    var body: some View {
        let paths = AgentFilePaths.extract(from: messageText)
        if !paths.isEmpty {
            let split = paths.map { path -> (path: String, artifact: (URL, ArtifactKind)?) in
                let ext = (path as NSString).pathExtension.lowercased()
                if let kind = Self.artifactExtensions[ext],
                   let url = AgentFilePaths.localURL(for: path) {
                    return (path, (url, kind))
                }
                return (path, nil)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(split.filter { $0.artifact != nil }, id: \.path) { item in
                    HStack(spacing: 6) {
                        AgentFileArtifactCard(url: item.artifact!.0, kind: item.artifact!.1)
                        // Its own reveal-in-Finder affordance: the card's
                        // click is the PREVIEW; the file on disk is a
                        // separate destination (e2e feedback 2026-07-25).
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([item.artifact!.0])
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
        }
    }

    @ViewBuilder
    private func chip(for path: String) -> some View {
        let local = AgentFilePaths.localURL(for: path)
        Button {
            if let local {
                // Reveal in Finder: opening an unknown type blindly is
                // riskier than showing it (the user decides what to do).
                NSWorkspace.shared.activateFileViewerSelecting([local])
            } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
                copiedPath = path
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copiedPath = nil }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: local != nil
                      ? "doc.circle"
                      : (copiedPath == path ? "checkmark.circle" : "doc.on.doc"))
                    .font(.system(size: 13))
                Text((path as NSString).lastPathComponent)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
            }
            .foregroundColor(palette.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.secondary.opacity(0.10), in: Capsule())
        }
        .buttonStyle(PlainButtonStyle())
        .help(local != nil
              ? String(format: AGL("agent.file.reveal"), path)
              : String(format: AGL("agent.file.remote"), path))
    }
}

/// The attached-files note woven into an outgoing agent message is a
/// CONTRACT the agent reads ("Attached files…:\n- path"); on screen it
/// renders as pills instead of raw paths. This splits a message into the
/// display text and the note's paths (all UI languages recognized).
enum AgentAttachNote {
    /// Every localized header the courier can produce.
    private static let headers: Set<String> = {
        var result = Set<String>()
        for key in ["agent.attach.fileNote.header", "agent.attach.filesNote.header"] {
            for (_, value) in AgentGatewayStrings.table[key] ?? [:] {
                result.insert(value)
            }
        }
        return result
    }()

    /// Returns the text WITHOUT the trailing note, plus the note's paths
    /// (empty when the message carries no note).
    static func split(_ text: String) -> (display: String, paths: [String]) {
        let lines = text.components(separatedBy: "\n")
        // The note is a header line followed by "- path" lines at the END.
        var index = lines.count - 1
        var paths: [String] = []
        while index >= 0, lines[index].hasPrefix("- ") {
            paths.insert(String(lines[index].dropFirst(2)), at: 0)
            index -= 1
        }
        guard !paths.isEmpty, index >= 0,
              headers.contains(lines[index].trimmingCharacters(in: .whitespaces)) else {
            return (text, [])
        }
        let display = lines[..<index].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (display, paths)
    }
}

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
                    HStack(spacing: 5) {
                        Image(systemName: "doc.fill")
                            .font(.system(size: 10))
                        Text((path as NSString).lastPathComponent)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.14), in: Capsule())
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
        let local = AgentFilePaths.localURL(for: path)
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
                    NSWorkspace.shared.activateFileViewerSelecting([local])
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .help(String(format: AGL("agent.file.reveal"), path))
            } else {
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
        .task(id: url) {
            let fileURL = url
            let loaded = await Task.detached(priority: .userInitiated) { () -> String? in
                guard let data = try? Data(contentsOf: fileURL), data.count <= Self.maxBytes else { return nil }
                return String(data: data, encoding: .utf8)
            }.value
            content = loaded ?? ""
        }
    }
}
