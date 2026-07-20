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
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.CleaningServices
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Share
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

class MainActivity : ComponentActivity() {
    private val viewModel: ChatViewModel by viewModels()

    /** Text shared into the app via SEND / PROCESS_TEXT — consumed by the input bar. */
    private val sharedText = MutableStateFlow<String?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        consumeIntent(intent)
        setContent {
            AISpotlightTheme {
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

    private fun consumeIntent(intent: Intent?) {
        when (intent?.action) {
            Intent.ACTION_SEND ->
                sharedText.value = intent.getStringExtra(Intent.EXTRA_TEXT)
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
            modifier = chatModifier,
        )
    }

    var showSettings by rememberSaveable { mutableStateOf(false) }
    var confirmClear by rememberSaveable { mutableStateOf(false) }

    // System Photo Picker (no permission needed) — fired from the ⋮ menu.
    val attachPicker = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.PickMultipleVisualMedia(maxItems = 4)
    ) { uris ->
        uris.forEach { viewModel.attachImage(it) }
    }

    if (showSettings) {
        BackHandler { showSettings = false }
        SettingsScreen(onBack = { showSettings = false })
        return
    }

    // The mac model has no conversation titles — the bar shows the active
    // preset (its emoji lives on the switcher button next to it).
    val activeTitle = activePresetName

    // No app bar over the chat: the preset picker pill (replacing the old
    // title) and the ⋮ button float over the content, which scrolls beneath
    // them. Settings keeps its classic top bar.
    val floatingHeader: @Composable () -> Unit = {
        Row(
            Modifier
                .fillMaxWidth()
                .statusBarsPadding()
                .padding(horizontal = 10.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // Translucent chip backing so the controls read over any content.
            val chipColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.82f)

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
                    Text(switcherPresets.firstOrNull { it.name == activePresetName }?.icon ?: "💬")
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
                                if (preset.name == activePresetName) {
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
                }
            }

            Spacer(Modifier.weight(1f))

            // Overflow menu (⋮): attach, new chat, share and settings.
            var menuOpen by remember { mutableStateOf(false) }
            Box {
                Box(
                    Modifier
                        .size(40.dp)
                        .clip(CircleShape)
                        .background(chipColor)
                        .clickable { menuOpen = true },
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
                    // Attach images (the paperclip moved out of the composer).
                    androidx.compose.material3.DropdownMenuItem(
                        leadingIcon = { Icon(Icons.Filled.AttachFile, contentDescription = null) },
                        text = { Text(androidx.compose.ui.res.stringResource(com.aispotlight.android.R.string.chat_attach)) },
                        onClick = {
                            menuOpen = false
                            attachPicker.launch(
                                androidx.activity.result.PickVisualMediaRequest(
                                    androidx.activity.result.contract.ActivityResultContracts.PickVisualMedia.ImageOnly
                                )
                            )
                        },
                    )
                    // Clear the conversation (the mac "new chat" semantics).
                    androidx.compose.material3.DropdownMenuItem(
                        leadingIcon = { Icon(Icons.Filled.CleaningServices, contentDescription = null) },
                        text = { Text(androidx.compose.ui.res.stringResource(com.aispotlight.android.R.string.action_clear_chat)) },
                        onClick = {
                            menuOpen = false
                            confirmClear = true
                        },
                    )
                    // Share the conversation as a markdown transcript.
                    androidx.compose.material3.DropdownMenuItem(
                        leadingIcon = { Icon(Icons.Filled.Share, contentDescription = null) },
                        text = { Text(androidx.compose.ui.res.stringResource(com.aispotlight.android.R.string.action_share)) },
                        onClick = {
                            menuOpen = false
                            val transcript = viewModel.exportTranscript()
                            val intent = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
                                type = "text/plain"
                                putExtra(android.content.Intent.EXTRA_TEXT, transcript)
                            }
                            context.startActivity(android.content.Intent.createChooser(intent, activeTitle))
                        },
                    )
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

    // One layout on every form factor: the chat fills the screen and simply
    // gets more room on tablets/unfolded foldables. The old docked preset
    // rail on wide screens duplicated the header's preset picker and read as
    // a foreign element — presets are a pill menu, not a navigation pane.
    Box(Modifier.fillMaxSize()) {
        chatPane(Modifier.fillMaxSize())
        floatingHeader()
    }

    if (confirmClear) {
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { confirmClear = false },
            title = { Text(androidx.compose.ui.res.stringResource(com.aispotlight.android.R.string.chat_clear_title)) },
            text = { Text(androidx.compose.ui.res.stringResource(com.aispotlight.android.R.string.chat_clear_message)) },
            confirmButton = {
                androidx.compose.material3.TextButton(onClick = {
                    confirmClear = false
                    viewModel.clearChat()
                }) { Text(androidx.compose.ui.res.stringResource(com.aispotlight.android.R.string.chat_new)) }
            },
            dismissButton = {
                androidx.compose.material3.TextButton(onClick = { confirmClear = false }) {
                    Text(androidx.compose.ui.res.stringResource(com.aispotlight.android.R.string.action_cancel))
                }
            },
        )
    }
}
