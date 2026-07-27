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
                state = .failed
                return
            }
            Self.cache.setObject(image, forKey: urlString as NSString)
            state = .loaded(image)
        } catch {
            state = .failed
        }
    }
}
