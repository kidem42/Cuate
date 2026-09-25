package com.aispotlight.android.settings
import com.aispotlight.android.core.*
import kotlinx.coroutines.flow.MutableStateFlow
object ApiKeyStore { fun key(provider: ProviderID): String? = "fixture" }
object Presets { val mandatoryPromptRules = "rules" }
class AppSettings {
 companion object { val current = AppSettings() }
 val chatProvider = MutableStateFlow(ProviderID.OPENAI)
 val maxToolIterations = MutableStateFlow(1)
 val systemPrompt = MutableStateFlow("instructions")
 val maxTokens = MutableStateFlow(1000)
 val reasoningMode = MutableStateFlow(ReasoningMode.AUTO)
 val compressionThreshold = MutableStateFlow(7000)
 val webSearchEnabled = MutableStateFlow(false)
 val openRouterWebSearch = MutableStateFlow(false)
 val openRouterWebFetch = MutableStateFlow(false)
 val openRouterZDROnly = MutableStateFlow(false)
 val recentImagesAsPixels = MutableStateFlow(false)
 val openRouterCatalog = MutableStateFlow<Map<String, ModelInfo>>(emptyMap())
 var model = "gpt-5.6"
 fun selectedModel(id: ProviderID): String? = model
 fun modelSupportsReasoningControl(id: ProviderID, model: String) = true
 fun modelSupportsTools(id: ProviderID, model: String) = true
 fun modelSupportsVision(id: ProviderID, model: String) = true
 fun modelSupportsNativeDocuments(id: ProviderID, model: String) = true
}
