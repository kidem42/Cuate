package com.aispotlight.android.settings

import android.content.Context
import android.content.SharedPreferences
import com.aispotlight.android.core.ModelCapabilities
import com.aispotlight.android.core.ModelInfo
import com.aispotlight.android.core.ProviderID
import com.aispotlight.android.core.ReasoningMode
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONObject

/**
 * App settings backed by SharedPreferences, exposed as StateFlows for Compose.
 * The Android analog of `AppSettings.swift` (UserDefaults + @Published).
 */
class AppSettings private constructor(context: Context) {
    private val prefs: SharedPreferences =
        context.getSharedPreferences("settings", Context.MODE_PRIVATE)

    companion object {
        @Volatile private var instance: AppSettings? = null

        fun shared(context: Context): AppSettings =
            instance ?: synchronized(this) {
                instance ?: AppSettings(context.applicationContext).also { instance = it }
            }

        /** Valid once `shared(context)` has been called (App.onCreate). */
        val current: AppSettings get() = instance!!
    }

    // MARK: - Chat provider & models

    private val _chatProvider = MutableStateFlow(
        ProviderID.fromId(prefs.getString("chatProvider", null)) ?: ProviderID.ANTHROPIC
    )
    val chatProvider: StateFlow<ProviderID> = _chatProvider

    fun setChatProvider(value: ProviderID) {
        _chatProvider.value = value
        prefs.edit().putString("chatProvider", value.id).apply()
    }

    /** Selected model per provider (provider id → model id). */
    private val _selectedModels = MutableStateFlow(readStringMap("selectedModels"))
    val selectedModels: StateFlow<Map<String, String>> = _selectedModels

    fun selectedModel(provider: ProviderID): String? = _selectedModels.value[provider.id]

    fun setSelectedModel(provider: ProviderID, model: String) {
        _selectedModels.value = _selectedModels.value + (provider.id to model)
        writeStringMap("selectedModels", _selectedModels.value)
        if (provider == ProviderID.OPENROUTER) pushOpenRouterModel(model)
    }

    /** Cached fetched model lists per provider. */
    private val _cachedModels = MutableStateFlow(readStringListMap("cachedModels"))
    val cachedModels: StateFlow<Map<String, List<String>>> = _cachedModels

    fun setCachedModels(provider: ProviderID, models: List<String>) {
        _cachedModels.value = _cachedModels.value + (provider.id to models)
        writeStringListMap("cachedModels", _cachedModels.value)
        // Auto-select the best preferred default the provider actually serves —
        // matched exactly, or as the prefix of a dated snapshot id.
        if (selectedModel(provider) == null && models.isNotEmpty()) {
            val preferred = provider.preferredDefaultModels.firstNotNullOfOrNull { want ->
                models.firstOrNull { it == want } ?: models.firstOrNull { it.startsWith("$want-") }
            }
            setSelectedModel(provider, preferred ?: models.first())
        }
    }

    /** OpenRouter model catalog (slug → capabilities), for slug validation. */
    private val _openRouterCatalog = MutableStateFlow(readCatalog())
    val openRouterCatalog: StateFlow<Map<String, ModelInfo>> = _openRouterCatalog

    fun setOpenRouterCatalog(catalog: List<ModelInfo>) {
        _openRouterCatalog.value = catalog.associateBy { it.id }
        val json = JSONObject()
        for (info in catalog) {
            json.put(info.id, JSONObject().apply {
                put("vision", info.supportsVision)
                put("tools", info.supportsTools)
                put("reasoning", info.supportsReasoning)
                // Per-token USD prices for cost tracking (absent = unknown).
                info.promptPricePerToken?.let { put("promptPrice", it) }
                info.completionPricePerToken?.let { put("completionPrice", it) }
            })
        }
        prefs.edit().putString("openRouterCatalog", json.toString()).apply()
    }

    // MARK: - Capability resolution (per provider+model)

    fun modelSupportsVision(provider: ProviderID, model: String): Boolean {
        if (provider == ProviderID.OPENROUTER) {
            return _openRouterCatalog.value[model]?.supportsVision ?: false
        }
        return provider.supportsVision
    }

    fun modelSupportsTools(provider: ProviderID, model: String): Boolean {
        if (provider == ProviderID.OPENROUTER) {
            return _openRouterCatalog.value[model]?.supportsTools ?: false
        }
        return true
    }

    fun modelSupportsReasoningControl(provider: ProviderID, model: String): Boolean {
        if (provider == ProviderID.OPENROUTER) {
            return _openRouterCatalog.value[model]?.supportsReasoning ?: false
        }
        return ModelCapabilities.supportsReasoningControl(provider, model)
    }

    // MARK: - Chat options

    private val _reasoningMode = MutableStateFlow(ReasoningMode.fromId(prefs.getString("reasoningMode", null)))
    val reasoningMode: StateFlow<ReasoningMode> = _reasoningMode

    fun setReasoningMode(value: ReasoningMode) {
        _reasoningMode.value = value
        prefs.edit().putString("reasoningMode", value.id).apply()
    }

    private val _maxTokens = MutableStateFlow(prefs.getInt("maxTokens", 16384))
    val maxTokens: StateFlow<Int> = _maxTokens

    fun setMaxTokens(value: Int) {
        _maxTokens.value = value
        prefs.edit().putInt("maxTokens", value).apply()
    }

    /** Preferred STT provider (falls back to any configured one at call time). */
    private val _sttProvider = MutableStateFlow(
        com.aispotlight.android.providers.STTProviderID.fromId(prefs.getString("sttProvider", null))
    )
    val sttProvider: StateFlow<com.aispotlight.android.providers.STTProviderID> = _sttProvider

    fun setSttProvider(value: com.aispotlight.android.providers.STTProviderID) {
        _sttProvider.value = value
        prefs.edit().putString("sttProvider", value.id).apply()
    }

    private val _webSearchEnabled = MutableStateFlow(prefs.getBoolean("webSearchEnabled", true))
    val webSearchEnabled: StateFlow<Boolean> = _webSearchEnabled

    fun setWebSearchEnabled(value: Boolean) {
        _webSearchEnabled.value = value
        prefs.edit().putBoolean("webSearchEnabled", value).apply()
    }

    // MARK: - Hermes Agent addon

    /** Gateway endpoint, e.g. `http://100.x.y.z:8642` (Tailscale/LAN/VPS). */
    private val _hermesEndpoint = MutableStateFlow(prefs.getString("hermesEndpoint", "") ?: "")
    val hermesEndpoint: StateFlow<String> = _hermesEndpoint

    fun setHermesEndpoint(value: String) {
        _hermesEndpoint.value = value.trim()
        prefs.edit().putString("hermesEndpoint", value.trim()).apply()
    }

    /** Hermes dashboard server URL — the file-upload courier's target. */
    private val _hermesDashboardUrl = MutableStateFlow(prefs.getString("hermesDashboardUrl", "") ?: "")
    val hermesDashboardUrl: StateFlow<String> = _hermesDashboardUrl

    fun setHermesDashboardUrl(value: String) {
        _hermesDashboardUrl.value = value.trim()
        prefs.edit().putString("hermesDashboardUrl", value.trim()).apply()
    }

    /**
     * Model-lock pair for new sessions: "provider|model", or empty = the
     * agent's own current pair (from `/api/model/options` top level).
     */
    private val _hermesModelLock = MutableStateFlow(prefs.getString("hermesModelLock", "") ?: "")
    val hermesModelLock: StateFlow<String> = _hermesModelLock

    fun setHermesModelLock(value: String) {
        _hermesModelLock.value = value
        prefs.edit().putString("hermesModelLock", value).apply()
    }

    /** The Hermes role shows in the switcher only when an endpoint is configured. */
    val hermesConfigured: Boolean
        get() = _hermesEndpoint.value.isNotEmpty()

    /**
     * Hermes effort ladder (their composer's OPTIONS popover; desktop 1:1).
     * "" = don't send — the agent's own default. Rides per request as
     * `model_options.reasoning_effort`.
     */
    val hermesEffortLevels = listOf("", "minimal", "low", "medium", "high", "xhigh", "max", "ultra")

    /** Pinned sessions sort first in the sidebar (desktop hermes.pinnedSessions). */
    private val _hermesPinnedSessions = MutableStateFlow(
        prefs.getStringSet("hermesPinnedSessions", emptySet())!!.toSet()
    )
    val hermesPinnedSessions: StateFlow<Set<String>> = _hermesPinnedSessions

    fun toggleHermesSessionPin(sessionId: String) {
        val next = if (sessionId in _hermesPinnedSessions.value)
            _hermesPinnedSessions.value - sessionId else _hermesPinnedSessions.value + sessionId
        _hermesPinnedSessions.value = next
        prefs.edit().putStringSet("hermesPinnedSessions", next).apply()
    }

    /** Session accent colors, sessionId → hex (desktop hermes.sessionColors). */
    private val _hermesSessionColors = MutableStateFlow(readStringMap("hermesSessionColors"))
    val hermesSessionColors: StateFlow<Map<String, String>> = _hermesSessionColors

    fun setHermesSessionColor(sessionId: String, hex: String?) {
        val next = if (hex == null) _hermesSessionColors.value - sessionId
            else _hermesSessionColors.value + (sessionId to hex)
        _hermesSessionColors.value = next
        writeStringMap("hermesSessionColors", next)
    }

    /** Per-session reasoning effort ("" = agent default). */
    private val _hermesSessionEfforts = MutableStateFlow(readStringMap("hermesSessionEfforts"))
    val hermesSessionEfforts: StateFlow<Map<String, String>> = _hermesSessionEfforts

    fun setHermesSessionEffort(sessionId: String, effort: String) {
        val next = if (effort.isEmpty()) _hermesSessionEfforts.value - sessionId
            else _hermesSessionEfforts.value + (sessionId to effort)
        _hermesSessionEfforts.value = next
        writeStringMap("hermesSessionEfforts", next)
    }

    /** Last model lock applied to a session, "provider|model" (display state). */
    private val _hermesSessionModels = MutableStateFlow(readStringMap("hermesSessionModels"))
    val hermesSessionModels: StateFlow<Map<String, String>> = _hermesSessionModels

    fun setHermesSessionModel(sessionId: String, pair: String) {
        val next = _hermesSessionModels.value + (sessionId to pair)
        _hermesSessionModels.value = next
        writeStringMap("hermesSessionModels", next)
    }

    /**
     * Tool-call rounds one reply may spend (the desktop 3.20 "tool budget",
     * same 1–12 range and default). When it runs out the model is forced to
     * write its final answer from what it has gathered.
     */
    private val _maxToolIterations = MutableStateFlow(prefs.getInt("maxToolIterations", 4))
    val maxToolIterations: StateFlow<Int> = _maxToolIterations

    fun setMaxToolIterations(value: Int) {
        val clamped = value.coerceIn(1, 12)
        _maxToolIterations.value = clamped
        prefs.edit().putInt("maxToolIterations", clamped).apply()
    }

    /**
     * Keep photos from the last few messages in the request as pixels (not
     * just the newest one) so follow-up questions about an image still see it.
     * Costs extra vision input tokens per turn while a photo is in the window,
     * hence opt-in: OFF preserves the existing images-only-on-last behavior.
     */
    /** Open http(s) links in an in-app Custom Tab (default) or the external browser. */
    private val _openLinksInApp = MutableStateFlow(prefs.getBoolean("openLinksInApp", true))
    val openLinksInApp: StateFlow<Boolean> = _openLinksInApp

    fun setOpenLinksInApp(value: Boolean) {
        _openLinksInApp.value = value
        prefs.edit().putBoolean("openLinksInApp", value).apply()
    }

    private val _recentImagesAsPixels = MutableStateFlow(prefs.getBoolean("recentImagesAsPixels", false))
    val recentImagesAsPixels: StateFlow<Boolean> = _recentImagesAsPixels

    fun setRecentImagesAsPixels(value: Boolean) {
        _recentImagesAsPixels.value = value
        prefs.edit().putBoolean("recentImagesAsPixels", value).apply()
    }

    // MARK: - OpenRouter model history

    /** Recently applied OpenRouter slugs, most recent first (max 8). */
    private val _openRouterModelHistory = MutableStateFlow(
        prefs.getString("openRouterModelHistory", null)?.split('\n')?.filter { it.isNotEmpty() } ?: emptyList()
    )
    val openRouterModelHistory: StateFlow<List<String>> = _openRouterModelHistory

    fun pushOpenRouterModel(slug: String) {
        if (slug.isEmpty()) return
        val updated = (listOf(slug) + _openRouterModelHistory.value.filter { it != slug }).take(8)
        _openRouterModelHistory.value = updated
        prefs.edit().putString("openRouterModelHistory", updated.joinToString("\n")).apply()
    }

    // MARK: - STT models (per provider override)

    private val _sttModels = MutableStateFlow(readStringMap("sttModels"))
    val sttModels: StateFlow<Map<String, String>> = _sttModels

    fun sttModel(provider: com.aispotlight.android.providers.STTProviderID): String =
        _sttModels.value[provider.id] ?: provider.defaultModel

    fun setSttModel(provider: com.aispotlight.android.providers.STTProviderID, model: String) {
        _sttModels.value =
            if (model.isBlank()) _sttModels.value - provider.id
            else _sttModels.value + (provider.id to model.trim())
        writeStringMap("sttModels", _sttModels.value)
    }

    // MARK: - TTS (voice replies)

    /**
     * Voice replies: a voice message gets a spoken reply (with the transcript
     * below it). Default OFF so existing users' behavior doesn't change.
     */
    private val _voiceReplies = MutableStateFlow(prefs.getBoolean("voiceReplies", false))
    val voiceReplies: StateFlow<Boolean> = _voiceReplies

    fun setVoiceReplies(value: Boolean) {
        _voiceReplies.value = value
        prefs.edit().putBoolean("voiceReplies", value).apply()
    }

    /** Preferred TTS provider (falls back to any configured one at call time). */
    private val _ttsProvider = MutableStateFlow(
        com.aispotlight.android.providers.TTSProviderID.fromId(prefs.getString("ttsProvider", null))
    )
    val ttsProvider: StateFlow<com.aispotlight.android.providers.TTSProviderID> = _ttsProvider

    fun setTtsProvider(value: com.aispotlight.android.providers.TTSProviderID) {
        _ttsProvider.value = value
        prefs.edit().putString("ttsProvider", value.id).apply()
    }

    private val _ttsModels = MutableStateFlow(readStringMap("ttsModels"))
    val ttsModels: StateFlow<Map<String, String>> = _ttsModels

    fun ttsModel(provider: com.aispotlight.android.providers.TTSProviderID): String =
        _ttsModels.value[provider.id] ?: provider.defaultModel

    fun setTtsModel(provider: com.aispotlight.android.providers.TTSProviderID, model: String) {
        _ttsModels.value =
            if (model.isBlank()) _ttsModels.value - provider.id
            else _ttsModels.value + (provider.id to model.trim())
        writeStringMap("ttsModels", _ttsModels.value)
    }

    private val _ttsVoices = MutableStateFlow(readStringMap("ttsVoices"))
    val ttsVoices: StateFlow<Map<String, String>> = _ttsVoices

    fun ttsVoice(provider: com.aispotlight.android.providers.TTSProviderID): String =
        _ttsVoices.value[provider.id] ?: provider.defaultVoice

    fun setTtsVoice(provider: com.aispotlight.android.providers.TTSProviderID, voice: String) {
        _ttsVoices.value = _ttsVoices.value + (provider.id to voice)
        writeStringMap("ttsVoices", _ttsVoices.value)
    }

    /** Speaking speed, 0.5–2.0 (honored by OpenAI; Gemini has no speed knob). */
    private val _ttsSpeed = MutableStateFlow(prefs.getFloat("ttsSpeed", 1f))
    val ttsSpeed: StateFlow<Float> = _ttsSpeed

    fun setTtsSpeed(value: Float) {
        _ttsSpeed.value = value
        prefs.edit().putFloat("ttsSpeed", value).apply()
    }

    // MARK: - Image tools (fal.ai): model selection + cost tracking

    private fun defaultImageModel(function: com.aispotlight.android.providers.FalImageProvider.Function): String =
        com.aispotlight.android.providers.FalImageProvider.models(function).first().id

    private val _imageModels = MutableStateFlow(readStringMap("imageModels"))
    val imageModels: StateFlow<Map<String, String>> = _imageModels

    fun imageModel(function: com.aispotlight.android.providers.FalImageProvider.Function): String =
        _imageModels.value[function.name] ?: defaultImageModel(function)

    fun setImageModel(function: com.aispotlight.android.providers.FalImageProvider.Function, modelId: String) {
        _imageModels.value = _imageModels.value + (function.name to modelId)
        writeStringMap("imageModels", _imageModels.value)
    }

    private val _upscaleFactor = MutableStateFlow(prefs.getInt("upscaleFactor", 2))
    val upscaleFactor: StateFlow<Int> = _upscaleFactor

    fun setUpscaleFactor(value: Int) {
        _upscaleFactor.value = value
        prefs.edit().putInt("upscaleFactor", value).apply()
    }

    private val _faceEnhance = MutableStateFlow(prefs.getBoolean("faceEnhance", false))
    val faceEnhance: StateFlow<Boolean> = _faceEnhance

    fun setFaceEnhance(value: Boolean) {
        _faceEnhance.value = value
        prefs.edit().putBoolean("faceEnhance", value).apply()
    }

    /** Spending counters: this session (memory) and this calendar month (prefs). */
    private val _sessionCostUSD = MutableStateFlow(0.0)
    val sessionCostUSD: StateFlow<Double> = _sessionCostUSD

    private fun monthKey(): String {
        val calendar = java.util.Calendar.getInstance()
        return "falCost.%04d-%02d".format(
            calendar.get(java.util.Calendar.YEAR), calendar.get(java.util.Calendar.MONTH) + 1
        )
    }

    private val _monthCostUSD = MutableStateFlow(
        Double.fromBits(prefs.getLong(monthKey(), 0L))
    )
    val monthCostUSD: StateFlow<Double> = _monthCostUSD

    fun addImageCost(costUSD: Double) {
        _sessionCostUSD.value += costUSD
        _monthCostUSD.value = Double.fromBits(prefs.getLong(monthKey(), 0L)) + costUSD
        prefs.edit().putLong(monthKey(), _monthCostUSD.value.toRawBits()).apply()
    }

    // MARK: - Diagnostics

    private val _diagnosticsEnabled = MutableStateFlow(prefs.getBoolean("diagnosticsEnabled", false))
    val diagnosticsEnabled: StateFlow<Boolean> = _diagnosticsEnabled

    fun setDiagnosticsEnabled(value: Boolean) {
        _diagnosticsEnabled.value = value
        prefs.edit().putBoolean("diagnosticsEnabled", value).apply()
    }

    // MARK: - Appearance & themes

    enum class AppearanceMode(val id: String) {
        SYSTEM("system"), LIGHT("light"), DARK("dark");

        companion object {
            fun fromId(id: String?): AppearanceMode = entries.firstOrNull { it.id == id } ?: SYSTEM
        }
    }

    private val _appearanceMode = MutableStateFlow(AppearanceMode.fromId(prefs.getString("appearanceMode", null)))
    val appearanceMode: StateFlow<AppearanceMode> = _appearanceMode

    fun setAppearanceMode(value: AppearanceMode) {
        _appearanceMode.value = value
        prefs.edit().putString("appearanceMode", value.id).apply()
    }

    /** Decorative chat theme id (see ChatThemeID; "dynamic" = Material You). */
    private val _themeId = MutableStateFlow(prefs.getString("theme", null) ?: "dynamic")
    val themeId: StateFlow<String> = _themeId

    fun setThemeId(value: String) {
        _themeId.value = value
        prefs.edit().putString("theme", value).apply()
    }

    /** Auto-switch to Halloween (Oct 31) / Día de Muertos (Nov 1-2). On by default. */
    private val _holidayThemes = MutableStateFlow(prefs.getBoolean("holidayThemes", true))
    val holidayThemes: StateFlow<Boolean> = _holidayThemes

    fun setHolidayThemes(value: Boolean) {
        _holidayThemes.value = value
        prefs.edit().putBoolean("holidayThemes", value).apply()
    }

    /**
     * Holiday auto-theme, port of HolidayThemeManager: when a holiday starts
     * the user's theme is remembered and the holiday theme applied; when it
     * ends the saved theme is restored. A manual theme change during the
     * holiday wins — the manager backs off for that holiday occurrence.
     */
    fun reconcileHolidayTheme() {
        if (!_holidayThemes.value) return
        val calendar = java.util.Calendar.getInstance()
        val month = calendar.get(java.util.Calendar.MONTH) + 1
        val day = calendar.get(java.util.Calendar.DAY_OF_MONTH)
        val year = calendar.get(java.util.Calendar.YEAR)
        val holiday: Pair<String, String>? = when {
            month == 10 && day == 31 -> "halloween" to "halloween-$year"
            month == 11 && day in 1..2 -> "diaDeMuertos" to "dia-$year"
            else -> null
        }
        val appliedToken = prefs.getString("holidayAppliedToken", null)
        val overriddenToken = prefs.getString("holidayOverriddenToken", null)
        if (holiday != null) {
            val (theme, token) = holiday
            if (overriddenToken == token) return // user changed theme mid-holiday
            if (appliedToken != token) {
                if (_themeId.value == theme) return // already on it by choice
                prefs.edit()
                    .putString("holidaySavedTheme", _themeId.value)
                    .putString("holidayAppliedToken", token)
                    .apply()
                setThemeId(theme)
            } else if (_themeId.value != theme) {
                // Manual override during the holiday — back off until next year.
                prefs.edit()
                    .putString("holidayOverriddenToken", token)
                    .remove("holidayAppliedToken")
                    .apply()
            }
        } else if (appliedToken != null) {
            // Holiday over — hand the theme back.
            val saved = prefs.getString("holidaySavedTheme", null) ?: "dynamic"
            prefs.edit().remove("holidayAppliedToken").remove("holidaySavedTheme").apply()
            setThemeId(saved)
        }
    }

    // MARK: - System prompt & presets

    private val _systemPrompt = MutableStateFlow(
        prefs.getString("systemPrompt", null) ?: Presets.builtIn[0].text
    )
    /** The editable working copy of the system prompt. */
    val systemPrompt: StateFlow<String> = _systemPrompt

    fun setSystemPrompt(value: String) {
        _systemPrompt.value = value
        prefs.edit().putString("systemPrompt", value).apply()
    }

    private val _activePresetName = MutableStateFlow(
        prefs.getString("activePresetName", null) ?: Presets.builtIn[0].name
    )
    val activePresetName: StateFlow<String> = _activePresetName

    private val _customPresets = MutableStateFlow(readStringMap("customPresets"))
    val customPresets: StateFlow<Map<String, String>> = _customPresets

    /** Per-preset emoji icons (user overrides; built-in defaults come from Presets). */
    private val _presetIcons = MutableStateFlow(readStringMap("presetIcons"))
    val presetIcons: StateFlow<Map<String, String>> = _presetIcons

    fun setPresetIcon(name: String, icon: String) {
        _presetIcons.value =
            if (icon.isBlank()) _presetIcons.value - name
            else _presetIcons.value + (name to icon.trim().take(4))
        writeStringMap("presetIcons", _presetIcons.value)
    }

    fun presetIcon(name: String): String =
        _presetIcons.value[name]
            ?: Presets.builtIn.firstOrNull { it.name == name }?.icon
            ?: "✨"

    /** Presets hidden from the panel switcher (they stay in Settings). */
    private val _hiddenPresets = MutableStateFlow(
        prefs.getStringSet("hiddenPresets", emptySet())?.toSet() ?: emptySet()
    )
    val hiddenPresets: StateFlow<Set<String>> = _hiddenPresets

    fun setPresetHidden(name: String, hidden: Boolean) {
        _hiddenPresets.value =
            if (hidden) _hiddenPresets.value + name else _hiddenPresets.value - name
        prefs.edit().putStringSet("hiddenPresets", _hiddenPresets.value).apply()
    }

    /** Switcher style: preset menu in the top bar, or a chip row above the input. */
    enum class PresetSwitcherStyle(val id: String) {
        MENU("menu"), CHIPS("chips");

        companion object {
            fun fromId(id: String?): PresetSwitcherStyle = entries.firstOrNull { it.id == id } ?: MENU
        }
    }

    private val _presetSwitcherStyle = MutableStateFlow(
        PresetSwitcherStyle.fromId(prefs.getString("presetSwitcherStyle", null))
    )
    val presetSwitcherStyle: StateFlow<PresetSwitcherStyle> = _presetSwitcherStyle

    fun setPresetSwitcherStyle(value: PresetSwitcherStyle) {
        _presetSwitcherStyle.value = value
        prefs.edit().putString("presetSwitcherStyle", value.id).apply()
    }

    val allPresets: List<PromptPreset>
        get() = Presets.builtIn.map { it.copy(icon = presetIcon(it.name)) } +
            _customPresets.value.keys.sorted().map {
                PromptPreset(name = it, text = _customPresets.value[it] ?: "", isBuiltIn = false, icon = presetIcon(it))
            }

    /**
     * Presets the switcher offers: the non-hidden ones, plus the active
     * preset — the switcher must always be able to display its current state.
     */
    fun switcherPresets(activeName: String): List<PromptPreset> =
        allPresets.filter { it.name !in _hiddenPresets.value || it.name == activeName }

    fun presetText(name: String): String? =
        Presets.builtIn.firstOrNull { it.name == name }?.text ?: _customPresets.value[name]

    /**
     * Switches the active preset and loads its text as the working copy.
     * Re-activating the CURRENT preset (tapping its chip again, starting a
     * new chat on it) is a no-op — it must not stomp working-copy edits.
     */
    fun activatePreset(name: String) {
        if (name == _activePresetName.value) return
        val text = presetText(name) ?: return
        _activePresetName.value = name
        prefs.edit().putString("activePresetName", name).apply()
        setSystemPrompt(text)
    }

    /** Reverts the working copy to the active preset's original text (mac `resetPromptToPreset`). */
    fun resetPromptToPreset() {
        setSystemPrompt(presetText(_activePresetName.value) ?: Presets.builtIn[0].text)
    }

    /** Saves the current working copy under a (new or existing) custom preset name. */
    fun saveCurrentAsPreset(name: String) {
        val trimmed = name.trim()
        if (trimmed.isEmpty() || Presets.builtIn.any { it.name == trimmed }) return
        _customPresets.value = _customPresets.value + (trimmed to _systemPrompt.value)
        writeStringMap("customPresets", _customPresets.value)
        _activePresetName.value = trimmed
        prefs.edit().putString("activePresetName", trimmed).apply()
    }

    fun deletePreset(name: String) {
        _customPresets.value = _customPresets.value - name
        writeStringMap("customPresets", _customPresets.value)
        setPresetIsolated(name, false)
        if (_activePresetName.value == name) activatePreset(Presets.builtIn[0].name)
        // ChatViewModel reacts by deleting the preset's isolated chat data,
        // if any — the macOS `.presetDeleted` notification semantics.
        _presetDeleted.tryEmit(name)
    }

    /** Emits the name of a just-deleted preset (macOS `.presetDeleted`). */
    private val _presetDeleted = MutableSharedFlow<String>(extraBufferCapacity = 8)
    val presetDeleted: SharedFlow<String> = _presetDeleted

    // MARK: - Isolated preset chats

    /**
     * Presets with their own isolated conversation (port of `isolatedPresets`):
     * switching to such a preset switches to its dedicated chat — separate
     * history, context and rolling summary.
     */
    private val _isolatedPresets = MutableStateFlow(
        prefs.getStringSet("isolatedPresets", emptySet())?.toSet() ?: emptySet()
    )
    val isolatedPresets: StateFlow<Set<String>> = _isolatedPresets

    fun isPresetIsolated(name: String): Boolean = name in _isolatedPresets.value

    fun setPresetIsolated(name: String, isolated: Boolean) {
        _isolatedPresets.value =
            if (isolated) _isolatedPresets.value + name else _isolatedPresets.value - name
        prefs.edit().putStringSet("isolatedPresets", _isolatedPresets.value).apply()
    }

    /** Stable id of the shared general conversation (the mac "general" chat). */
    fun generalConversationId(): String? = prefs.getString("generalConversationId", null)

    fun setGeneralConversationId(id: String) {
        prefs.edit().putString("generalConversationId", id).apply()
    }

    /** Stable conversation id for an isolated preset's dedicated chat. */
    fun isolatedConversationId(presetName: String): String? =
        prefs.getString("isolatedConvId.$presetName", null)

    fun setIsolatedConversationId(presetName: String, conversationId: String) {
        prefs.edit().putString("isolatedConvId.$presetName", conversationId).apply()
    }

    fun clearIsolatedConversationId(presetName: String) {
        prefs.edit().remove("isolatedConvId.$presetName").apply()
    }

    // MARK: - JSON-in-prefs helpers

    private fun readStringMap(key: String): Map<String, String> {
        val raw = prefs.getString(key, null) ?: return emptyMap()
        return try {
            val json = JSONObject(raw)
            json.keys().asSequence().associateWith { json.getString(it) }
        } catch (_: Exception) {
            emptyMap()
        }
    }

    private fun writeStringMap(key: String, map: Map<String, String>) {
        val json = JSONObject()
        map.forEach { (k, v) -> json.put(k, v) }
        prefs.edit().putString(key, json.toString()).apply()
    }

    private fun readStringListMap(key: String): Map<String, List<String>> {
        val raw = prefs.getString(key, null) ?: return emptyMap()
        return try {
            val json = JSONObject(raw)
            json.keys().asSequence().associateWith { k ->
                val arr = json.getJSONArray(k)
                (0 until arr.length()).map { arr.getString(it) }
            }
        } catch (_: Exception) {
            emptyMap()
        }
    }

    private fun writeStringListMap(key: String, map: Map<String, List<String>>) {
        val json = JSONObject()
        map.forEach { (k, v) -> json.put(k, org.json.JSONArray(v)) }
        prefs.edit().putString(key, json.toString()).apply()
    }

    private fun readCatalog(): Map<String, ModelInfo> {
        val raw = prefs.getString("openRouterCatalog", null) ?: return emptyMap()
        return try {
            val json = JSONObject(raw)
            json.keys().asSequence().associateWith { id ->
                val entry = json.getJSONObject(id)
                ModelInfo(
                    id = id,
                    supportsVision = entry.optBoolean("vision"),
                    supportsTools = entry.optBoolean("tools"),
                    supportsReasoning = entry.optBoolean("reasoning"),
                    promptPricePerToken = if (entry.has("promptPrice")) entry.optDouble("promptPrice") else null,
                    completionPricePerToken = if (entry.has("completionPrice")) entry.optDouble("completionPrice") else null,
                )
            }
        } catch (_: Exception) {
            emptyMap()
        }
    }
}
