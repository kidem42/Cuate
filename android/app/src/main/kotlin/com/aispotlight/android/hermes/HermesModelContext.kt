package com.aispotlight.android.hermes

/**
 * Context-window resolution for the gauge — the Kotlin port of the desktop's
 * `HermesModelContext.swift` (which itself mirrors Hermes' own chain in
 * `agent/model_metadata.py`, v0.20.0):
 *
 *   1. The gateway's `GET /api/model/info` (`effective_context_length`) —
 *      served by the DASHBOARD server (the API server has never had the
 *      route), so it resolves through the dashboard URL when configured.
 *      Only valid for the agent's currently configured model.
 *   2. `DEFAULT_CONTEXT_LENGTHS` ported from Hermes v0.20.0 with its
 *      matching rule: longest key first, key must be a substring of the
 *      lowercased model id.
 *   3. The 256K fallback — Hermes' own final default.
 *
 * ⚠️ Generated from the desktop table — when it moves, re-port, don't edit
 * entries here by hand.
 */
object HermesModelContext {

    private val defaultContextLengths: Map<String, Int> = mapOf(
        // Anthropic Claude — current 1M family, bare ids to avoid
        // fuzzy-match collisions; older models fall to the 200K catch-all.
        "claude-fable-5" to 1_000_000,
        "claude-fable" to 1_000_000,
        "claude-opus-5" to 1_000_000,
        "claude-sonnet-5" to 1_000_000,
        "claude-opus-4-8" to 1_000_000,
        "claude-opus-4.8" to 1_000_000,
        "claude-opus-4-7" to 1_000_000,
        "claude-opus-4.7" to 1_000_000,
        "claude-opus-4-6" to 1_000_000,
        "claude-sonnet-4-6" to 1_000_000,
        "claude-opus-4.6" to 1_000_000,
        "claude-sonnet-4.6" to 1_000_000,
        "claude" to 200_000,
        // OpenAI GPT-5 family. NOTE (Hermes comment): 5.5/5.6 are 1.05M on
        // the direct API but capped at 272K via ChatGPT Codex OAuth — that
        // cap only resolves through the gateway's own chain (step 1 above).
        "gpt-5.6-luna" to 1_050_000,
        "gpt-5.6-terra" to 1_050_000,
        "gpt-5.6-sol" to 1_050_000,
        "gpt-5.5" to 1_050_000,
        "gpt-5.4-nano" to 400_000,
        "gpt-5.4-mini" to 400_000,
        "gpt-5.4" to 1_050_000,
        "gpt-5.3-codex-spark" to 128_000,
        "gpt-5.1-chat" to 128_000,
        "gpt-5" to 400_000,
        "gpt-4.1" to 1_047_576,
        "gpt-4" to 128_000,
        // Google
        "gemini" to 1_048_576,
        "gemma-4-31b" to 256_000,
        "gemma-4" to 256_000,
        "gemma4" to 256_000,
        "gemma-3" to 131_072,
        "gemma" to 8_192,
        // DeepSeek — V4 family is 1M; bare "deepseek" stays a 128K fallback.
        "deepseek-v4-pro" to 1_000_000,
        "deepseek-v4-flash" to 1_000_000,
        "deepseek-chat" to 1_000_000,
        "deepseek-reasoner" to 1_000_000,
        "deepseek" to 128_000,
        // Meta
        "llama" to 131_072,
        // Qwen
        "qwen3.6-plus" to 1_048_576,
        "qwen3.7-plus" to 1_048_576,
        "qwen3.8-max" to 1_000_000,
        "qwen3-coder-plus" to 1_000_000,
        "qwen3-coder" to 262_144,
        "qwen3-max" to 262_144,
        "qwen" to 131_072,
        // MiniMax
        "minimax-m3" to 1_000_000,
        "minimax" to 204_800,
        // GLM
        "glm-5.2" to 1_048_576,
        "glm" to 202_752,
        // xAI Grok
        "grok-4.6" to 500_000,
        "grok-composer" to 200_000,
        "grok-build-latest" to 500_000,
        "grok-build" to 256_000,
        "grok-code-fast" to 256_000,
        "grok-2-vision" to 8_192,
        "grok-4-fast" to 2_000_000,
        "grok-4.20" to 2_000_000,
        "grok-4.5" to 500_000,
        "grok-4.3" to 1_000_000,
        "grok-4" to 256_000,
        "grok-3" to 131_072,
        "grok-2" to 131_072,
        "grok" to 131_072,
        // Kimi — K3 is 1M; older/unknown Kimi at 256K.
        "kimi-k3" to 1_048_576,
        "kimi" to 262_144,
        // Upstage Solar
        "solar-open2" to 262_144,
        "solar-pro3" to 131_072,
        "solar-pro2" to 65_536,
        "solar-mini" to 32_768,
        // Tencent Hunyuan
        "hy3-preview" to 262_144,
        "hy3" to 262_144,
        // NVIDIA Nemotron
        "nemotron" to 131_072,
        // Arcee
        "trinity" to 262_144,
        // OpenRouter
        "elephant" to 262_144,
        // Hugging Face Inference Providers (org/name ids, lowercased)
        "qwen/qwen3.5-397b-a17b" to 131_072,
        "qwen/qwen3.5-35b-a3b" to 131_072,
        "deepseek-ai/deepseek-v3.2" to 65_536,
        "moonshotai/kimi-k2.5" to 262_144,
        "moonshotai/kimi-k2.6" to 262_144,
        "moonshotai/kimi-k2-thinking" to 262_144,
        "minimaxai/minimax-m2.5" to 204_800,
        "xiaomimimo/mimo-v2-flash" to 262_144,
        "mimo-v2-pro" to 1_048_576,
        "mimo-v2.5-pro" to 1_048_576,
        "mimo-v2.5" to 1_048_576,
        "mimo-v2-omni" to 262_144,
        "mimo-v2-flash" to 262_144,
        "zai-org/glm-5" to 202_752,
    )

    /** Keys sorted longest-first once — "gpt-5.6-terra" must win over "gpt-5". */
    private val sortedKeys: List<String> =
        defaultContextLengths.keys.sortedByDescending { it.length }

    const val FALLBACK = 262_144

    /** Hermes step 8: longest-key-first substring lookup. null = fallback. */
    fun lookup(model: String): Int? {
        val lowered = model.lowercase()
        for (key in sortedKeys) if (key in lowered) return defaultContextLengths[key]
        return null
    }

    /**
     * Full client-side chain for a session's gauge denominator.
     * [agentModel]/[agentLength] — the cached `model/info` answer (the
     * gateway's own resolution wins for its exact model: it knows OAuth caps
     * and config overrides no table can).
     */
    fun limit(model: String?, agentModel: String?, agentLength: Int): Int {
        if (model != null) {
            if (agentModel == model && agentLength > 0) return agentLength
            lookup(model)?.let { return it }
        } else if (agentLength > 0) {
            return agentLength
        }
        return FALLBACK
    }
}
