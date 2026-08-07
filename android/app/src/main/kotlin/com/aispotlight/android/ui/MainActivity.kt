package com.aispotlight.android.ui

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CleaningServices
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.outlined.Psychology
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.aispotlight.android.chat.ChatViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private val viewModel: ChatViewModel by viewModels()

    /** Text shared into the app via SEND / PROCESS_TEXT — consumed by the input bar. */
    private val sharedText = MutableStateFlow<String?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        consumeIntent(intent)
        setContent {
            CuateTheme {
                Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                    AppRoot(viewModel, sharedText)
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        consumeIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        com.aispotlight.android.NotificationService.appVisible = true
        // Returning to the app refreshes the agent mirror — runs finished
        // while we were away surface as unread badges.
        viewModel.syncHermesSessions()
        // The day may have rolled over while the process lived in the
        // background — the mac re-checks on NSCalendarDayChanged, here the
        // next foreground pass does it (idempotent).
        com.aispotlight.android.settings.AppSettings.shared(this).reconcileHolidayTheme()
    }

    override fun onPause() {
        super.onPause()
        com.aispotlight.android.NotificationService.appVisible = false
    }

    private fun consumeIntent(intent: Intent?) {
        when (intent?.action) {
            Intent.ACTION_SEND -> {
                val type = intent.type ?: ""
                val stream = androidx.core.content.IntentCompat.getParcelableExtra(
                    intent, Intent.EXTRA_STREAM, android.net.Uri::class.java
                )
                when {
                    // Shared image → pending attachment (same path as the picker).
                    stream != null && type.startsWith("image/") ->
                        viewModel.attachImage(stream)
                    // Shared voice note / audio file → transcript into the input.
                    stream != null && type.startsWith("audio/") ->
                        viewModel.importSharedAudio(stream, type)
                    // Shared document (PDF, Word, …) → pending file attachment.
                    stream != null && !type.startsWith("text/") ->
                        viewModel.attachFile(stream)
                    else ->
                        sharedText.value = intent.getStringExtra(Intent.EXTRA_TEXT)
                }
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                val streams = androidx.core.content.IntentCompat.getParcelableArrayListExtra(
                    intent, Intent.EXTRA_STREAM, android.net.Uri::class.java
                )
                // Mixed batches (images + documents): route each Uri by its
                // RESOLVED mime — the intent's own type may be a wildcard.
                streams?.forEach { uri ->
                    val mime = contentResolver.getType(uri) ?: intent.type ?: ""
                    if (mime.startsWith("image/")) viewModel.attachImage(uri)
                    else viewModel.attachFile(uri)
                }
            }
            Intent.ACTION_PROCESS_TEXT ->
                sharedText.value = intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()
        }
    }
}

/**
 * Adaptive shell: on wide screens (unfolded foldables, tablets, landscape) the
 * conversation list docks as a persistent left pane next to the chat; on
 * narrow screens (folded/phone) it opens as a separate "screen" the back
 * gesture returns from.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AppRoot(viewModel: ChatViewModel, sharedTextFlow: MutableStateFlow<String?>) {
    val conversations by viewModel.conversations.collectAsStateWithLifecycle()
    val activeId by viewModel.activeConversationId.collectAsStateWithLifecycle()
    val messages by viewModel.messages.collectAsStateWithLifecycle()
    val isLoading by viewModel.isLoading.collectAsStateWithLifecycle()
    val statusText by viewModel.statusText.collectAsStateWithLifecycle()
    val hasOlder by viewModel.hasOlderMessages.collectAsStateWithLifecycle()
    val pendingAttachments by viewModel.pendingAttachments.collectAsStateWithLifecycle()
    val isRecording by viewModel.isRecording.collectAsStateWithLifecycle()
    val isTranscribing by viewModel.isTranscribing.collectAsStateWithLifecycle()
    val transcriptionResult by viewModel.transcriptionResult.collectAsStateWithLifecycle()
    val errorText by viewModel.errorText.collectAsStateWithLifecycle()
    val sharedText by sharedTextFlow.collectAsState()

    val context = androidx.compose.ui.platform.LocalContext.current
    val settings = com.aispotlight.android.settings.AppSettings.shared(context)
    val activePresetName by settings.activePresetName.collectAsStateWithLifecycle()
    val switcherStyle by settings.presetSwitcherStyle.collectAsStateWithLifecycle()
    // hidden/icon changes recompose through these flows
    val presetIcons by settings.presetIcons.collectAsStateWithLifecycle()
    val hiddenPresets by settings.hiddenPresets.collectAsStateWithLifecycle()
    val switcherPresets = remember(presetIcons, hiddenPresets, activePresetName) {
        settings.switcherPresets(activePresetName)
    }

    // Hermes agent role: active thread state, session rows for the pill
    // menu, unread badges and the files dialog.
    val isHermesActive by viewModel.isHermesActive.collectAsStateWithLifecycle()
    val hermesUnread by viewModel.hermesUnread.collectAsStateWithLifecycle()
    val hermesEndpoint by settings.hermesEndpoint.collectAsStateWithLifecycle()
    val hermesConfigured = hermesEndpoint.isNotEmpty()
    val hermesThreads = remember(conversations) { conversations.filter { it.isHermes } }
    val chatFiles by viewModel.chatFiles.collectAsStateWithLifecycle()
    val hermesSkillsList by viewModel.hermesSkills.collectAsStateWithLifecycle()
    val pinnedMessages by viewModel.pinnedMessages.collectAsStateWithLifecycle()
    val hermesModelOptions by viewModel.hermesModelOptions.collectAsStateWithLifecycle()
    val hermesPinnedSessions by settings.hermesPinnedSessions.collectAsStateWithLifecycle()
    val hermesSessionColors by settings.hermesSessionColors.collectAsStateWithLifecycle()
    val hermesSessionModels by settings.hermesSessionModels.collectAsStateWithLifecycle()
    val hermesSessionEfforts by settings.hermesSessionEfforts.collectAsStateWithLifecycle()
    val hermesCreating by viewModel.hermesCreating.collectAsStateWithLifecycle()

    // The Hermes sessions sidebar (desktop 4.0 parity: create / rename /
    // pin / color / delete / unread) lives in a drawer; the hamburger and
    // the role row in the switcher open it.
    val drawerState = androidx.compose.material3.rememberDrawerState(
        androidx.compose.material3.DrawerValue.Closed
    )
    val scope = androidx.compose.runtime.rememberCoroutineScope()

    // Opening the sidebar re-syncs the sessions list against the gateway —
    // sessions created/renamed/DELETED on other surfaces (desktop, CLI)
    // land here; without this the drawer showed threads deleted elsewhere
    // until the next role switch (e2e 2026-07-27).
    androidx.compose.runtime.LaunchedEffect(drawerState.isOpen) {
        if (drawerState.isOpen && hermesConfigured) viewModel.syncHermesSessions()
    }

    // "New session" from the drawer keeps it open to host the spinner; the
    // drawer closes itself once the create lands (either way) and the new
    // thread is on screen.
    var closeDrawerAfterCreate by remember { mutableStateOf(false) }
    androidx.compose.runtime.LaunchedEffect(hermesCreating) {
        if (!hermesCreating && closeDrawerAfterCreate) {
            closeDrawerAfterCreate = false
            drawerState.close()
        }
    }

    // Agent banners need POST_NOTIFICATIONS on 13+ — ask once, when the
    // Hermes role first becomes active.
    val notifPermission = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.RequestPermission()
    ) { }
    androidx.compose.runtime.LaunchedEffect(isHermesActive) {
        if (isHermesActive && android.os.Build.VERSION.SDK_INT >= 33 &&
            !com.aispotlight.android.NotificationService.canNotify(context)
        ) {
            notifPermission.launch(android.Manifest.permission.POST_NOTIFICATIONS)
        }
    }

    val chatPane: @Composable (Modifier) -> Unit = { chatModifier ->
        ChatScreen(
            messages = messages,
            isLoading = isLoading,
            statusText = statusText,
            hasOlderMessages = hasOlder,
            pendingAttachments = pendingAttachments,
            isRecording = isRecording,
            isTranscribing = isTranscribing,
            transcriptionResult = transcriptionResult,
            onSend = { viewModel.send(it) },
            onStop = { viewModel.stopStreaming() },
            onLoadOlder = { viewModel.loadOlderPage() },
            onAttachImage = { viewModel.attachImage(it) },
            onAttachFile = { viewModel.attachFile(it) },
            onRemoveAttachment = { viewModel.removePendingAttachment(it) },
            onStartRecording = { viewModel.startRecording() },
            onStopRecording = { viewModel.stopRecordingAndTranscribe() },
            onCancelRecording = { viewModel.cancelRecording() },
            onTranscriptionConsumed = { viewModel.consumeTranscription() },
            onImageTool = { attachment, function, prompt, mask ->
                viewModel.runImageTool(attachment, function, prompt, mask)
            },
            onSaveToGallery = { viewModel.saveAttachmentToGallery(it) },
            onExtractText = { viewModel.extractText(it) },
            errorText = errorText,
            onErrorDismiss = { viewModel.consumeError() },
            presets = switcherPresets,
            activePreset = activePresetName,
            presetChipsRow = switcherStyle == com.aispotlight.android.settings.AppSettings.PresetSwitcherStyle.CHIPS,
            onSelectPreset = { viewModel.setConversationPreset(it) },
            prefillText = sharedText,
            onPrefillConsumed = { sharedTextFlow.value = null },
            conversationKey = activeId ?: "",
            isHermes = isHermesActive,
            hermesSkills = hermesSkillsList,
            pinnedMessages = pinnedMessages,
            onTogglePin = { viewModel.togglePin(it) },
            onLocatePin = { viewModel.locatePin(it) },
            onStepDetails = { viewModel.hermesStepDetails(it) },
            modifier = chatModifier,
        )
    }

    // Session model + reasoning effort for the ⋮ menu (moved out of the
    // composer 2026-07-27 — the chips row ate screen height for controls
    // touched once per session). The stored pair may lack the provider
    // ("|model" — learned from the gateway session list, which only knows
    // the model): show what we have.
    val hermesModelLabel = viewModel.activeHermesSessionId
        ?.let { hermesSessionModels[it] }?.split("|")
        ?.filter { it.isNotEmpty() }?.joinToString(" · ")?.ifEmpty { null }
    val hermesEffort = viewModel.activeHermesSessionId
        ?.let { hermesSessionEfforts[it] } ?: ""

    var showSettings by rememberSaveable { mutableStateOf(false) }
    var confirmClear by rememberSaveable { mutableStateOf(false) }
    var showModelPicker by rememberSaveable { mutableStateOf(false) }

    // SAF document picker: ANY files, several at once. In agent chats the
    // courier uploads them to the agent's host (desktop 4.2 mechanics); in
    // built-in chats documents are extracted to text for the model.
    val filePicker = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.OpenMultipleDocuments()
    ) { uris ->
        uris.forEach { uri ->
            val mime = context.contentResolver.getType(uri) ?: ""
            if (mime.startsWith("image/")) viewModel.attachImage(uri) else viewModel.attachFile(uri)
        }
    }

    if (showSettings) {
        BackHandler { showSettings = false }
        SettingsScreen(onBack = { showSettings = false })
        return
    }

    // The mac model has no conversation titles — the bar shows the active
    // preset (its emoji lives on the switcher button next to it). An agent
    // thread shows ITS title (sessions are real named threads).
    val activeTitle = if (isHermesActive) {
        conversations.firstOrNull { it.id == activeId }?.title ?: "Hermes"
    } else {
        activePresetName
    }

    // No app bar over the chat: the preset picker pill (replacing the old
    // title) and the ⋮ button float over the content, which scrolls beneath
    // them. Settings keeps its classic top bar.
    val floatingHeader: @Composable () -> Unit = {
        // Centered in the same column as the chat (ChatContentMaxWidth): pinned
        // to the window edges on a tablet, the ⋮ ends up a hand's width away
        // from the conversation it acts on.
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
        Row(
            Modifier
                .widthIn(max = ChatContentMaxWidth)
                .fillMaxWidth()
                .statusBarsPadding()
                .padding(horizontal = 10.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // Translucent chip backing so the controls read over any content.
            val chipColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.82f)

            // Hamburger opens the Hermes sessions sidebar (agent threads).
            if (isHermesActive) {
                Box(
                    Modifier
                        .size(40.dp)
                        .clip(CircleShape)
                        .background(chipColor)
                        .clickable { scope.launch { drawerState.open() } },
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        Icons.Filled.Menu,
                        contentDescription = androidx.compose.ui.res.stringResource(com.aispotlight.android.R.string.hermes_sessions),
                    )
                }
                Spacer(Modifier.width(8.dp))
            }

            // Preset picker pill — emoji + name + caret, opens the preset menu.
            var presetMenuOpen by remember { mutableStateOf(false) }
            Box {
                Row(
                    Modifier
                        .clip(RoundedCornerShape(20.dp))
                        .background(chipColor)
                        .clickable { presetMenuOpen = true }
                        .padding(start = 12.dp, end = 4.dp, top = 8.dp, bottom = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        if (isHermesActive) "🪽"
                        else switcherPresets.firstOrNull { it.name == activePresetName }?.icon ?: "💬"
                    )
                    Spacer(Modifier.width(6.dp))
                    Text(
                        activeTitle,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        style = MaterialTheme.typography.titleSmall,
                        modifier = Modifier.widthIn(max = 190.dp),
                    )
                    Icon(Icons.Filled.ArrowDropDown, contentDescription = null)
                }
                ThemedDropdownMenu(
                    expanded = presetMenuOpen,
                    onDismissRequest = { presetMenuOpen = false },
                ) {
                    for (preset in switcherPresets) {
                        // Same anatomy as the ⋮ menu: leading icon slot (the
                        // preset's emoji), label, trailing check on the active row.
                        androidx.compose.material3.DropdownMenuItem(
                            leadingIcon = { Text(preset.icon) },
                            text = { Text(preset.name) },
                            trailingIcon = {
                                if (preset.name == activePresetName && !isHermesActive) {
                                    Icon(
                                        Icons.Filled.Check,
                                        contentDescription = null,
                                        tint = MaterialTheme.colorScheme.primary,
                                    )
                                }
                            },
                            onClick = {
                                presetMenuOpen = false
                                viewModel.setConversationPreset(preset.name)
                            },
                        )
                    }
                    // Hermes agent role: one row in the switcher (desktop:
                    // the role button); its SESSIONS live in the sidebar
                    // drawer, which this row also opens.
                    if (hermesConfigured) {
                        androidx.compose.material3.HorizontalDivider()
                        androidx.compose.material3.DropdownMenuItem(
                            leadingIcon = { Text("🪽") },
                            text = { Text(androidx.compose.ui.res.stringResource(com.aispotlight.android.R.string.hermes_role)) },
                            trailingIcon = {
                                when {
                                    isHermesActive -> Icon(
                                        Icons.Filled.Check,
                                        contentDescription = null,
                                        tint = MaterialTheme.colorScheme.primary,
                                    )
                                    hermesUnread.isNotEmpty() -> Box(
                                        Modifier
                                            .size(8.dp)
                                            .clip(CircleShape)
                                            .background(MaterialTheme.colorScheme.primary)
                                    )
                                }
                            },
                            onClick = {
                                presetMenuOpen = false
                                viewModel.openHermes()
                                scope.launch { drawerState.open() }
                            },
                        )
                    }
                }
            }

            Spacer(Modifier.weight(1f))

            // Overflow menu (⋮): attach, new chat, share and settings.
            // Agent chats add nested pages for the session model and the
            // reasoning effort (moved here from the composer chips row).
            var menuOpen by remember { mutableStateOf(false) }
            var menuPage by remember { mutableStateOf("main") }
            Box {
                Box(
                    Modifier
                        .size(40.dp)
                        .clip(CircleShape)
                        .background(chipColor)
                        .clickable { menuPage = "main"; menuOpen = true },
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        Icons.Filled.MoreVert,
                        contentDescription = androidx.compose.ui.res.stringResource(com.aispotlight.android.R.string.action_menu),
                    )
                }
                ThemedDropdownMenu(
                    expanded = menuOpen,
                    onDismissRequest = { menuOpen = false },
                ) {
                    when (menuPage) {
                    "effort" -> {
                        androidx.compose.material3.DropdownMenuItem(
                            leadingIcon = { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = null) },
                            text = { Text(androidx.compose.ui.res.stringResource(com.aispotlight.android.R.string.hermes_menu_effort)) },
                            onClick = { menuPage = "main" },
                        )
                        androidx.compose.material3.HorizontalDivider()
                        for (level in settings.hermesEffortLevels) {
                            androidx.compose.material3.DropdownMenuItem(
                                text = {
                                    Text(level.ifEmpty {
                                        androidx.compose.ui.res.stringResource(com.aispotlight.android.R.string.hermes_effort_default)
                                    })
                                },
                                trailingIcon = {
                                    if (level == hermesEffort) Icon(Icons.Filled.Check, contentDescription = null)
                                },
                                onClick = {
                                    menuOpen = false
                                    viewModel.setActiveSessionEffort(level)
                                },
                            )
                        }
                    }
                    else -> {
                    // ONE attach item, every chat: any file. Photos have their
                    // own richer route — the composer's attach sheet (gallery
                    // grid + camera). Splitting "image" from "file" here made
                    // attach mean two different things per chat kind.
                    androidx.compose.material3.DropdownMenuItem(
                        leadingIcon = { Icon(Icons.Filled.AttachFile, contentDescription = null) },
                        text = { Text(androidx.compose.ui.res.stringResource(com.aispotlight.android.R.string.chat_attach)) },
                        onClick = {
                            menuOpen = false
                            filePicker.launch(arrayOf("*/*"))
                        },
                    )
                    if (isHermesActive) {
                        // Agent threads: the gateway owns the history — the
                        // clear action becomes new session / delete session.
                        androidx.compose.material3.DropdownMenuItem(
                            enabled = !hermesCreating,
                            leadingIcon = {
                                if (hermesCreating) {
                                    androidx.compose.material3.CircularProgressIndicator(
                                        modifier = Modifier.size(18.dp), strokeWidth = 2.dp,
                                    )
                                } else {
                                    Icon(Icons.Filled.Add, contentDescription = null)
                                }
                            },
                            text = {
                                Text(androidx.compose.ui.res.stringResource(
                                    if (hermesCreating) com.aispotlight.android.R.string.hermes_creating_session
                                    else com.aispotlight.android.R.string.hermes_new_session
                                ))
                            },
                            onClick = {
                                menuOpen = false
                                viewModel.newHermesSession()
                            },
                        )
                        // Every file of the chat: agent-side paths + yours.
                        androidx.compose.material3.DropdownMenuItem(
                            leadingIcon = { Icon(Icons.Filled.Folder, contentDescription = null) },
                            text = { Text(androidx.compose.ui.res.stringResource(com.aispotlight.android.R.string.hermes_files)) },
                            onClick = {
                                menuOpen = false
                                viewModel.loadChatFiles()
                            },
                        )
                        // Session model opens the structured picker dialog
                        // (providers → vendors → models, search); the effort
                        // stays a nested page — it's 4 rows.
                        androidx.compose.material3.DropdownMenuItem(
                            leadingIcon = { Icon(Icons.Outlined.Psychology, contentDescription = null) },
                            text = { Text(androidx.compose.ui.res.stringResource(com.aispotlight.android.R.string.hermes_menu_model)) },
                            trailingIcon = {
                                Text(
                                    hermesModelLabel?.substringAfterLast("/") ?: "",
                                    style = MaterialTheme.typography.bodySmall,
                                    maxLines = 1,
                                    overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                                    modifier = Modifier.widthIn(max = 120.dp),
                                )
                            },
                            onClick = {
                                menuOpen = false
                                showModelPicker = true
                                // The catalog is live and mutable — re-read on open.
                                viewModel.refreshHermesModelOptions()
                            },
                        )
                        if (settings.hermesEffortLevels.isNotEmpty()) {
                            androidx.compose.material3.DropdownMenuItem(
                                leadingIcon = { Icon(Icons.Filled.Tune, contentDescription = null) },
                                text = { Text(androidx.compose.ui.res.stringResource(com.aispotlight.android.R.string.hermes_menu_effort)) },
                                trailingIcon = {
                                    Text(
                                        hermesEffort.ifEmpty {
                                            androidx.compose.ui.res.stringResource(com.aispotlight.android.R.string.hermes_effort_default)
                                        },
                                        style = MaterialTheme.typography.bodySmall,
                                    )
                                },
                                onClick = { menuPage = "effort" },
                            )
                        }
                        androidx.compose.material3.DropdownMenuItem(
                            leadingIcon = { Icon(Icons.Filled.Delete, contentDescription = null) },
                            text = { Text(androidx.compose.ui.res.stringResource(com.aispotlight.android.R.string.hermes_delete_session)) },
                            onClick = {
                                menuOpen = false
                                confirmClear = true
                            },
                        )
                    } else {
                    // Clear the conversation (the mac "new chat" semantics).
                    androidx.compose.material3.DropdownMenuItem(
                        leadingIcon = { Icon(Icons.Filled.CleaningServices, contentDescription = null) },
                        text = { Text(androidx.compose.ui.res.stringResource(com.aispotlight.android.R.string.action_clear_chat)) },
                        onClick = {
                            menuOpen = false
                            confirmClear = true
                        },
                    )
                    }
                    // Sharing is a per-MESSAGE action (long-press a bubble):
                    // a whole-transcript export had no reader — nobody sends
                    // a markdown dump of an entire conversation.
                    androidx.compose.material3.HorizontalDivider()
                    androidx.compose.material3.DropdownMenuItem(
                        leadingIcon = { Icon(Icons.Filled.Settings, contentDescription = null) },
                        text = { Text(androidx.compose.ui.res.stringResource(com.aispotlight.android.R.string.settings_title)) },
                        onClick = {
                            menuOpen = false
                            showSettings = true
                        },
                    )
                    }
                    }
                }
            }
        }
        }
    }

    // One layout on every form factor: the chat fills the screen and simply
    // gets more room on tablets/unfolded foldables. The old docked preset
    // rail was removed (presets are a pill menu) — but the HERMES sessions
    // sidebar is a real navigation surface (desktop 4.0), so it returns as
    // a drawer: swipe from the left edge in an agent thread, the hamburger,
    // or the role row in the switcher.
    androidx.compose.material3.ModalNavigationDrawer(
        drawerState = drawerState,
        gesturesEnabled = hermesConfigured && (isHermesActive || drawerState.isOpen),
        drawerContent = {
            HermesSidebar(
                threads = hermesThreads,
                activeId = activeId,
                unreadIds = hermesUnread,
                pinnedSessionIds = hermesPinnedSessions,
                sessionColors = hermesSessionColors,
                onOpen = {
                    scope.launch { drawerState.close() }
                    viewModel.openHermesConversation(it)
                },
                onNewSession = {
                    // The drawer STAYS open: it hosts the create spinner
                    // (closing it instantly hid all progress — the invisible
                    // wait bred repeat taps). It closes itself when the
                    // session is ready and the thread opens.
                    closeDrawerAfterCreate = true
                    viewModel.newHermesSession()
                },
                creatingSession = hermesCreating,
                onRename = { id, title -> viewModel.renameHermesConversation(id, title) },
                onTogglePin = { settings.toggleHermesSessionPin(it) },
                onSetColor = { id, hex -> settings.setHermesSessionColor(id, hex) },
                onDelete = { viewModel.deleteHermesConversation(it) },
            )
        },
    ) {
        Box(Modifier.fillMaxSize()) {
            chatPane(Modifier.fillMaxSize())
            floatingHeader()
        }
    }

    if (confirmClear) {
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { confirmClear = false },
            title = {
                Text(androidx.compose.ui.res.stringResource(
                    if (isHermesActive) com.aispotlight.android.R.string.hermes_delete_title
                    else com.aispotlight.android.R.string.chat_clear_title
                ))
            },
            text = {
                Text(androidx.compose.ui.res.stringResource(
                    if (isHermesActive) com.aispotlight.android.R.string.hermes_delete_message
                    else com.aispotlight.android.R.string.chat_clear_message
                ))
            },
            confirmButton = {
                androidx.compose.material3.TextButton(onClick = {
                    confirmClear = false
                    if (isHermesActive) viewModel.deleteHermesConversation() else viewModel.clearChat()
                }) {
                    Text(androidx.compose.ui.res.stringResource(
                        if (isHermesActive) com.aispotlight.android.R.string.action_delete
                        else com.aispotlight.android.R.string.chat_new
                    ))
                }
            },
            dismissButton = {
                androidx.compose.material3.TextButton(onClick = { confirmClear = false }) {
                    Text(androidx.compose.ui.res.stringResource(com.aispotlight.android.R.string.action_cancel))
                }
            },
        )
    }

    // Session model picker: provider sections, vendor subgroups, search.
    if (showModelPicker) {
        // Provider may be unknown ("|model" from the session list) — the
        // picker then matches the check mark by model alone.
        val lockedPair = viewModel.activeHermesSessionId
            ?.let { hermesSessionModels[it] }?.split("|")
            ?.takeIf { it.size == 2 && it[1].isNotEmpty() }?.let { it[0] to it[1] }
        HermesModelPicker(
            options = hermesModelOptions,
            selected = lockedPair,
            onPickAgentDefault = null,
            onPick = { provider, model ->
                showModelPicker = false
                viewModel.setActiveSessionModel(provider, model)
            },
            onRefresh = { viewModel.refreshHermesModelOptions(force = true) },
            onDismiss = { showModelPicker = false },
        )
    }

    // Files of the agent chat: agent-side paths (tap = copy) and the
    // attachments the user sent, in their own group (desktop 4.2 grouping).
    chatFiles?.let { files ->
        val clipboard = androidx.compose.ui.platform.LocalClipboardManager.current
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { viewModel.dismissChatFiles() },
            title = { Text(androidx.compose.ui.res.stringResource(com.aispotlight.android.R.string.hermes_files)) },
            text = {
                androidx.compose.foundation.lazy.LazyColumn {
                    if (files.agentPaths.isEmpty() && files.sentByYou.isEmpty()) {
                        item {
                            Text(androidx.compose.ui.res.stringResource(com.aispotlight.android.R.string.hermes_files_empty))
                        }
                    }
                    items(files.agentPaths.size) { index ->
                        val path = files.agentPaths[index]
                        // Desktop row anatomy: filename + the full path in
                        // small mono. Tap = copy (the remote-host branch).
                        androidx.compose.foundation.layout.Column(
                            Modifier
                                .fillMaxWidth()
                                .clickable {
                                    clipboard.setText(androidx.compose.ui.text.AnnotatedString(path))
                                }
                                .padding(vertical = 6.dp),
                        ) {
                            Text(
                                path.substringAfterLast('/'),
                                style = MaterialTheme.typography.bodyMedium,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            Text(
                                path,
                                style = MaterialTheme.typography.labelSmall.copy(
                                    fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                                ),
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                    if (files.sentByYou.isNotEmpty()) {
                        item {
                            Text(
                                androidx.compose.ui.res.stringResource(com.aispotlight.android.R.string.hermes_files_sent),
                                style = MaterialTheme.typography.labelMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.padding(top = 10.dp, bottom = 2.dp),
                            )
                        }
                        items(files.sentByYou.size) { index ->
                            Text(
                                files.sentByYou[index],
                                style = MaterialTheme.typography.bodySmall,
                                modifier = Modifier.padding(vertical = 6.dp),
                            )
                        }
                    }
                }
            },
            confirmButton = {
                androidx.compose.material3.TextButton(onClick = { viewModel.dismissChatFiles() }) {
                    Text(androidx.compose.ui.res.stringResource(com.aispotlight.android.R.string.action_close))
                }
            },
        )
    }
}
