package com.aispotlight.android.providers

import com.aispotlight.android.core.LLMProvider
import com.aispotlight.android.core.ProviderID

/** Maps a ProviderID to its implementation. */
object ProviderRegistry {
    private val anthropic = AnthropicProvider()
    private val gemini = GeminiProvider()

    fun provider(id: ProviderID): LLMProvider = AccountingProvider(rawProvider(id))

    private fun rawProvider(id: ProviderID): LLMProvider = when (id) {
        ProviderID.ANTHROPIC -> anthropic
        ProviderID.GEMINI -> gemini
        ProviderID.OPENAI -> OpenAICompatibleProvider.openAI
        ProviderID.MISTRAL -> OpenAICompatibleProvider.mistral
        ProviderID.DEEPSEEK -> OpenAICompatibleProvider.deepSeek
        ProviderID.OPENROUTER -> OpenAICompatibleProvider.openRouter
        ProviderID.KIMI -> OpenAICompatibleProvider.kimi
    }
}
