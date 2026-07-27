package com.aispotlight.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.outlined.BarChart
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.Key
import androidx.compose.material.icons.outlined.Mic
import androidx.compose.material.icons.outlined.Palette
import androidx.compose.material.icons.outlined.SmartToy
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.aispotlight.android.R
import com.aispotlight.android.core.ProviderID
import com.aispotlight.android.core.ReasoningMode
import com.aispotlight.android.providers.FalImageProvider as Fal
import com.aispotlight.android.providers.ProviderRegistry
import com.aispotlight.android.providers.STTProviderID
import com.aispotlight.android.providers.TTSProviderID
import com.aispotlight.android.settings.ApiKeyStore
import com.aispotlight.android.settings.AppSettings
import kotlinx.coroutines.launch

/**
 * Settings — the "Eclipse" design (claude.ai/design «Редизайн меню настроек
 * Eclipse»): glass card sections with hairline dividers on a radial near-black
 * (or warm cream) background, the app icon's eclipse orange as the single
 * accent. Structure stays the Android-16 pattern: a top-level category list
 * with icons and current values, each category opening a subpage. Same options
 * as the macOS SettingsView (chat / keys / voice / images / appearance /
 * prompts) including the live key validity checks.
 */

/** Key check state, port of SettingsView.KeyTestState. */
private sealed class KeyState {
    object Testing : KeyState()
    object Ok : KeyState()
    data class Failed(val reason: String) : KeyState()
}

private enum class SettingsTab { CHAT, KEYS, VOICE, IMAGES, HERMES, APPEARANCE, PROMPTS, COSTS }

private val SettingsTab.icon: ImageVector
    get() = when (this) {
        SettingsTab.CHAT -> Icons.Outlined.ChatBubbleOutline
        SettingsTab.KEYS -> Icons.Outlined.Key
        SettingsTab.VOICE -> Icons.Outlined.Mic
        SettingsTab.IMAGES -> Icons.Outlined.Image
        SettingsTab.APPEARANCE -> Icons.Outlined.Palette
        SettingsTab.PROMPTS -> Icons.Outlined.Description
        SettingsTab.COSTS -> Icons.Outlined.BarChart
        SettingsTab.HERMES -> Icons.Outlined.SmartToy
    }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val settings = AppSettings.shared(context)
    var subScreen by rememberSaveable { mutableStateOf<String?>(null) }
    val currentTab = subScreen?.let { name -> SettingsTab.entries.firstOrNull { it.name == name } }

    // System back pops the subpage before leaving settings.
    BackHandler(enabled = currentTab != null) { subScreen = null }

    // Settings wear their own Eclipse look, independent of the chat theme;
    // the System/Light/Dark appearance setting picks the palette (System
    // follows the OS).
    val appearanceMode by settings.appearanceMode.collectAsState()
    val eclipseDark = when (appearanceMode) {
        AppSettings.AppearanceMode.LIGHT -> false
        AppSettings.AppearanceMode.DARK -> true
        AppSettings.AppearanceMode.SYSTEM -> androidx.compose.foundation.isSystemInDarkTheme()
    }
    EclipseSettingsTheme(dark = eclipseDark) {
    val ecl = LocalEclipsePalette.current
    Scaffold(
        containerColor = Color.Transparent,
        modifier = Modifier.eclipseBackground(ecl),
        topBar = {
            TopAppBar(
                title = {
                    Text(currentTab?.let { tabTitle(it) } ?: stringResource(R.string.settings_title))
                },
                navigationIcon = {
                    IconButton(onClick = { if (currentTab != null) subScreen = null else onBack() }) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.action_back))
                    }
                },
                colors = androidx.compose.material3.TopAppBarDefaults.topAppBarColors(
                    containerColor = Color.Transparent,
                    titleContentColor = ecl.text,
                    navigationIconContentColor = ecl.text,
                ),
            )
        },
    ) { padding ->
        AnimatedContent(
            targetState = currentTab,
            transitionSpec = {
                if (targetState != null) {
                    (slideInHorizontally { it / 4 } + fadeIn()) togetherWith fadeOut()
                } else {
                    fadeIn() togetherWith (slideOutHorizontally { it / 4 } + fadeOut())
                }
            },
            label = "settingsNav",
            modifier = Modifier.padding(padding).fillMaxSize(),
        ) { tab ->
            Column(
                Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                when (tab) {
                    null -> SettingsHome(settings) { subScreen = it.name }
                    SettingsTab.CHAT -> ChatTab(settings)
                    SettingsTab.KEYS -> KeysTab(settings)
                    SettingsTab.VOICE -> VoiceTab(settings)
                    SettingsTab.IMAGES -> ImagesTab(settings)
                    SettingsTab.APPEARANCE -> AppearanceTab(settings)
                    SettingsTab.PROMPTS -> PromptsTab(settings)
                    SettingsTab.COSTS -> CostsTab(settings)
                    SettingsTab.HERMES -> HermesSection(settings)
                }
            }
        }
    }
    } // EclipseSettingsTheme
}

@Composable
private fun tabTitle(tab: SettingsTab): String = when (tab) {
    SettingsTab.CHAT -> stringResource(R.string.tab_chat)
    SettingsTab.KEYS -> stringResource(R.string.tab_keys)
    SettingsTab.VOICE -> stringResource(R.string.tab_voice)
    SettingsTab.IMAGES -> stringResource(R.string.tab_images)
    SettingsTab.APPEARANCE -> stringResource(R.string.tab_appearance)
    SettingsTab.PROMPTS -> stringResource(R.string.tab_prompts)
    SettingsTab.COSTS -> stringResource(R.string.tab_costs)
    SettingsTab.HERMES -> stringResource(R.string.hermes_section)
}

// MARK: - Home (category list with live value summaries)

@Composable
private fun SettingsHome(settings: AppSettings, onOpen: (SettingsTab) -> Unit) {
    val chatProvider by settings.chatProvider.collectAsState()
    val selectedModels by settings.selectedModels.collectAsState()
    val sttProvider by settings.sttProvider.collectAsState()
    val themeId by settings.themeId.collectAsState()
    val activePreset by settings.activePresetName.collectAsState()
    val appearanceMode by settings.appearanceMode.collectAsState()

    val chatSubtitle = listOfNotNull(
        chatProvider.displayName,
        selectedModels[chatProvider.id]?.substringAfterLast('/'),
    ).joinToString(" · ")
    val keysConfigured = ProviderID.entries.count { ApiKeyStore.hasKey(it) } +
        ApiKeyStore.AuxKey.entries.count { ApiKeyStore.hasAuxKey(it) }
    // Enriched value summaries (the Eclipse design's home rows).
    val voiceSubtitle = sttProvider.displayName + " · " + stringResource(R.string.home_voice_summary)
    val appearanceSubtitle = ChatThemeID.fromId(themeId).displayName + " · " + stringResource(
        when (appearanceMode) {
            AppSettings.AppearanceMode.SYSTEM -> R.string.appearance_system
            AppSettings.AppearanceMode.LIGHT -> R.string.appearance_light
            AppSettings.AppearanceMode.DARK -> R.string.appearance_dark
        }
    )

    SettingsGroup {
        item {
            SettingsNavRow(SettingsTab.CHAT.icon, tabTitle(SettingsTab.CHAT), chatSubtitle) { onOpen(SettingsTab.CHAT) }
        }
        item {
            SettingsNavRow(
                SettingsTab.KEYS.icon, tabTitle(SettingsTab.KEYS),
                stringResource(R.string.settings_keys_summary, keysConfigured),
            ) { onOpen(SettingsTab.KEYS) }
        }
        item {
            SettingsNavRow(SettingsTab.VOICE.icon, tabTitle(SettingsTab.VOICE), voiceSubtitle) { onOpen(SettingsTab.VOICE) }
        }
        item {
            SettingsNavRow(
                SettingsTab.IMAGES.icon, tabTitle(SettingsTab.IMAGES),
                if (ApiKeyStore.hasAuxKey(ApiKeyStore.AuxKey.FAL)) stringResource(R.string.home_images_summary)
                else stringResource(R.string.keys_missing),
            ) { onOpen(SettingsTab.IMAGES) }
        }
    }
    SettingsGroup {
        item {
            SettingsNavRow(
                SettingsTab.APPEARANCE.icon, tabTitle(SettingsTab.APPEARANCE),
                appearanceSubtitle,
            ) { onOpen(SettingsTab.APPEARANCE) }
        }
        item {
            SettingsNavRow(SettingsTab.PROMPTS.icon, tabTitle(SettingsTab.PROMPTS), activePreset) { onOpen(SettingsTab.PROMPTS) }
        }
        item {
            // Live month-total summary, like the other enriched home rows.
            val monthUSD by com.aispotlight.android.data.SpendTracker.monthUSD.collectAsState()
            SettingsNavRow(
                SettingsTab.COSTS.icon, tabTitle(SettingsTab.COSTS),
                stringResource(R.string.costs_month) + " · " +
                    com.aispotlight.android.data.SpendTracker.usd(monthUSD),
            ) { onOpen(SettingsTab.COSTS) }
        }
    }
    // The agent addon gets its own top-level category (its section used to
    // hide at the bottom of the Chat subpage — undiscoverable).
    SettingsGroup {
        item {
            val hermesEndpoint by settings.hermesEndpoint.collectAsState()
            SettingsNavRow(
                SettingsTab.HERMES.icon, tabTitle(SettingsTab.HERMES),
                hermesEndpoint.ifEmpty { stringResource(R.string.hermes_not_configured) },
            ) { onOpen(SettingsTab.HERMES) }
        }
    }
    // App version, visible right on the settings home (it used to hide at
    // the bottom of the Chat subpage).
    val context = LocalContext.current
    val packageInfo = remember {
        context.packageManager.getPackageInfo(context.packageName, 0)
    }
    val versionCode = remember(packageInfo) {
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P) {
            packageInfo.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            packageInfo.versionCode.toLong()
        }
    }
    SettingsFootnote(
        stringResource(R.string.settings_version, packageInfo.versionName ?: "?", versionCode)
    )
}

// MARK: - Chat tab (provider, model, parameters)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ChatTab(settings: AppSettings) {
    val scope = rememberCoroutineScope()
    val chatProvider by settings.chatProvider.collectAsState()
    val selectedModels by settings.selectedModels.collectAsState()
    val cachedModels by settings.cachedModels.collectAsState()
    val reasoningMode by settings.reasoningMode.collectAsState()
    val webSearchEnabled by settings.webSearchEnabled.collectAsState()
    val maxTokens by settings.maxTokens.collectAsState()
    var status by remember { mutableStateOf<String?>(null) }
    val hasKey = ApiKeyStore.hasKey(chatProvider)
    val modelsFailedTemplate = stringResource(R.string.settings_models_failed, "%s")

    Column {
        SettingsGroup(stringResource(R.string.settings_provider)) {
            item { ProviderDropdown(selected = chatProvider, onSelect = { settings.setChatProvider(it) }) }
        }
        if (!hasKey) {
            SettingsFootnote(stringResource(R.string.settings_no_key, chatProvider.apiKeyURL), isError = true)
        }
    }

    Column {
        SettingsGroup(stringResource(R.string.settings_model)) {
            if (chatProvider.usesManualModelEntry) {
                // OpenRouter: free slug entry (catalog validates in ChatService).
                item {
                    var slug by rememberSaveable(chatProvider) {
                        mutableStateOf(selectedModels[chatProvider.id] ?: "")
                    }
                    Column {
                        OutlinedTextField(
                            value = slug,
                            onValueChange = { slug = it },
                            modifier = Modifier.fillMaxWidth(),
                            label = { Text(stringResource(R.string.settings_model_slug)) },
                            singleLine = true,
                            colors = eclipseFieldColors(),
                        )
                        EclipseTextButton(stringResource(R.string.settings_apply_model), onClick = {
                            settings.setSelectedModel(chatProvider, slug.trim())
                            // Keep the capability catalog fresh (the endpoint is public).
                            scope.launch {
                                try {
                                    settings.setOpenRouterCatalog(
                                        com.aispotlight.android.providers.OpenAICompatibleProvider
                                            .openRouter.fetchModelCatalog(ApiKeyStore.key(ProviderID.OPENROUTER))
                                    )
                                } catch (_: Exception) { /* offline — validated on next apply */ }
                            }
                        })
                        // Recently used slugs — one tap to switch back.
                        val history by settings.openRouterModelHistory.collectAsState()
                        if (history.isNotEmpty()) {
                            Row(
                                horizontalArrangement = Arrangement.spacedBy(6.dp),
                                modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                            ) {
                                for (pastSlug in history) {
                                    EclipseChip(
                                        label = pastSlug,
                                        selected = pastSlug == selectedModels[chatProvider.id],
                                        onClick = {
                                            slug = pastSlug
                                            settings.setSelectedModel(chatProvider, pastSlug)
                                        },
                                    )
                                }
                            }
                        }
                    }
                }
            } else {
                item {
                    Column {
                        ModelDropdown(
                            models = cachedModels[chatProvider.id] ?: emptyList(),
                            selected = selectedModels[chatProvider.id],
                            onSelect = { settings.setSelectedModel(chatProvider, it) },
                        )
                        EclipseTextButton(
                            stringResource(R.string.settings_refresh_models),
                            enabled = hasKey,
                            onClick = {
                                scope.launch {
                                    try {
                                        val key = ApiKeyStore.key(chatProvider) ?: return@launch
                                        settings.setCachedModels(chatProvider, ProviderRegistry.provider(chatProvider).fetchModels(key))
                                        status = null
                                    } catch (e: Exception) {
                                        status = modelsFailedTemplate.format(e.message ?: "")
                                    }
                                }
                            },
                        )
                    }
                }
            }
        }
        status?.let { SettingsFootnote(it, isError = true) }
    }

    SettingsGroup(stringResource(R.string.settings_reasoning)) {
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for (mode in ReasoningMode.entries) {
                    EclipseChip(
                        label = stringResource(when (mode) {
                            ReasoningMode.AUTO -> R.string.reasoning_auto
                            ReasoningMode.FAST -> R.string.reasoning_fast
                            ReasoningMode.DEEP -> R.string.reasoning_deep
                        }),
                        selected = reasoningMode == mode,
                        onClick = { settings.setReasoningMode(mode) },
                    )
                }
            }
        }
    }

    Column {
        val maxToolIterations by settings.maxToolIterations.collectAsState()
        SettingsGroup(stringResource(R.string.settings_web_search)) {
            item {
                SettingsSwitchRow(
                    title = stringResource(R.string.settings_web_search_enable),
                    checked = webSearchEnabled,
                    onCheckedChange = { settings.setWebSearchEnabled(it) },
                )
            }
            // Tool budget (desktop 3.20): rounds of tool calls one reply may
            // spend before the model must write its final answer.
            item {
                Column(Modifier.fillMaxWidth().padding(top = 4.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            stringResource(R.string.settings_tool_budget),
                            style = MaterialTheme.typography.bodyMedium,
                            modifier = Modifier.weight(1f),
                        )
                        Text(
                            "$maxToolIterations",
                            style = MaterialTheme.typography.bodyMedium,
                            fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                        )
                    }
                    androidx.compose.material3.Slider(
                        value = maxToolIterations.toFloat(),
                        onValueChange = { settings.setMaxToolIterations(it.toInt()) },
                        valueRange = 1f..12f,
                        steps = 10,
                    )
                    Text(
                        stringResource(R.string.settings_tool_budget_hint),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
        if (!ApiKeyStore.hasAuxKey(ApiKeyStore.AuxKey.BRAVE)) {
            SettingsFootnote(stringResource(R.string.settings_web_needs_key))
        }
    }

    // Opt-in: photos from recent messages stay in the request as pixels
    // (see ChatService.RECENT_PIXEL_WINDOW). Off by default — recurring
    // vision-token cost must not appear silently for existing users.
    val recentImagesAsPixels by settings.recentImagesAsPixels.collectAsState()
    SettingsGroup(stringResource(R.string.settings_recent_images)) {
        item {
            SettingsSwitchRow(
                title = stringResource(R.string.settings_recent_images_enable),
                checked = recentImagesAsPixels,
                onCheckedChange = { settings.setRecentImagesAsPixels(it) },
                subtitle = stringResource(R.string.settings_recent_images_hint),
            )
        }
    }

    // Links: in-app Custom Tab (default) vs the external browser.
    val openLinksInApp by settings.openLinksInApp.collectAsState()
    SettingsGroup(stringResource(R.string.settings_links)) {
        item {
            SettingsSwitchRow(
                title = stringResource(R.string.settings_links_in_app),
                checked = openLinksInApp,
                onCheckedChange = { settings.setOpenLinksInApp(it) },
                subtitle = stringResource(R.string.settings_links_in_app_hint),
            )
        }
    }

    SettingsGroup(stringResource(R.string.settings_max_tokens)) {
        item {
            var maxTokensDraft by rememberSaveable(maxTokens) { mutableStateOf(maxTokens.toString()) }
            OutlinedTextField(
                value = maxTokensDraft,
                onValueChange = { value ->
                    maxTokensDraft = value.filter { it.isDigit() }
                    maxTokensDraft.toIntOrNull()?.let { tokens ->
                        if (tokens in 256..128_000) settings.setMaxTokens(tokens)
                    }
                },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
                textStyle = MaterialTheme.typography.bodyMedium.copy(
                    fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                ),
                colors = eclipseFieldColors(),
            )
        }
    }

    // Diagnostics: local log, opt-in (port of the mac diagnostics section).
    val diagnosticsEnabled by settings.diagnosticsEnabled.collectAsState()
    val context = LocalContext.current
    SettingsGroup(stringResource(R.string.settings_diagnostics)) {
        item {
            SettingsSwitchRow(
                title = stringResource(R.string.settings_diagnostics_enable),
                checked = diagnosticsEnabled,
                onCheckedChange = {
                    settings.setDiagnosticsEnabled(it)
                    com.aispotlight.android.core.Diagnostics.setEnabled(it)
                },
            )
        }
        item {
            EclipseTextButton(
                stringResource(R.string.settings_diagnostics_share),
                enabled = com.aispotlight.android.core.Diagnostics.logFile() != null,
                onClick = {
                    val file = com.aispotlight.android.core.Diagnostics.logFile() ?: return@EclipseTextButton
                    val intent = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
                        type = "text/plain"
                        putExtra(android.content.Intent.EXTRA_TEXT, file.readText().takeLast(50_000))
                    }
                    context.startActivity(android.content.Intent.createChooser(intent, "diagnostics.log"))
                },
            )
        }
    }

    // App version — answers "which build am I on" without leaving the app.
    // Read from PackageManager: BuildConfig generation is disabled.
    val packageInfo = remember {
        context.packageManager.getPackageInfo(context.packageName, 0)
    }
    val versionCode = remember(packageInfo) {
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P) {
            packageInfo.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            packageInfo.versionCode.toLong()
        }
    }
    SettingsFootnote(
        stringResource(R.string.settings_version, packageInfo.versionName ?: "?", versionCode)
    )
}

// MARK: - Keys tab (all providers with live validity checks)

/** One-line purpose blurb under each provider's name (Eclipse design). */
@Composable
private fun providerKeyDesc(provider: ProviderID): String = stringResource(
    when (provider) {
        ProviderID.ANTHROPIC -> R.string.key_desc_anthropic
        ProviderID.OPENAI -> R.string.key_desc_openai
        ProviderID.GEMINI -> R.string.key_desc_gemini
        ProviderID.MISTRAL -> R.string.key_desc_mistral
        ProviderID.DEEPSEEK -> R.string.key_desc_deepseek
        ProviderID.OPENROUTER -> R.string.key_desc_openrouter
        ProviderID.KIMI -> R.string.key_desc_kimi
    }
)

@Composable
private fun KeysTab(settings: AppSettings) {
    val scope = rememberCoroutineScope()
    // Per-provider check state — the mac keysSection's testing/ok/failed dots.
    val keyStates = remember { mutableStateMapOf<String, KeyState>() }
    // ApiKeyStore isn't observable — bump to re-read after save/delete.
    var refresh by remember { mutableStateOf(0) }

    SettingsGroup(stringResource(R.string.keys_chat_header)) {
        for (provider in ProviderID.entries) {
            item {
                ProviderKeyRow(
                    title = provider.displayName,
                    description = providerKeyDesc(provider),
                    badge = provider.badgeLetter,
                    badgeColor = Color(provider.brandColor),
                    hasKey = refresh >= 0 && ApiKeyStore.hasKey(provider),
                    maskedKey = if (refresh >= 0) maskKey(ApiKeyStore.key(provider)) else null,
                    state = keyStates[provider.id],
                    keyUrl = provider.apiKeyURL,
                    onDelete = {
                        ApiKeyStore.setKey(provider, null)
                        keyStates.remove(provider.id)
                        refresh++
                    },
                    onSave = { key ->
                        keyStates[provider.id] = KeyState.Testing
                        scope.launch {
                            try {
                                ProviderRegistry.provider(provider).validateKey(key)
                                ApiKeyStore.setKey(provider, key)
                                keyStates[provider.id] = KeyState.Ok
                                refresh++
                                if (provider == ProviderID.OPENROUTER) {
                                    // OpenRouter capabilities are per-model: refresh the
                                    // catalog so tools/vision/reasoning resolve correctly.
                                    try {
                                        settings.setOpenRouterCatalog(
                                            com.aispotlight.android.providers.OpenAICompatibleProvider
                                                .openRouter.fetchModelCatalog(key)
                                        )
                                    } catch (_: Exception) { /* refreshed on next model apply */ }
                                } else {
                                    // Fetch models right away — auto-selects a default.
                                    try {
                                        settings.setCachedModels(
                                            provider, ProviderRegistry.provider(provider).fetchModels(key)
                                        )
                                    } catch (_: Exception) { /* list is refreshable later */ }
                                }
                            } catch (e: Exception) {
                                keyStates[provider.id] = KeyState.Failed(e.message ?: "")
                            }
                        }
                    },
                )
            }
        }
    }

    Column {
        SettingsGroup(stringResource(R.string.keys_services_header)) {
            // Deepgram is STT-only; Brave powers web search; fal.ai the image tools.
            item {
                AuxKeyRow(
                    "Deepgram", stringResource(R.string.key_desc_deepgram),
                    "D", Color(0xFF13EF95), ApiKeyStore.AuxKey.DEEPGRAM, keyStates,
                )
            }
            item {
                AuxKeyRow(
                    "Brave Search", stringResource(R.string.key_desc_brave),
                    "B", Color(0xFFFB542B), ApiKeyStore.AuxKey.BRAVE, keyStates,
                )
            }
            item {
                AuxKeyRow(
                    "fal.ai", stringResource(R.string.key_desc_fal),
                    "F", Color(0xFF6C4EF6), ApiKeyStore.AuxKey.FAL, keyStates,
                )
            }
        }
        SettingsFootnote(stringResource(R.string.settings_fal_note))
    }
}

/** `sk-ant-a…3fQx` — enough of the stored key to tell WHICH one is saved. */
private fun maskKey(raw: String?): String? {
    if (raw.isNullOrBlank()) return null
    val trimmed = raw.trim()
    return if (trimmed.length <= 12) {
        trimmed.take(3) + "…"
    } else {
        trimmed.take(8) + "…" + trimmed.takeLast(4)
    }
}

/**
 * One provider row, Eclipse-style: badge + name + purpose blurb, the masked
 * key on its own monospace line when saved, live status icon, and a trash
 * button to delete the key. Without a key the row shows a «+ Добавить»
 * outline chip that expands into the entry field with a gradient verify
 * button; tapping a saved row also opens the field (key replacement).
 */
@Composable
private fun ProviderKeyRow(
    title: String,
    description: String,
    badge: String,
    badgeColor: Color,
    hasKey: Boolean,
    maskedKey: String?,
    state: KeyState?,
    keyUrl: String,
    onSave: (String) -> Unit,
    onDelete: () -> Unit,
) {
    val ecl = LocalEclipsePalette.current
    var input by rememberSaveable(title) { mutableStateOf("") }
    var editing by rememberSaveable(title) { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            // A saved row opens the entry field on tap — key replacement
            // without deleting first.
            modifier = if (hasKey) Modifier.clickable { editing = !editing } else Modifier,
        ) {
            // Brand badge — the mac provider icon without logo assets.
            EclipseBadge(badge, badgeColor)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(title, color = ecl.text, style = MaterialTheme.typography.bodyLarge)
                Text(description, style = MaterialTheme.typography.bodySmall, color = ecl.sub)
                // Masked stored key — identifies WHICH key is saved.
                if (maskedKey != null) {
                    Text(
                        maskedKey,
                        style = MaterialTheme.typography.labelSmall.copy(
                            fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                        ),
                        color = ecl.sub.copy(alpha = 0.75f),
                        modifier = Modifier.padding(top = 2.dp),
                    )
                }
            }
            Spacer(Modifier.width(8.dp))
            KeyStatusIcon(state, hasKey)
            if (hasKey) {
                Spacer(Modifier.width(10.dp))
                // Trash in a red-outlined circle (the design's delete affordance).
                Box(
                    Modifier
                        .size(32.dp)
                        .border(1.dp, ecl.deleteBorder, CircleShape)
                        .clip(CircleShape)
                        .clickable { editing = false; onDelete() },
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        Icons.Outlined.Delete,
                        contentDescription = stringResource(R.string.keys_delete),
                        tint = ecl.delete,
                        modifier = Modifier.size(16.dp),
                    )
                }
            } else if (!editing && state != KeyState.Testing) {
                Spacer(Modifier.width(10.dp))
                EclipseOutlineButton(stringResource(R.string.keys_add), onClick = { editing = true })
            }
        }
        if (editing || (!hasKey && state is KeyState.Failed)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(
                    value = input,
                    onValueChange = { input = it },
                    modifier = Modifier.weight(1f),
                    label = {
                        Text(stringResource(if (hasKey) R.string.settings_key_saved else R.string.settings_api_key))
                    },
                    singleLine = true,
                    visualTransformation = PasswordVisualTransformation(),
                    colors = eclipseFieldColors(),
                )
                Spacer(Modifier.width(8.dp))
                EclipsePrimaryButton(
                    stringResource(R.string.keys_check),
                    enabled = input.isNotBlank() && state != KeyState.Testing,
                    onClick = {
                        onSave(input.trim())
                        input = ""
                        editing = false
                    },
                )
            }
        }
        if (state is KeyState.Failed) {
            Text(
                stringResource(R.string.settings_key_failed, state.reason),
                style = MaterialTheme.typography.bodySmall,
                color = ecl.delete,
            )
        }
        if (!hasKey && editing && state == null && keyUrl.isNotEmpty()) {
            Text(keyUrl, style = MaterialTheme.typography.bodySmall, color = ecl.sub)
        }
    }
}

/** ✓ / ✗ / spinner — the key row's live status. */
@Composable
private fun KeyStatusIcon(state: KeyState?, hasKey: Boolean) {
    val ecl = LocalEclipsePalette.current
    when (state) {
        KeyState.Testing -> CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = ecl.accent)
        KeyState.Ok -> Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = ecl.ok)
        is KeyState.Failed -> Icon(Icons.Filled.Error, contentDescription = null, tint = ecl.delete)
        null -> if (hasKey) {
            Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = ecl.ok.copy(alpha = 0.7f))
        }
    }
}

@Composable
private fun AuxKeyRow(
    title: String,
    description: String,
    badge: String,
    badgeColor: Color,
    aux: ApiKeyStore.AuxKey,
    keyStates: androidx.compose.runtime.snapshots.SnapshotStateMap<String, KeyState>,
) {
    var refresh by remember { mutableStateOf(0) }
    ProviderKeyRow(
        title = title,
        description = description,
        badge = badge,
        badgeColor = badgeColor,
        hasKey = refresh >= 0 && ApiKeyStore.hasAuxKey(aux),
        maskedKey = if (refresh >= 0) maskKey(ApiKeyStore.auxKey(aux)) else null,
        state = keyStates["aux." + aux.id],
        keyUrl = "",
        onDelete = {
            ApiKeyStore.setAuxKey(aux, null)
            keyStates.remove("aux." + aux.id)
            refresh++
        },
        onSave = { key ->
            ApiKeyStore.setAuxKey(aux, key)
            keyStates["aux." + aux.id] = KeyState.Ok
            refresh++
        },
    )
}

// MARK: - Voice tab

@Composable
private fun VoiceTab(settings: AppSettings) {
    val sttProvider by settings.sttProvider.collectAsState()
    val sttModels by settings.sttModels.collectAsState()

    Column {
        SettingsGroup(stringResource(R.string.settings_stt)) {
            item {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    for (provider in STTProviderID.entries) {
                        EclipseChip(
                            label = provider.displayName,
                            selected = sttProvider == provider,
                            onClick = { settings.setSttProvider(provider) },
                        )
                    }
                }
            }
        }
        SettingsFootnote(stringResource(R.string.settings_stt_note))
    }

    // Per-provider readiness + model override (defaults from STTProviderID).
    val ecl = LocalEclipsePalette.current
    SettingsGroup {
        for (provider in STTProviderID.entries) {
            item {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(provider.displayName, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge, color = ecl.text)
                        if (provider.hasKey) {
                            Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = ecl.ok, modifier = Modifier.size(18.dp))
                        } else {
                            Text(
                                stringResource(R.string.keys_missing),
                                style = MaterialTheme.typography.bodySmall,
                                color = ecl.sub,
                            )
                        }
                    }
                    var modelDraft by rememberSaveable(provider) {
                        mutableStateOf(sttModels[provider.id] ?: "")
                    }
                    OutlinedTextField(
                        value = modelDraft,
                        onValueChange = {
                            modelDraft = it
                            settings.setSttModel(provider, it)
                        },
                        modifier = Modifier.fillMaxWidth(),
                        label = { Text(stringResource(R.string.settings_stt_model, provider.defaultModel)) },
                        singleLine = true,
                        colors = eclipseFieldColors(),
                    )
                }
            }
        }
    }

    // Voice replies (TTS): a voice message gets a spoken reply back, with the
    // transcript below the player. OpenAI exposes voice + speed (+ style on
    // gpt-4o-mini-tts); Gemini exposes voice only — the speed slider hides.
    val voiceReplies by settings.voiceReplies.collectAsState()
    val ttsProvider by settings.ttsProvider.collectAsState()
    val ttsModels by settings.ttsModels.collectAsState()
    val ttsVoices by settings.ttsVoices.collectAsState()
    val ttsSpeed by settings.ttsSpeed.collectAsState()

    Column {
        SettingsGroup(stringResource(R.string.settings_tts)) {
            item {
                SettingsSwitchRow(
                    title = stringResource(R.string.settings_voice_replies),
                    checked = voiceReplies,
                    onCheckedChange = { settings.setVoiceReplies(it) },
                )
            }
            if (voiceReplies) {
                item {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        for (provider in TTSProviderID.entries) {
                            EclipseChip(
                                label = provider.displayName,
                                selected = ttsProvider == provider,
                                onClick = { settings.setTtsProvider(provider) },
                            )
                            if (provider == ttsProvider && provider.hasKey) {
                                Icon(
                                    Icons.Filled.CheckCircle, contentDescription = null,
                                    tint = ecl.ok,
                                    modifier = Modifier.size(18.dp).align(Alignment.CenterVertically),
                                )
                            }
                        }
                        if (!ttsProvider.hasKey) {
                            Text(
                                stringResource(R.string.keys_missing),
                                style = MaterialTheme.typography.bodySmall,
                                color = ecl.sub,
                                modifier = Modifier.align(Alignment.CenterVertically),
                            )
                        }
                    }
                }
                item {
                    var modelDraft by rememberSaveable(ttsProvider) {
                        mutableStateOf(ttsModels[ttsProvider.id] ?: "")
                    }
                    OutlinedTextField(
                        value = modelDraft,
                        onValueChange = {
                            modelDraft = it
                            settings.setTtsModel(ttsProvider, it)
                        },
                        modifier = Modifier.fillMaxWidth(),
                        label = { Text(stringResource(R.string.settings_stt_model, ttsProvider.defaultModel)) },
                        singleLine = true,
                        colors = eclipseFieldColors(),
                    )
                }
                item {
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(
                            stringResource(R.string.settings_tts_voice),
                            style = MaterialTheme.typography.bodyMedium,
                            color = ecl.text,
                        )
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                            modifier = Modifier.horizontalScroll(rememberScrollState()),
                        ) {
                            val selectedVoice = ttsVoices[ttsProvider.id] ?: ttsProvider.defaultVoice
                            for (voice in ttsProvider.voices) {
                                EclipseChip(
                                    label = voice,
                                    selected = selectedVoice == voice,
                                    onClick = { settings.setTtsVoice(ttsProvider, voice) },
                                )
                            }
                        }
                    }
                }
                if (ttsProvider.supportsSpeed) {
                    item {
                        Column {
                            Text(
                                stringResource(R.string.settings_tts_speed, "%.2f".format(ttsSpeed)),
                                style = MaterialTheme.typography.bodyMedium,
                                color = ecl.text,
                            )
                            EclipseSlider(
                                value = ttsSpeed,
                                onValueChange = { settings.setTtsSpeed(it) },
                                valueRange = 0.5f..2f,
                                steps = 5,
                            )
                        }
                    }
                }
            }
        }
        SettingsFootnote(stringResource(R.string.settings_voice_replies_note))
    }
}

// MARK: - Images tab (fal.ai model catalog, ТЗ §3.1)

@Composable
private fun ImagesTab(settings: AppSettings) {
    val imageModels by settings.imageModels.collectAsState()
    val upscaleFactor by settings.upscaleFactor.collectAsState()
    val faceEnhance by settings.faceEnhance.collectAsState()
    val sessionCost by settings.sessionCostUSD.collectAsState()
    val monthCost by settings.monthCostUSD.collectAsState()

    if (!ApiKeyStore.hasAuxKey(ApiKeyStore.AuxKey.FAL)) {
        SettingsFootnote(stringResource(R.string.images_needs_key), isError = true)
    }

    val ecl = LocalEclipsePalette.current
    // Not @Composable itself: it only REGISTERS item lambdas on the group —
    // they execute later inside SettingsGroup's composable loop.
    fun SettingsGroupScope.modelPickerItems(function: Fal.Function) {
        val selected = imageModels[function.name] ?: Fal.models(function).first().id
        for (model in Fal.models(function)) {
            item {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    EclipseChip(
                        label = model.name,
                        selected = selected == model.id,
                        onClick = { settings.setImageModel(function, model.id) },
                    )
                    Spacer(Modifier.weight(1f))
                    Text(
                        model.priceLabel,
                        style = MaterialTheme.typography.labelSmall,
                        color = ecl.sub,
                    )
                }
            }
        }
    }

    SettingsGroup(stringResource(R.string.images_upscale_model)) {
        modelPickerItems(Fal.Function.UPSCALE)
        // Upscale factor + face enhance (honored by models that support them).
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.images_factor), Modifier.weight(1f), color = ecl.text)
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    for (factor in listOf(2, 4, 8)) {
                        EclipseChip(
                            label = "×$factor",
                            selected = upscaleFactor == factor,
                            onClick = { settings.setUpscaleFactor(factor) },
                        )
                    }
                }
            }
        }
        item {
            SettingsSwitchRow(
                title = stringResource(R.string.images_face_enhance),
                checked = faceEnhance,
                onCheckedChange = { settings.setFaceEnhance(it) },
            )
        }
    }

    SettingsGroup(stringResource(R.string.images_bg_model)) {
        modelPickerItems(Fal.Function.REMOVE_BACKGROUND)
    }

    Column {
        SettingsGroup(stringResource(R.string.images_cleanup_model)) {
            modelPickerItems(Fal.Function.OBJECT_CLEANUP)
        }
        SettingsFootnote(stringResource(R.string.images_cleanup_note))
    }

    // Spending counters — the mac session/month cost display.
    Column {
        SettingsGroup(stringResource(R.string.images_costs)) {
            item {
                Text(
                    stringResource(R.string.images_costs_value, "%.3f".format(sessionCost), "%.3f".format(monthCost)),
                    style = MaterialTheme.typography.bodyMedium,
                    color = ecl.text,
                )
            }
        }
        SettingsFootnote(stringResource(R.string.images_slash_hint))
    }
}

// MARK: - Appearance tab

@Composable
private fun AppearanceTab(settings: AppSettings) {
    val themeId by settings.themeId.collectAsState()
    val appearanceMode by settings.appearanceMode.collectAsState()
    val holidayThemes by settings.holidayThemes.collectAsState()

    // Theme grid with live mini-previews (port of the mac ThemeGridPicker):
    // each thumbnail renders the theme's real palette — background, a bubble
    // pair and the send accent — so the user picks by look, not by name.
    // Previews follow the app's appearance setting, not just the system.
    val gridDark = when (appearanceMode) {
        AppSettings.AppearanceMode.LIGHT -> false
        AppSettings.AppearanceMode.DARK -> true
        AppSettings.AppearanceMode.SYSTEM -> androidx.compose.foundation.isSystemInDarkTheme()
    }
    Column {
        SettingsGroup(stringResource(R.string.settings_theme)) {
            item {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    for (row in ChatThemeID.entries.chunked(3)) {
                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                            for (theme in row) {
                                ThemeThumbnailCell(
                                    theme = theme,
                                    dark = gridDark,
                                    selected = themeId == theme.id,
                                    onClick = { settings.setThemeId(theme.id) },
                                    modifier = Modifier.weight(1f),
                                )
                            }
                            repeat(3 - row.size) { Spacer(Modifier.weight(1f)) }
                        }
                    }
                }
            }
        }
        // Chat themes style the conversation only — settings keep Eclipse.
        SettingsFootnote(stringResource(R.string.settings_theme_note))
    }

    SettingsGroup(stringResource(R.string.settings_appearance)) {
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for (mode in AppSettings.AppearanceMode.entries) {
                    EclipseChip(
                        label = stringResource(when (mode) {
                            AppSettings.AppearanceMode.SYSTEM -> R.string.appearance_system
                            AppSettings.AppearanceMode.LIGHT -> R.string.appearance_light
                            AppSettings.AppearanceMode.DARK -> R.string.appearance_dark
                        }),
                        selected = appearanceMode == mode,
                        onClick = { settings.setAppearanceMode(mode) },
                    )
                }
            }
        }
        item {
            SettingsSwitchRow(
                title = stringResource(R.string.settings_holiday),
                checked = holidayThemes,
                onCheckedChange = { settings.setHolidayThemes(it) },
            )
        }
    }
}

// MARK: - Prompts tab

@Composable
private fun PromptsTab(settings: AppSettings) {
    val systemPrompt by settings.systemPrompt.collectAsState()
    val activePreset by settings.activePresetName.collectAsState()
    val isolatedPresets by settings.isolatedPresets.collectAsState()
    val ecl = LocalEclipsePalette.current

    SettingsGroup(stringResource(R.string.settings_prompt)) {
        item {
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
            ) {
                for (preset in settings.allPresets) {
                    EclipseChip(
                        label = "${preset.icon} ${preset.name}",
                        selected = activePreset == preset.name,
                        onClick = { settings.activatePreset(preset.name) },
                    )
                }
            }
        }
        // Isolated chat: this preset keeps its own conversation, history and
        // rolling summary (the macOS isolated-preset semantics).
        item {
            SettingsSwitchRow(
                title = stringResource(R.string.settings_isolated_chat),
                checked = activePreset in isolatedPresets,
                onCheckedChange = { settings.setPresetIsolated(activePreset, it) },
            )
        }
        // Per-preset properties: emoji icon + hidden-from-switcher (mac parity).
        item {
            val presetIcons by settings.presetIcons.collectAsState()
            var iconDraft by rememberSaveable(activePreset, presetIcons) {
                mutableStateOf(settings.presetIcon(activePreset))
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.settings_preset_icon), Modifier.weight(1f), color = ecl.text)
                OutlinedTextField(
                    value = iconDraft,
                    onValueChange = {
                        iconDraft = it.take(4)
                        settings.setPresetIcon(activePreset, iconDraft)
                    },
                    modifier = Modifier.width(90.dp),
                    singleLine = true,
                    colors = eclipseFieldColors(),
                )
            }
        }
        item {
            val hiddenPresets by settings.hiddenPresets.collectAsState()
            SettingsSwitchRow(
                title = stringResource(R.string.settings_preset_hidden),
                checked = activePreset in hiddenPresets,
                onCheckedChange = { settings.setPresetHidden(activePreset, it) },
            )
        }
        // Switcher style: emoji menu in the top bar, or a chip row above the input.
        item {
            val switcherStyle by settings.presetSwitcherStyle.collectAsState()
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.settings_switcher_style), Modifier.weight(1f), color = ecl.text)
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    EclipseChip(
                        label = stringResource(R.string.switcher_menu),
                        selected = switcherStyle == AppSettings.PresetSwitcherStyle.MENU,
                        onClick = { settings.setPresetSwitcherStyle(AppSettings.PresetSwitcherStyle.MENU) },
                    )
                    EclipseChip(
                        label = stringResource(R.string.switcher_chips),
                        selected = switcherStyle == AppSettings.PresetSwitcherStyle.CHIPS,
                        onClick = { settings.setPresetSwitcherStyle(AppSettings.PresetSwitcherStyle.CHIPS) },
                    )
                }
            }
        }
    }

    SettingsGroup(stringResource(R.string.settings_prompt_working)) {
        item {
            var promptDraft by rememberSaveable(activePreset) { mutableStateOf(systemPrompt) }
            LaunchedEffect(systemPrompt) { promptDraft = systemPrompt }
            OutlinedTextField(
                value = promptDraft,
                onValueChange = {
                    promptDraft = it
                    settings.setSystemPrompt(it)
                },
                modifier = Modifier.fillMaxWidth(),
                minLines = 4,
                maxLines = 12,
                colors = eclipseFieldColors(),
            )
        }
        // Unsaved-changes marker + revert (the mac promptIsModified row):
        // shown only while the working copy differs from the preset's text.
        item {
            val promptIsModified = systemPrompt != settings.presetText(activePreset)
            if (promptIsModified) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        stringResource(R.string.prompts_edited),
                        style = MaterialTheme.typography.bodySmall,
                        color = ecl.edited,
                        modifier = Modifier.weight(1f),
                    )
                    EclipseTextButton(
                        stringResource(R.string.prompts_revert_to, activePreset),
                        onClick = { settings.resetPromptToPreset() },
                    )
                }
            }
        }
        item {
            var newPresetName by rememberSaveable { mutableStateOf("") }
            Row(verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(
                    value = newPresetName,
                    onValueChange = { newPresetName = it },
                    modifier = Modifier.weight(1f),
                    label = { Text(stringResource(R.string.settings_save_preset)) },
                    singleLine = true,
                    colors = eclipseFieldColors(),
                )
                Spacer(Modifier.width(8.dp))
                EclipsePrimaryButton(
                    stringResource(R.string.action_save),
                    enabled = newPresetName.isNotBlank(),
                    onClick = {
                        settings.saveCurrentAsPreset(newPresetName)
                        newPresetName = ""
                    },
                )
            }
        }
    }

    // Custom presets can be deleted (built-ins stay).
    val custom = settings.allPresets.filter { !it.isBuiltIn }
    if (custom.isNotEmpty()) {
        SettingsGroup(stringResource(R.string.settings_custom_presets)) {
            for (preset in custom) {
                item {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("${preset.icon} ${preset.name}", Modifier.weight(1f), color = ecl.text)
                        EclipseTextButton(
                            stringResource(R.string.action_delete),
                            onClick = { settings.deletePreset(preset.name) },
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Shared bits

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ProviderDropdown(selected: ProviderID, onSelect: (ProviderID) -> Unit) {
    var expanded by rememberSaveable { mutableStateOf(false) }
    ExposedDropdownMenuBox(expanded = expanded, onExpandedChange = { expanded = it }) {
        OutlinedTextField(
            value = selected.displayName,
            onValueChange = {},
            readOnly = true,
            modifier = Modifier.menuAnchor().fillMaxWidth(),
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = expanded) },
            colors = eclipseFieldColors(),
        )
        ExposedDropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            for (provider in ProviderID.entries) {
                DropdownMenuItem(
                    text = { Text(provider.displayName) },
                    onClick = {
                        onSelect(provider)
                        expanded = false
                    },
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ModelDropdown(models: List<String>, selected: String?, onSelect: (String) -> Unit) {
    var expanded by rememberSaveable { mutableStateOf(false) }
    ExposedDropdownMenuBox(expanded = expanded, onExpandedChange = { expanded = it }) {
        OutlinedTextField(
            value = selected ?: stringResource(R.string.settings_no_model),
            onValueChange = {},
            readOnly = true,
            modifier = Modifier.menuAnchor().fillMaxWidth(),
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = expanded) },
            colors = eclipseFieldColors(),
        )
        ExposedDropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            for (model in models) {
                DropdownMenuItem(
                    text = { Text(model) },
                    onClick = {
                        onSelect(model)
                        expanded = false
                    },
                )
            }
        }
    }
}

// MARK: - Hermes Agent addon section

/**
 * Settings for the Hermes agent role: gateway endpoint + API_SERVER_KEY,
 * connection check (health → capabilities → model options), model lock for
 * new sessions, dashboard courier (file uploads) and the SSH setup commands
 * — the Android adaptation of HermesSettingsView (no local one-click setup:
 * from a phone every gateway is remote).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun HermesSection(settings: AppSettings) {
    val scope = rememberCoroutineScope()
    val endpoint by settings.hermesEndpoint.collectAsState()
    val dashboardUrl by settings.hermesDashboardUrl.collectAsState()
    val modelLock by settings.hermesModelLock.collectAsState()
    var endpointDraft by rememberSaveable { mutableStateOf(settings.hermesEndpoint.value) }
    var keyDraft by rememberSaveable { mutableStateOf("") }
    var dashboardDraft by rememberSaveable { mutableStateOf(settings.hermesDashboardUrl.value) }
    var dashboardTokenDraft by rememberSaveable { mutableStateOf("") }
    var status by remember { mutableStateOf<String?>(null) }
    var statusOk by remember { mutableStateOf(false) }
    var checking by remember { mutableStateOf(false) }
    var modelOptions by remember {
        mutableStateOf<com.aispotlight.android.hermes.HermesModelOptions?>(null)
    }
    val clipboard = androidx.compose.ui.platform.LocalClipboardManager.current

    Column {
        SettingsGroup(stringResource(R.string.hermes_section)) {
            // Gateway endpoint.
            item {
                OutlinedTextField(
                    value = endpointDraft,
                    onValueChange = { endpointDraft = it },
                    label = { Text(stringResource(R.string.hermes_endpoint)) },
                    placeholder = { Text("http://100.x.y.z:8642") },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                    colors = eclipseFieldColors(),
                )
            }
            // API_SERVER_KEY (Keystore-backed).
            item {
                OutlinedTextField(
                    value = keyDraft,
                    onValueChange = { keyDraft = it },
                    label = {
                        Text(
                            if (ApiKeyStore.hasAuxKey(ApiKeyStore.AuxKey.HERMES))
                                stringResource(R.string.hermes_key_saved)
                            else stringResource(R.string.hermes_key)
                        )
                    },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                    visualTransformation = androidx.compose.ui.text.input.PasswordVisualTransformation(),
                    colors = eclipseFieldColors(),
                )
            }
            // Check & save: persists endpoint/key, probes health +
            // capabilities, loads the model-lock options.
            item {
                EclipseTextButton(
                    if (checking) stringResource(R.string.settings_validating)
                    else stringResource(R.string.keys_check_save),
                    enabled = !checking && endpointDraft.isNotBlank(),
                    onClick = {
                        checking = true
                        status = null
                        settings.setHermesEndpoint(endpointDraft)
                        if (keyDraft.isNotBlank()) {
                            ApiKeyStore.setAuxKey(ApiKeyStore.AuxKey.HERMES, keyDraft.trim())
                            keyDraft = ""
                        }
                        scope.launch {
                            try {
                                val transport = com.aispotlight.android.hermes.HermesChatService.transport(settings)
                                val health = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                                    transport.health()
                                }
                                val caps = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                                    transport.capabilities()
                                }
                                modelOptions = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                                    try { transport.modelOptions() } catch (_: Exception) { null }
                                }
                                statusOk = true
                                status = "✓ $health · ${caps.platform}"
                            } catch (e: Exception) {
                                statusOk = false
                                status = e.message?.take(160) ?: "Connection failed"
                            }
                            checking = false
                        }
                    },
                )
            }
            item {
                status?.let {
                    Text(
                        it,
                        style = MaterialTheme.typography.bodySmall,
                        color = if (statusOk) MaterialTheme.colorScheme.primary
                            else MaterialTheme.colorScheme.error,
                    )
                }
            }
            // Model lock for new sessions: agent default, or an explicit
            // provider/model pair from /api/model/options.
            item {
                val options = modelOptions
                if (options != null && options.providers.isNotEmpty()) {
                    var lockMenuOpen by remember { mutableStateOf(false) }
                    val currentLabel = modelLock.split("|").let {
                        if (it.size == 2 && it[0].isNotEmpty()) "${it[0]} · ${it[1]}"
                        else stringResource(R.string.hermes_model_agent_default)
                    }
                    Column {
                        Text(
                            stringResource(R.string.hermes_model_lock),
                            style = MaterialTheme.typography.bodyMedium,
                        )
                        Box {
                            EclipseTextButton(currentLabel, onClick = { lockMenuOpen = true })
                            androidx.compose.material3.DropdownMenu(
                                expanded = lockMenuOpen,
                                onDismissRequest = { lockMenuOpen = false },
                            ) {
                                androidx.compose.material3.DropdownMenuItem(
                                    text = { Text(stringResource(R.string.hermes_model_agent_default)) },
                                    onClick = {
                                        lockMenuOpen = false
                                        settings.setHermesModelLock("")
                                    },
                                )
                                for (provider in options.providers) {
                                    for (model in provider.models) {
                                        androidx.compose.material3.DropdownMenuItem(
                                            text = { Text("${provider.slug} · $model") },
                                            onClick = {
                                                lockMenuOpen = false
                                                settings.setHermesModelLock("${provider.slug}|$model")
                                            },
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        SettingsFootnote(stringResource(R.string.hermes_endpoint_hint))
    }

    // Dashboard courier: file uploads to the agent's host need the Hermes
    // dashboard server (its own URL + session token).
    Column {
        SettingsGroup(stringResource(R.string.hermes_dashboard)) {
            item {
                OutlinedTextField(
                    value = dashboardDraft,
                    onValueChange = {
                        dashboardDraft = it
                        settings.setHermesDashboardUrl(it)
                    },
                    label = { Text(stringResource(R.string.hermes_dashboard_url)) },
                    placeholder = { Text("http://100.x.y.z:8080") },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                    colors = eclipseFieldColors(),
                )
            }
            item {
                OutlinedTextField(
                    value = dashboardTokenDraft,
                    onValueChange = { dashboardTokenDraft = it },
                    label = {
                        Text(
                            if (ApiKeyStore.hasAuxKey(ApiKeyStore.AuxKey.HERMES_DASHBOARD))
                                stringResource(R.string.hermes_key_saved)
                            else stringResource(R.string.hermes_dashboard_token)
                        )
                    },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                    visualTransformation = androidx.compose.ui.text.input.PasswordVisualTransformation(),
                    colors = eclipseFieldColors(),
                )
            }
            item {
                EclipseTextButton(
                    stringResource(R.string.action_save),
                    enabled = dashboardTokenDraft.isNotBlank(),
                    onClick = {
                        ApiKeyStore.setAuxKey(ApiKeyStore.AuxKey.HERMES_DASHBOARD, dashboardTokenDraft.trim())
                        dashboardTokenDraft = ""
                    },
                )
            }
        }
        SettingsFootnote(stringResource(R.string.hermes_dashboard_hint))
    }

    // SSH setup block for the remote host (VPS, cloud, a Mac at home) —
    // verbatim the desktop commands; API_SERVER_HOST=0.0.0.0 is mandatory.
    Column {
        SettingsGroup(stringResource(R.string.hermes_setup)) {
            item {
                val commands = "ssh USER@HOST 'echo API_SERVER_ENABLED=true >> ~/.hermes/.env; \\\n" +
                    "  echo API_SERVER_HOST=0.0.0.0 >> ~/.hermes/.env; \\\n" +
                    "  echo API_SERVER_KEY=$(openssl rand -hex 24) >> ~/.hermes/.env; \\\n" +
                    "  hermes gateway install; hermes gateway restart'\n" +
                    "ssh USER@HOST \"grep '^API_SERVER_KEY=' ~/.hermes/.env\""
                Column {
                    Text(
                        commands,
                        fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                        style = MaterialTheme.typography.bodySmall,
                        modifier = Modifier.horizontalScroll(rememberScrollState()),
                    )
                    EclipseTextButton(
                        stringResource(R.string.action_copy),
                        onClick = {
                            clipboard.setText(androidx.compose.ui.text.AnnotatedString(commands))
                        },
                    )
                }
            }
        }
        SettingsFootnote(stringResource(R.string.hermes_setup_hint))
    }
}
