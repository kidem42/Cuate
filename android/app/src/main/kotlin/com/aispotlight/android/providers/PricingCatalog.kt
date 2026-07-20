package com.aispotlight.android.providers

import android.content.Context
import com.aispotlight.android.core.Diagnostics
import com.aispotlight.android.core.HttpClient
import com.aispotlight.android.core.ProviderID
import com.aispotlight.android.core.TokenUsage
import okhttp3.Request
import org.json.JSONObject
import java.io.File

/**
 * USD prices per ONE token (LiteLLM's unit — multiply by counts directly).
 * Port of the macOS `ModelPricing`. Null fields mean "unknown"; [cost] falls
 * back conservatively: unknown cache-read bills at the input rate, unknown
 * cache-write at 1.25× input (the Anthropic premium — the only provider that
 * bills writes today).
 */
data class ModelPricing(
    val inputPerToken: Double? = null,
    val outputPerToken: Double? = null,
    val cacheReadPerToken: Double? = null,
    val cacheWritePerToken: Double? = null,
) {
    /** Turn cost in USD, or null when the base input/output prices are unknown. */
    fun cost(usage: TokenUsage): Double? {
        val input = inputPerToken ?: return null
        val output = outputPerToken ?: return null
        val read = cacheReadPerToken ?: input
        val write = cacheWritePerToken ?: input * 1.25
        return usage.inputTokens * input +
            usage.outputTokens * output +
            usage.cacheReadTokens * read +
            usage.cacheWriteTokens * write
    }
}

/**
 * Per-model chat prices + flat rates for non-token services (OCR, STT).
 * Port of the macOS `PricingCatalog`.
 *
 * Sources, in priority order at lookup time:
 * 1. `pricing-cache.json` in the app files dir — written by the weekly
 *    LiteLLM refresh; applies from the next launch.
 * 2. The bundled snapshot below (same LiteLLM field names, one parser).
 * 3. OpenRouter models are NOT here: callers use the live catalog price
 *    from `ModelInfo` (see ChatService), which is exact per-model.
 */
object PricingCatalog {

    private var cacheFile: File? = null
    @Volatile private var catalog: Map<String, Map<String, ModelPricing>> = emptyMap()

    /** Called once from App.onCreate — loads snapshot + on-disk refresh cache. */
    fun init(context: Context) {
        val file = File(context.filesDir, "pricing-cache.json")
        cacheFile = file
        var merged = parse(SNAPSHOT_JSON)
        if (file.exists()) {
            try {
                val cached = parse(file.readText())
                merged = merged.toMutableMap().apply {
                    for ((provider, models) in cached) {
                        put(provider, (get(provider) ?: emptyMap()) + models)
                    }
                }
            } catch (_: Exception) { /* corrupt cache — snapshot still applies */ }
        }
        catalog = merged
    }

    // MARK: Lookup

    /**
     * Resolves pricing for a provider+model. Matching: exact id first, then
     * the LONGEST catalog key that is a prefix of the model id — so
     * "claude-sonnet-5" matches "claude-sonnet-5-20250929", and "gpt-5.5"
     * prefers the "gpt-5.5" entry over "gpt-5".
     */
    fun pricing(provider: ProviderID, model: String): ModelPricing? {
        val table = catalog[provider.id] ?: return null
        table[model]?.let { return it }
        val key = table.keys.filter { model.startsWith(it) }.maxByOrNull { it.length }
        return key?.let { table[it] }
    }

    /** Flat rates for non-token services, USD per unit. */
    val ocrPerPage: Map<String, Double> = mapOf(
        "mistral" to 0.001, // $1 per 1000 pages
    )
    val sttPerMinute: Map<String, Double> = mapOf(
        "mistral" to 0.001,   // Voxtral mini transcribe
        "openai" to 0.006,    // gpt-4o-transcribe
        "deepgram" to 0.0043, // Nova-3 pay-as-you-go
    )
    /** Brave Search "Base AI" plan rate ($5 CPM); free tier bills nothing. */
    const val SEARCH_PER_QUERY = 0.005

    // MARK: Parsing (snapshot + cache share the format)

    /** Parses {provider: {model: {input_cost_per_token, ...}}}, USD per token. */
    private fun parse(raw: String): Map<String, Map<String, ModelPricing>> {
        val json = try { JSONObject(raw) } catch (_: Exception) { return emptyMap() }
        val result = mutableMapOf<String, Map<String, ModelPricing>>()
        for (provider in json.keys()) {
            if (provider == "fetched_at") continue
            val models = json.optJSONObject(provider) ?: continue
            val table = mutableMapOf<String, ModelPricing>()
            for (model in models.keys()) {
                val f = models.optJSONObject(model) ?: continue
                val pricing = ModelPricing(
                    inputPerToken = f.optDoubleOrNull("input_cost_per_token"),
                    outputPerToken = f.optDoubleOrNull("output_cost_per_token"),
                    cacheReadPerToken = f.optDoubleOrNull("cache_read_input_token_cost"),
                    cacheWritePerToken = f.optDoubleOrNull("cache_creation_input_token_cost"),
                )
                if (pricing.inputPerToken != null || pricing.outputPerToken != null) {
                    table[model] = pricing
                }
            }
            if (table.isNotEmpty()) result[provider] = table
        }
        return result
    }

    private fun JSONObject.optDoubleOrNull(key: String): Double? =
        if (has(key)) optDouble(key).takeIf { !it.isNaN() } else null

    // MARK: Weekly refresh from LiteLLM

    private const val REMOTE_URL =
        "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
    private const val REFRESH_INTERVAL_MS = 7L * 24 * 3600 * 1000

    /**
     * Fire-and-forget: refreshes the on-disk cache when it is missing or older
     * than a week. Network errors are silent — the snapshot still applies.
     * Called lazily from the spend path (first record per launch).
     */
    fun refreshIfStale() {
        val file = cacheFile ?: return
        if (file.exists() && System.currentTimeMillis() - file.lastModified() < REFRESH_INTERVAL_MS) return
        Thread {
            try {
                val request = Request.Builder().url(REMOTE_URL).build()
                HttpClient.client.newCall(request).execute().use { response ->
                    if (!response.isSuccessful) return@use
                    val json = JSONObject(response.body?.string() ?: return@use)
                    val filtered = JSONObject()
                    for (key in json.keys()) {
                        val fields = json.optJSONObject(key) ?: continue
                        if (!fields.has("input_cost_per_token")) continue
                        val (provider, model) = mapLiteLLMKey(key) ?: continue
                        val entry = JSONObject()
                        for (field in listOf(
                            "input_cost_per_token", "output_cost_per_token",
                            "cache_read_input_token_cost", "cache_creation_input_token_cost"
                        )) {
                            if (fields.has(field)) entry.put(field, fields.optDouble(field))
                        }
                        val table = filtered.optJSONObject(provider) ?: JSONObject().also { filtered.put(provider, it) }
                        table.put(model, entry)
                    }
                    if (filtered.length() > 0) {
                        filtered.put("fetched_at", System.currentTimeMillis())
                        file.writeText(filtered.toString())
                        Diagnostics.log("pricing", "refresh.done providers=${filtered.length() - 1}")
                    }
                }
            } catch (_: Exception) { /* silent — snapshot still applies */ }
        }.apply { isDaemon = true }.start()
    }

    /**
     * Maps a LiteLLM catalog key ("gemini/gemini-2.5-flash", "claude-…",
     * "deepseek/deepseek-chat") to (our provider id, bare model id).
     * OpenRouter is deliberately skipped — its live catalog is exact.
     */
    private fun mapLiteLLMKey(key: String): Pair<String, String>? {
        fun strip(prefix: String): String? {
            if (!key.startsWith(prefix)) return null
            val bare = key.removePrefix(prefix)
            return if (bare.contains("/")) null else bare
        }
        strip("anthropic/")?.let { return "anthropic" to it }
        if (key.startsWith("claude")) return "anthropic" to key
        strip("gemini/")?.let { return "gemini" to it }
        strip("deepseek/")?.let { return "deepseek" to it }
        strip("mistral/")?.let { return "mistral" to it }
        strip("moonshot/")?.let { return "kimi" to it }
        strip("moonshotai/")?.let { return "kimi" to it }
        if (key.startsWith("gpt") || key.startsWith("o1") || key.startsWith("o3") ||
            key.startsWith("o4") || key.startsWith("chatgpt") || key.startsWith("chat-latest")
        ) {
            return "openai" to key
        }
        return null
    }

    // MARK: Bundled snapshot

    /**
     * USD per token, LiteLLM field names. Mirror of the macOS snapshot
     * (2026-07): Anthropic price sheet; DeepSeek V4 hit/miss; Kimi K3/K2.x
     * cached; Gemini 2.5; Mistral; OpenAI.
     */
    private val SNAPSHOT_JSON = """
    {
      "anthropic": {
        "claude-fable-5":    {"input_cost_per_token": 1e-05, "output_cost_per_token": 5e-05, "cache_read_input_token_cost": 1e-06, "cache_creation_input_token_cost": 1.25e-05},
        "claude-mythos-5":   {"input_cost_per_token": 1e-05, "output_cost_per_token": 5e-05, "cache_read_input_token_cost": 1e-06, "cache_creation_input_token_cost": 1.25e-05},
        "claude-opus-4-8":   {"input_cost_per_token": 5e-06, "output_cost_per_token": 2.5e-05, "cache_read_input_token_cost": 5e-07, "cache_creation_input_token_cost": 6.25e-06},
        "claude-opus-4-7":   {"input_cost_per_token": 5e-06, "output_cost_per_token": 2.5e-05, "cache_read_input_token_cost": 5e-07, "cache_creation_input_token_cost": 6.25e-06},
        "claude-opus-4-6":   {"input_cost_per_token": 5e-06, "output_cost_per_token": 2.5e-05, "cache_read_input_token_cost": 5e-07, "cache_creation_input_token_cost": 6.25e-06},
        "claude-opus-4-5":   {"input_cost_per_token": 5e-06, "output_cost_per_token": 2.5e-05, "cache_read_input_token_cost": 5e-07, "cache_creation_input_token_cost": 6.25e-06},
        "claude-opus-4-1":   {"input_cost_per_token": 1.5e-05, "output_cost_per_token": 7.5e-05, "cache_read_input_token_cost": 1.5e-06, "cache_creation_input_token_cost": 1.875e-05},
        "claude-opus-4-0":   {"input_cost_per_token": 1.5e-05, "output_cost_per_token": 7.5e-05, "cache_read_input_token_cost": 1.5e-06, "cache_creation_input_token_cost": 1.875e-05},
        "claude-sonnet-5":   {"input_cost_per_token": 3e-06, "output_cost_per_token": 1.5e-05, "cache_read_input_token_cost": 3e-07, "cache_creation_input_token_cost": 3.75e-06},
        "claude-sonnet-4":   {"input_cost_per_token": 3e-06, "output_cost_per_token": 1.5e-05, "cache_read_input_token_cost": 3e-07, "cache_creation_input_token_cost": 3.75e-06},
        "claude-haiku-4-5":  {"input_cost_per_token": 1e-06, "output_cost_per_token": 5e-06, "cache_read_input_token_cost": 1e-07, "cache_creation_input_token_cost": 1.25e-06},
        "claude-3-5-haiku":  {"input_cost_per_token": 8e-07, "output_cost_per_token": 4e-06},
        "claude-3-haiku":    {"input_cost_per_token": 2.5e-07, "output_cost_per_token": 1.25e-06}
      },
      "openai": {
        "gpt-5.5":      {"input_cost_per_token": 5e-06, "output_cost_per_token": 3e-05, "cache_read_input_token_cost": 5e-07},
        "gpt-5-mini":   {"input_cost_per_token": 2.5e-07, "output_cost_per_token": 2e-06, "cache_read_input_token_cost": 2.5e-08},
        "gpt-5-nano":   {"input_cost_per_token": 5e-08, "output_cost_per_token": 4e-07, "cache_read_input_token_cost": 5e-09},
        "gpt-5-chat":   {"input_cost_per_token": 1.25e-06, "output_cost_per_token": 1e-05, "cache_read_input_token_cost": 1.25e-07},
        "chat-latest":  {"input_cost_per_token": 1.25e-06, "output_cost_per_token": 1e-05, "cache_read_input_token_cost": 1.25e-07},
        "gpt-5":        {"input_cost_per_token": 1.25e-06, "output_cost_per_token": 1e-05, "cache_read_input_token_cost": 1.25e-07},
        "gpt-4.1":      {"input_cost_per_token": 2e-06, "output_cost_per_token": 8e-06, "cache_read_input_token_cost": 5e-07},
        "gpt-4.1-mini": {"input_cost_per_token": 4e-07, "output_cost_per_token": 1.6e-06, "cache_read_input_token_cost": 1e-07},
        "gpt-4.1-nano": {"input_cost_per_token": 1e-07, "output_cost_per_token": 4e-07, "cache_read_input_token_cost": 2.5e-08},
        "gpt-4o":       {"input_cost_per_token": 2.5e-06, "output_cost_per_token": 1e-05, "cache_read_input_token_cost": 1.25e-06},
        "gpt-4o-mini":  {"input_cost_per_token": 1.5e-07, "output_cost_per_token": 6e-07, "cache_read_input_token_cost": 7.5e-08},
        "o3":           {"input_cost_per_token": 2e-06, "output_cost_per_token": 8e-06, "cache_read_input_token_cost": 5e-07},
        "o4-mini":      {"input_cost_per_token": 1.1e-06, "output_cost_per_token": 4.4e-06, "cache_read_input_token_cost": 2.75e-07}
      },
      "gemini": {
        "gemini-flash-latest":    {"input_cost_per_token": 3e-07, "output_cost_per_token": 2.5e-06, "cache_read_input_token_cost": 7.5e-08},
        "gemini-2.5-pro":         {"input_cost_per_token": 1.25e-06, "output_cost_per_token": 1e-05, "cache_read_input_token_cost": 3.1e-07},
        "gemini-2.5-flash":       {"input_cost_per_token": 3e-07, "output_cost_per_token": 2.5e-06, "cache_read_input_token_cost": 7.5e-08},
        "gemini-2.5-flash-lite":  {"input_cost_per_token": 1e-07, "output_cost_per_token": 4e-07, "cache_read_input_token_cost": 2.5e-08},
        "gemini-2.0-flash":       {"input_cost_per_token": 1e-07, "output_cost_per_token": 4e-07, "cache_read_input_token_cost": 2.5e-08},
        "gemini-1.5-flash":       {"input_cost_per_token": 7.5e-08, "output_cost_per_token": 3e-07},
        "gemini-1.5-pro":         {"input_cost_per_token": 1.25e-06, "output_cost_per_token": 5e-06}
      },
      "mistral": {
        "mistral-large":  {"input_cost_per_token": 2e-06, "output_cost_per_token": 6e-06},
        "mistral-medium": {"input_cost_per_token": 4e-07, "output_cost_per_token": 2e-06},
        "mistral-small":  {"input_cost_per_token": 1e-07, "output_cost_per_token": 3e-07},
        "codestral":      {"input_cost_per_token": 3e-07, "output_cost_per_token": 9e-07}
      },
      "deepseek": {
        "deepseek-chat":     {"input_cost_per_token": 1.4e-07, "output_cost_per_token": 2.8e-07, "cache_read_input_token_cost": 2.8e-09},
        "deepseek-reasoner": {"input_cost_per_token": 4.35e-07, "output_cost_per_token": 8.7e-07, "cache_read_input_token_cost": 3.625e-09}
      },
      "kimi": {
        "kimi-k3":   {"input_cost_per_token": 3e-06, "output_cost_per_token": 1.5e-05, "cache_read_input_token_cost": 3e-07},
        "kimi-k2.7": {"input_cost_per_token": 9.5e-07, "output_cost_per_token": 4e-06, "cache_read_input_token_cost": 1.6e-07},
        "kimi-k2.6": {"input_cost_per_token": 9.5e-07, "output_cost_per_token": 4e-06, "cache_read_input_token_cost": 1.6e-07},
        "kimi-k2":   {"input_cost_per_token": 6e-07, "output_cost_per_token": 2.5e-06, "cache_read_input_token_cost": 1.5e-07}
      }
    }
    """.trimIndent()
}
