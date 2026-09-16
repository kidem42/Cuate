import Foundation
import Darwin

/// Isolated, bounded downloads of presigned note/transcript links. Never uses
/// the authenticated API session, cookies, a cache, or redirects.
nonisolated enum PlaudContentFetch {
    static let maxBytes = 20 * 1024 * 1024

    static func validatedURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host, !host.isEmpty,
              !host.contains(":"), host.contains("."),
              host.range(of: #"^[0-9.]+$"#, options: .regularExpression) == nil else { return nil }
        return url
    }

    static func publicAddress(_ text: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            let n = UInt32(bigEndian: v4.s_addr)
            let a = n >> 24, b = (n >> 16) & 255, c = (n >> 8) & 255
            return !(a == 0 || a == 10 || a == 127 || a >= 224
                || (a == 100 && (64...127).contains(b))
                || (a == 169 && b == 254) || (a == 172 && (16...31).contains(b))
                || (a == 192 && (b == 168 || (b == 0 && (c == 0 || c == 2))))
                || (a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100)))
                || (a == 203 && b == 0 && c == 113))
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, text, &v6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: &v6) { Array($0) }
        // Global unicast only. Exclude special-purpose, documentation and
        // transition ranges rather than allowing embedded private IPv4.
        return bytes[0] & 0xe0 == 0x20
            && !(bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] < 0x02)
            && !(bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8)
            && !(bytes[0] == 0x20 && bytes[1] == 0x02)
            && !(bytes[0] == 0x3f && bytes[1] == 0xff)
    }

    private static func publicHost(_ host: String) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "443", &hints, &result) == 0, let first = result else { return false }
        defer { freeaddrinfo(first) }
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let current = node {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(current.pointee.ai_addr, current.pointee.ai_addrlen,
                              &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0,
                  publicAddress(String(cString: buffer)) else { return false }
            node = current.pointee.ai_next
        }
        return true
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    static func text(_ raw: String) async throws -> String {
        guard let url = validatedURL(raw), let host = url.host else { throw URLError(.badURL) }
        // DNS is blocking; keep it off the main actor. Like upstream safe-fetch,
        // this is preflight validation, not DNS pinning of the transport.
        let allowed = await Task.detached { publicHost(host) }.value
        try Task.checkCancellation()
        guard allowed else { throw URLError(.cannotFindHost) }
        return try await download(url)
    }

    /// Transport seam for offline URLProtocol tests; production calls this only
    /// after URL and DNS validation above.
    static func download(_ url: URL, configuration: URLSessionConfiguration = .ephemeral) async throws -> String {
        let config = configuration
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              response.expectedContentLength <= maxBytes else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maxBytes else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        guard let text = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
        return text
    }
}
