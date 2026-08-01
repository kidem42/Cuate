import SwiftUI
import AppKit

/// Inline image from a markdown `![](url)` line. Plain URLs load plainly;
/// URLs pointing at a connected agent gateway get its Bearer token — a
/// screenshot the agent serves from its own host would otherwise 401 and
/// silently never render (notes §7.2 п.5). `data:image/...` URLs decode
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
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 420, maxHeight: 420, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .help(alt.isEmpty ? urlString : alt)
                // A mirrored image is NOT a local attachment — without its
                // own menu there was no way to copy or save a photo that
                // arrived from another device (feedback 2026-08-01).
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
        }
        // The DASHBOARD host serves the files the courier uploaded — that is
        // how an image sent from another device renders here (the gateway
        // keeps no pixels). Its own token, same never-leak rule.
        if let dashHost = HermesSettings.shared.dashboardBaseURL?.host,
           url.host == dashHost,
           let token = APIKeyStore.key(aux: .hermesDashboard) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
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
