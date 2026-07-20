package com.aispotlight.android.providers

import com.aispotlight.android.core.HttpClient
import com.aispotlight.android.core.ProviderException
import com.aispotlight.android.core.ToolSpec
import com.aispotlight.android.data.SpendKind
import com.aispotlight.android.data.SpendTracker
import com.aispotlight.android.settings.ApiKeyStore
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject

/**
 * Brave Search API — the universal `web_search` tool available to every chat
 * provider through function calling.
 */
object BraveSearchService {
    private const val ENDPOINT = "https://api.search.brave.com/res/v1/web/search"

    val isAvailable: Boolean
        get() = ApiKeyStore.auxKey(ApiKeyStore.AuxKey.BRAVE) != null

    /** The tool definition advertised to the model. */
    val toolSpec = ToolSpec(
        name = "web_search",
        description = "Search the web for current information. Use this when the answer depends on recent events, live data (prices, weather, news, releases), or facts you are not confident about. Returns titles, URLs and snippets.",
        parameters = JSONObject()
            .put("type", "object")
            .put("properties", JSONObject().put("query", JSONObject()
                .put("type", "string")
                .put("description", "The search query, in the language most likely to have good results.")))
            .put("required", JSONArray().put("query"))
    )

    private data class Result(
        val title: String,
        val url: String,
        val snippet: String,
        val extraSnippets: List<String>,
    )

    /**
     * Runs a web search and returns results formatted for a tool result message.
     * On Base AI / Pro AI plans, `extra_snippets` enriches each result with up
     * to 5 additional page excerpts; on plans without it we retry without the flag.
     */
    suspend fun search(query: String, count: Int = 5): String {
        // Costs tab: count the query at the Base AI plan rate ($0.005/query).
        // Free-tier users pay nothing — flagged as an upper-bound estimate.
        SpendTracker.record(
            kind = SpendKind.SEARCH, provider = "brave", model = "web-search",
            units = 1.0, costUSD = PricingCatalog.SEARCH_PER_QUERY, isEstimate = true,
        )
        return try {
            performSearch(query, count, extraSnippets = true)
        } catch (e: ProviderException) {
            if (e.kind == ProviderException.Kind.HTTP &&
                (e.message ?: "").contains("HTTP 4")
            ) {
                // Plan may not include extra_snippets — retry the plain request.
                performSearch(query, count, extraSnippets = false)
            } else {
                throw e
            }
        }
    }

    private suspend fun performSearch(query: String, count: Int, extraSnippets: Boolean): String {
        val apiKey = ApiKeyStore.auxKey(ApiKeyStore.AuxKey.BRAVE)
            ?: throw ProviderException.http(0, "No Brave Search API key configured.")

        val urlBuilder = ENDPOINT.toHttpUrl().newBuilder()
            .addQueryParameter("q", query)
            .addQueryParameter("count", count.toString())
        if (extraSnippets) urlBuilder.addQueryParameter("extra_snippets", "true")

        val request = Request.Builder()
            .url(urlBuilder.build())
            .header("X-Subscription-Token", apiKey)
            .header("Accept", "application/json")
            .build()

        val data = HttpClient.json(request)
        val items = try {
            JSONObject(data).getJSONObject("web").getJSONArray("results")
        } catch (_: Exception) {
            throw ProviderException.decoding("unexpected Brave Search payload")
        }

        val results = mutableListOf<Result>()
        for (i in 0 until minOf(items.length(), count)) {
            val item = items.optJSONObject(i) ?: continue
            val title = item.optString("title").takeIf { it.isNotEmpty() } ?: continue
            val url = item.optString("url").takeIf { it.isNotEmpty() } ?: continue
            val extra = item.optJSONArray("extra_snippets")
                ?.let { arr -> (0 until arr.length()).mapNotNull { arr.optString(it).takeIf { s -> s.isNotEmpty() } } }
                ?: emptyList()
            results.add(Result(title, url, item.optString("description"), extra))
        }

        if (results.isEmpty()) return "No results found for \"$query\"."

        return results.mapIndexed { index, result ->
            buildString {
                append("${index + 1}. ${result.title}\n${result.url}\n${result.snippet}")
                if (result.extraSnippets.isNotEmpty()) {
                    append("\n" + result.extraSnippets.joinToString("\n") { "• $it" })
                }
            }
        }.joinToString("\n\n")
    }
}
