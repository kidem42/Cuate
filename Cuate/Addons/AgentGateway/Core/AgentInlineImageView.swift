import SwiftUI
import AppKit

/// Inline image from a markdown `![](url)` line. Plain URLs load plainly;
/// URLs pointing at a connected agent gateway get its Bearer token — a
/// screenshot the agent serves from its own host would otherwise 401 and
/// silently never render (notes §7.2 item 5). `data:image/...` URLs decode
/// locally without any request.
struct AgentInlineImageView: View {
    @Environment(\.themePalette) private var palette

    let urlString: String
    let alt: String

    private enum LoadState {
        case loading
        case loaded(NSImage)
        case failed
    }
    @State private var state: LoadState = .loading

    /// Decoded-image cache (URL-keyed): transcript rows rebuild on scroll,
    /// and re-fetching a screenshot per rebuild would hammer the gateway.
    private static let cache = NSCache<NSString, NSImage>()
    /// Original bytes, kept alongside: "Save to Downloads" must write the
    /// file as it came (a JPEG re-encoded through NSImage bloats and loses
    /// EXIF), and rows rebuild long after the URLSession data is gone.
    private static let dataCache = NSCache<NSString, NSData>()

    var body: some View {
        switch state {
        case .loading:
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.10))
                .frame(width: 220, height: 140)
                .overlay(ProgressView().controlSize(.small))
                .task { await load() }
        case .loaded(let image):
            // A real Button, not onTapGesture: the bubble wraps markdown in
            // .textSelection(.enabled), and clicks over selectable regions
            // start a selection instead of reaching a gesture (same trap as
            // ArtifactCardView). Click opens the picture full-size in the
            // system viewer — zoom, markup, and export come free — while the
            // right-click menu keeps one-step copy/save (feedback 2026-08-01
            // and 2026-08-19: no way to enlarge or save a note's photo).
            Button { openExternally(image) } label: {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 420, maxHeight: 420, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .textSelection(.disabled)
            .help(alt.isEmpty ? AGL("agent.image.open") : "\(alt) — \(AGL("agent.image.open"))")
            .contextMenu {
                Button(AGL("agent.image.copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([image])
                }
                Button(AGL("agent.image.save")) { saveToDownloads(image) }
            }
        case .failed:
            HStack(spacing: 6) {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.caption)
                Text(alt.isEmpty ? AGL("agent.image.failed") : alt)
                    .font(.footnote)
                    .lineLimit(1)
            }
            .foregroundColor(palette.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            .help(urlString)
            // Failure is NOT terminal. The launch race made it look like it
            // was: a fresh binary (app update) re-authorizes the Keychain
            // ACL in the background for ~6s, chats render immediately, and
            // every inline fetch went out WITHOUT its Bearer → 401 → a dead
            // gray pill until the row was rebuilt (e2e 2026-08-01). Keys
            // landing re-arm the load; a click retries by hand.
            .onTapGesture { state = .loading }
            .onReceive(NotificationCenter.default.publisher(for: .apiKeysDidChange)) { _ in
                state = .loading
            }
        }
    }

    private func load() async {
        if let cached = Self.cache.object(forKey: urlString as NSString) {
            state = .loaded(cached)
            return
        }
        if urlString.hasPrefix("data:image") {
            if let comma = urlString.firstIndex(of: ","),
               let data = Data(base64Encoded: String(urlString[urlString.index(after: comma)...])),
               let image = NSImage(data: data) {
                Self.cache.setObject(image, forKey: urlString as NSString)
                Self.dataCache.setObject(data as NSData, forKey: urlString as NSString)
                state = .loaded(image)
            } else {
                state = .failed
            }
            return
        }
        if !urlString.contains("://") {
            // Cache-relative path (Plaud note pictures downloaded by
            // PlaudImages): read off disk, never a network fetch.
            let fileURL = ChatAttachment.resolveURL(urlString)
            if let data = try? Data(contentsOf: fileURL), let image = NSImage(data: data) {
                Self.cache.setObject(image, forKey: urlString as NSString)
                Self.dataCache.setObject(data as NSData, forKey: urlString as NSString)
                state = .loaded(image)
            } else {
                state = .failed
            }
            return
        }
        guard let url = URL(string: urlString) else {
            state = .failed
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        // The gateway's own host → authorized fetch (and only there: the
        // token must never leak to arbitrary internet hosts).
        if let gatewayHost = HermesSettings.shared.baseURL.host,
           url.host == gatewayHost,
           let key = APIKeyStore.key(aux: .hermes) {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue(HermesTransport.userAgent, forHTTPHeaderField: "User-Agent")
        }
        // The DASHBOARD host serves the files the courier uploaded — that is
        // how an image sent from another device renders here (the gateway
        // keeps no pixels). Its own token, same never-leak rule.
        if let dashHost = HermesSettings.shared.dashboardBaseURL?.host,
           url.host == dashHost,
           let token = APIKeyStore.key(aux: .hermesDashboard) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(HermesTransport.userAgent, forHTTPHeaderField: "User-Agent")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(status), let image = NSImage(data: data) else {
                Diagnostics.log("agent", "image.load.fail http=\(status) bytes=\(data.count)")
                state = .failed
                return
            }
            Self.cache.setObject(image, forKey: urlString as NSString)
            Self.dataCache.setObject(data as NSData, forKey: urlString as NSString)
            state = .loaded(image)
        } catch {
            Diagnostics.log("agent", "image.load.fail \(String(error.localizedDescription.prefix(120)))")
            state = .failed
        }
    }

    /// Opens the picture in the system viewer (Preview by default): free
    /// zoom, markup, and export beat any in-app lightbox. A cache-relative
    /// path opens its file in place; a remote image is written to a stable
    /// temp file first — original bytes when still cached, PNG re-encode as
    /// the fallback — so re-clicks reuse the same file.
    private func openExternally(_ image: NSImage) {
        if !urlString.contains("://") {
            NSWorkspace.shared.open(ChatAttachment.resolveURL(urlString))
            return
        }
        var ext = "png"
        let data: Data
        if let original = Self.dataCache.object(forKey: urlString as NSString) {
            data = original as Data
            ext = data.starts(with: [0xFF, 0xD8]) ? "jpg"
                : data.starts(with: [0x47, 0x49]) ? "gif"
                : "png"
        } else if let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?
                      .representation(using: .png, properties: [:]) {
            data = png
        } else {
            NSSound.beep()
            return
        }
        // FNV-1a of the URL — a stable per-image temp name.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in urlString.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CuateImages", isDirectory: true)
        let name = "image-" + String(format: "%08x", UInt32(truncatingIfNeeded: hash)) + "." + ext
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            NSWorkspace.shared.open(url)
        } catch {
            NSSound.beep()
            Diagnostics.log("agent", "image.open failed \(String(error.localizedDescription.prefix(120)))")
        }
    }

    /// Writes the image into ~/Downloads (uniquified, original bytes when
    /// still cached — PNG re-encode as the fallback) and reveals it in
    /// Finder: the reveal doubles as the "it worked" confirmation.
    private func saveToDownloads(_ image: NSImage) {
        let data: Data
        var filename = alt
        if let original = Self.dataCache.object(forKey: urlString as NSString) {
            data = original as Data
            if (filename as NSString).pathExtension.isEmpty {
                // No usable name (bare markdown alt) — sniff the format.
                let ext = data.starts(with: [0xFF, 0xD8]) ? "jpg"
                    : data.starts(with: [0x47, 0x49]) ? "gif"
                    : "png"
                filename = (filename.isEmpty ? "image" : filename) + ".\(ext)"
            }
        } else if let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?
                      .representation(using: .png, properties: [:]) {
            data = png
            filename = ((filename as NSString).deletingPathExtension.isEmpty
                        ? "image" : (filename as NSString).deletingPathExtension) + ".png"
        } else {
            return
        }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var target = downloads.appendingPathComponent(filename)
        var counter = 2
        while FileManager.default.fileExists(atPath: target.path) {
            let numbered = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            target = downloads.appendingPathComponent(numbered)
            counter += 1
        }
        do {
            try data.write(to: target, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([target])
        } catch {
            Diagnostics.log("agent", "image.save.fail \(String(error.localizedDescription.prefix(120)))")
        }
    }
}
