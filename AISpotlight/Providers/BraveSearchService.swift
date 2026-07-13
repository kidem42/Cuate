import Foundation

/// Brave Search API — the universal `web_search` tool available to every chat
/// provider through function calling.
enum BraveSearchService {
    private static let endpoint = URL(string: "https://api.search.brave.com/res/v1/web/search")!

    static var isAvailable: Bool {
        APIKeyStore.key(aux: .brave) != nil
    }

    /// The tool definition advertised to the model.
    static let toolSpec = ToolSpec(
        name: "web_search",
        description: "Search the web for current information. Use this when the answer depends on recent events, live data (prices, weather, news, releases), or facts you are not confident about. Returns titles, URLs and snippets.",
        parameters: [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "The search query, in the language most likely to have good results."
                ]
            ],
            "required": ["query"]
        ]
    )

    struct Result {
        let title: String
        let url: String
        let snippet: String
        let extraSnippets: [String]
    }

    /// Runs a web search and returns results formatted for a tool result message.
    /// On Base AI / Pro AI plans, `extra_snippets` enriches each result with up
    /// to 5 additional page excerpts; on plans without it we retry without the flag.
    static func search(query: String, count: Int = 5) async throws -> String {
        do {
            return try await performSearch(query: query, count: count, extraSnippets: true)
        } catch let error as ProviderError {
            if case .http(let status, _) = error, (400..<500).contains(status) {
                // Plan may not include extra_snippets — retry the plain request.
                return try await performSearch(query: query, count: count, extraSnippets: false)
            }
            throw error
        }
    }

    private static func performSearch(query: String, count: Int, extraSnippets: Bool) async throws -> String {
        guard let apiKey = APIKeyStore.key(aux: .brave) else {
            throw ProviderError.http(status: 0, message: "No Brave Search API key configured.")
        }

        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        var queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: String(count))
        ]
        if extraSnippets {
            queryItems.append(URLQueryItem(name: "extra_snippets", value: "true"))
        }
        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data = try await HTTPClient.json(request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let web = json["web"] as? [String: Any],
              let items = web["results"] as? [[String: Any]] else {
            throw ProviderError.decoding("unexpected Brave Search payload")
        }

        let results: [Result] = items.prefix(count).compactMap { item in
            guard let title = item["title"] as? String,
                  let url = item["url"] as? String else { return nil }
            return Result(
                title: title,
                url: url,
                snippet: (item["description"] as? String) ?? "",
                extraSnippets: (item["extra_snippets"] as? [String]) ?? []
            )
        }

        guard !results.isEmpty else {
            return "No results found for \"\(query)\"."
        }

        return results.enumerated().map { index, result in
            var block = "\(index + 1). \(result.title)\n\(result.url)\n\(result.snippet)"
            if !result.extraSnippets.isEmpty {
                block += "\n" + result.extraSnippets.map { "• \($0)" }.joined(separator: "\n")
            }
            return block
        }.joined(separator: "\n\n")
    }
}
