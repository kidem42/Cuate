import Foundation

/// Context-window resolution for the sidebar gauge — Hermes' own algorithm,
/// not a reinvention. The agent resolves a model's window through a chain
/// ending in a hardcoded family table + 256K fallback
/// (`agent/model_metadata.py`, `get_model_context_length`); we mirror the
/// tail of that chain client-side:
///
///   1. The gateway's `GET /api/model/info` (`effective_context_length`) —
///      the FULL chain (config override, provider probes, Codex-OAuth caps)
///      run by Hermes itself. Only valid for the agent's currently
///      configured model, and only on gateways new enough to have the
///      route (absent → 404, probed 2026-07-29).
///   2. `DEFAULT_CONTEXT_LENGTHS` ported verbatim from Hermes v0.19.0
///      (2026.7.20) with its matching rule: longest key first, key must be
///      a substring of the lowercased model id (one direction only — the
///      reverse would let "claude-sonnet-4" match "claude-sonnet-4-6").
///   3. The user's `contextLimitTokens` setting (262 144 default) — our
///      equivalent of Hermes' final 256K fallback, kept as a manual
///      override for models neither source knows.
enum HermesModelContext {

    /// Hermes `DEFAULT_CONTEXT_LENGTHS` (agent/model_metadata.py, v0.19.0).
    /// Keys are stored lowercased — Hermes compares them against a
    /// lowercased model id, so its few mixed-case entries (HF org/name ids)
    /// can never match there; lowercasing makes them do what they intend.
    /// When upgrading Hermes on the stand, re-diff this table.
    static let defaultContextLengths: [String: Int] = [
        // Anthropic Claude — current 1M family, bare ids to avoid
        // fuzzy-match collisions; older models fall to the 200K catch-all.
        "claude-fable-5": 1_000_000,
        "claude-fable": 1_000_000,
        "claude-opus-5": 1_000_000,
        "claude-sonnet-5": 1_000_000,
        "claude-opus-4-8": 1_000_000,
        "claude-opus-4.8": 1_000_000,
        "claude-opus-4-7": 1_000_000,
        "claude-opus-4.7": 1_000_000,
        "claude-opus-4-6": 1_000_000,
        "claude-sonnet-4-6": 1_000_000,
        "claude-opus-4.6": 1_000_000,
        "claude-sonnet-4.6": 1_000_000,
        "claude": 200_000,
        // OpenAI GPT-5 family. NOTE (Hermes comment): 5.5/5.6 are 1.05M on
        // the direct API but capped at 272K via ChatGPT Codex OAuth — that
        // cap only resolves through the gateway's own chain (step 1 above).
        "gpt-5.6-luna": 1_050_000,
        "gpt-5.6-terra": 1_050_000,
        "gpt-5.6-sol": 1_050_000,
        "gpt-5.5": 1_050_000,
        "gpt-5.4-nano": 400_000,
        "gpt-5.4-mini": 400_000,
        "gpt-5.4": 1_050_000,
        "gpt-5.3-codex-spark": 128_000,
        "gpt-5.1-chat": 128_000,
        "gpt-5": 400_000,
        "gpt-4.1": 1_047_576,
        "gpt-4": 128_000,
        // Google
        "gemini": 1_048_576,
        "gemma-4-31b": 256_000,
        "gemma-4": 256_000,
        "gemma4": 256_000,
        "gemma-3": 131_072,
        "gemma": 8_192,
        // DeepSeek — V4 family is 1M; bare "deepseek" stays a 128K fallback.
        "deepseek-v4-pro": 1_000_000,
        "deepseek-v4-flash": 1_000_000,
        "deepseek-chat": 1_000_000,
        "deepseek-reasoner": 1_000_000,
        "deepseek": 128_000,
        // Meta
        "llama": 131_072,
        // Qwen
        "qwen3.6-plus": 1_048_576,
        "qwen3.7-plus": 1_048_576,
        "qwen3-coder-plus": 1_000_000,
        "qwen3-coder": 262_144,
        "qwen3-max": 262_144,
        "qwen": 131_072,
        // MiniMax
        "minimax-m3": 1_000_000,
        "minimax": 204_800,
        // GLM
        "glm-5.2": 1_048_576,
        "glm": 202_752,
        // xAI Grok
        "grok-composer": 200_000,
        "grok-build-latest": 500_000,
        "grok-build": 256_000,
        "grok-code-fast": 256_000,
        "grok-2-vision": 8_192,
        "grok-4-fast": 2_000_000,
        "grok-4.20": 2_000_000,
        "grok-4.5": 500_000,
        "grok-4.3": 1_000_000,
        "grok-4": 256_000,
        "grok-3": 131_072,
        "grok-2": 131_072,
        "grok": 131_072,
        // Kimi — K3 is 1M; older/unknown Kimi at 256K.
        "kimi-k3": 1_048_576,
        "kimi": 262_144,
        // Upstage Solar
        "solar-open2": 262_144,
        "solar-pro3": 131_072,
        "solar-pro2": 65_536,
        "solar-mini": 32_768,
        // Tencent Hunyuan
        "hy3-preview": 262_144,
        "hy3": 262_144,
        // NVIDIA Nemotron
        "nemotron": 131_072,
        // Arcee
        "trinity": 262_144,
        // OpenRouter
        "elephant": 262_144,
        // Hugging Face Inference Providers (org/name ids, lowercased)
        "qwen/qwen3.5-397b-a17b": 131_072,
        "qwen/qwen3.5-35b-a3b": 131_072,
        "deepseek-ai/deepseek-v3.2": 65_536,
        "moonshotai/kimi-k2.5": 262_144,
        "moonshotai/kimi-k2.6": 262_144,
        "moonshotai/kimi-k2-thinking": 262_144,
        "minimaxai/minimax-m2.5": 204_800,
        "xiaomimimo/mimo-v2-flash": 262_144,
        "mimo-v2-pro": 1_048_576,
        "mimo-v2.5-pro": 1_048_576,
        "mimo-v2.5": 1_048_576,
        "mimo-v2-omni": 262_144,
        "mimo-v2-flash": 262_144,
        "zai-org/glm-5": 202_752,
    ]

    /// Keys sorted longest-first once — the match must prefer
    /// "gpt-5.6-terra" over "gpt-5", exactly like Hermes' step 8.
    private static let sortedKeys: [String] =
        defaultContextLengths.keys.sorted { $0.count > $1.count }

    /// Hermes step 8: longest-key-first substring lookup. nil = step 9
    /// (the caller's fallback).
    static func lookup(model: String) -> Int? {
        let lowered = model.lowercased()
        for key in sortedKeys where lowered.contains(key) {
            return defaultContextLengths[key]
        }
        return nil
    }

    /// Full client-side chain for a session's gauge denominator.
    /// `model` nil (nothing recorded for the session and no catalog yet)
    /// resolves as the agent's own model via the cached `/api/model/info`.
    static func limit(forModel model: String?, settings: HermesSettings) -> Int {
        if let model {
            // The gateway's own resolution wins when it covers this exact
            // model — it knows OAuth caps and config overrides we can't.
            if settings.agentContextModel == model, settings.agentContextLength > 0 {
                return settings.agentContextLength
            }
            if let table = lookup(model: model) { return table }
        } else if settings.agentContextLength > 0 {
            return settings.agentContextLength
        }
        return settings.contextLimitTokens
    }
}
