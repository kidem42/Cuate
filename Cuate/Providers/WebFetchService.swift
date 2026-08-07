import Foundation
import AppKit

/// `web_fetch` — the companion tool to `web_search`: the model asks for a
/// URL, we download the page and hand back its readable text. Runs CLIENT-
/// side (free, no key, works with every provider) — unlike Claude Desktop,
/// where web_fetch is executed by Anthropic's servers.
enum WebFetchService {
    /// The tool definition advertised to the model.
    static let toolSpec = ToolSpec(
        name: "web_fetch",
        description: "Fetch a web page by URL and return its readable text. Use it to read a promising web_search result in full, or when the user provides a URL. Works for HTML and plain-text pages; not for downloading binary files.",
        parameters: [
            "type": "object",
            "properties": [
                "url": [
                    "type": "string",
                    "description": "Full http(s) URL of the page to read."
                ]
            ],
            "required": ["url"]
        ]
    )

    /// Text budget returned to the model — a full article fits, giant pages
    /// get truncated with an explicit note so the model knows it saw a part.
    private static let maxChars = 24_000
    /// Download cap: pages above this are not real articles.
    private static let maxBytes = 5 * 1024 * 1024

    static func fetch(urlString: String) async throws -> String {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty else {
            throw ProviderError.http(status: 0, message: "web_fetch: invalid or non-http(s) URL")
        }
        // SSRF hygiene: the model must not be able to read the local network.
        guard !isPrivateHost(host) else {
            throw ProviderError.http(status: 0, message: "web_fetch: local and private addresses are not allowed")
        }

        var request = URLRequest(url: url, timeoutInterval: 25)
        // Default CFNetwork UA gets bot-blocked on many sites — look like Safari.
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

        let (data, response) = try await HTTPClient.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.http(status: http.statusCode, message: "web_fetch: page returned HTTP \(http.statusCode)")
        }
        guard data.count <= Self.maxBytes else {
            throw ProviderError.http(status: 0, message: "web_fetch: page is too large (\(data.count / 1024) KB)")
        }

        let mime = (http.mimeType ?? "").lowercased()
        let text: String
        if mime.contains("html") || mime.isEmpty {
            text = await extractReadableText(from: data, encodingName: http.textEncodingName)
        } else if mime.hasPrefix("text/") || mime.contains("json") || mime.contains("xml") {
            text = decodeString(data, encodingName: http.textEncodingName)
        } else {
            throw ProviderError.http(status: 0, message: "web_fetch: unsupported content type \(mime)")
        }

        let cleaned = text
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw ProviderError.http(status: 0, message: "web_fetch: the page produced no readable text (may require JavaScript)")
        }

        var result = "Content of \(url.absoluteString):\n\n"
        if cleaned.count > Self.maxChars {
            result += cleaned.prefix(Self.maxChars) + "\n\n[Truncated: page continues beyond \(Self.maxChars) characters]"
        } else {
            result += cleaned
        }
        return result
    }

    // MARK: - HTML → text

    /// NSAttributedString's HTML importer (main-thread only, WebKit-legacy)
    /// handles entities/structure; when it fails, tags are stripped crudely.
    private static func extractReadableText(from data: Data, encodingName: String?) async -> String {
        let html = decodeString(data, encodingName: encodingName)
        // <script>/<style> go first: not text to the importer, garbage to the fallback.
        let stripped = html
            .replacingOccurrences(of: "(?is)<(script|style|noscript|svg|iframe)\\b.*?</\\1>", with: " ", options: .regularExpression)
        let attributed = await MainActor.run { () -> String? in
            guard let data = stripped.data(using: .utf8),
                  let parsed = try? NSAttributedString(
                    data: data,
                    options: [.documentType: NSAttributedString.DocumentType.html,
                              .characterEncoding: String.Encoding.utf8.rawValue],
                    documentAttributes: nil
                  ) else { return nil }
            return parsed.string
        }
        if let attributed, !attributed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return attributed
        }
        // Fallback: block tags → newlines, every other tag is dropped.
        return stripped
            .replacingOccurrences(of: "(?i)<(br|/p|/div|/h[1-6]|/li|/tr)[^>]*>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    }

    private static func decodeString(_ data: Data, encodingName: String?) -> String {
        if let encodingName {
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(encodingName as CFString)
            if cfEncoding != kCFStringEncodingInvalidId {
                let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
                if let s = String(data: data, encoding: encoding) { return s }
            }
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
    }

    /// localhost, RFC1918, link-local, .local/.internal and dot-less hosts
    /// (intranet names) — all rejected.
    private static func isPrivateHost(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" || host.hasSuffix(".local") || host.hasSuffix(".internal") { return true }
        if !host.contains(".") { return true }
        if host.hasPrefix("127.") || host.hasPrefix("10.") || host.hasPrefix("192.168.")
            || host.hasPrefix("169.254.") || host.hasPrefix("0.") { return true }
        // 172.16.0.0/12
        if host.hasPrefix("172.") {
            let octet = host.dropFirst(4).prefix { $0 != "." }
            if let n = Int(octet), (16...31).contains(n) { return true }
        }
        // IPv6 unique-local / link-local literals ([fd..], [fe80..]).
        if host.hasPrefix("fd") || host.hasPrefix("fe80") { return true }
        return false
    }
}
