package com.aispotlight.android.ui

import android.Manifest
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.filled.AutoFixHigh
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.SelectAll
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.PhotoCamera
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.outlined.Psychology
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.drawOutline
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import kotlinx.coroutines.flow.first
import com.aispotlight.android.R
import com.aispotlight.android.data.ChatAttachment
import com.aispotlight.android.data.ChatMessage
import com.aispotlight.android.data.ImageStore
import java.io.File

/**
 * The chat pane: message list with streaming, thinking indicator, artifacts,
 * attachments and voice input. The Compose analog of ChatWindow.swift.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatScreen(
    messages: List<ChatMessage>,
    isLoading: Boolean,
    statusText: String?,
    hasOlderMessages: Boolean,
    pendingAttachments: List<ChatAttachment>,
    isRecording: Boolean,
    isTranscribing: Boolean,
    transcriptionResult: String?,
    onSend: (String) -> Unit,
    onStop: () -> Unit,
    onLoadOlder: () -> Unit,
    onAttachImage: (Uri) -> Unit,
    onRemoveAttachment: (String) -> Unit,
    onStartRecording: () -> Boolean,
    onStopRecording: () -> Unit,
    onCancelRecording: () -> Unit,
    onTranscriptionConsumed: () -> Unit,
    onImageTool: (ChatAttachment, com.aispotlight.android.providers.FalImageProvider.Function, String?, String?) -> Unit,
    onSaveToGallery: (ChatAttachment) -> Unit,
    onExtractText: (ChatAttachment) -> Unit = {},
    /** Pipeline error (transcription, attach, image tool) shown as a dismissible banner. */
    errorText: String? = null,
    onErrorDismiss: () -> Unit = {},
    presets: List<com.aispotlight.android.settings.PromptPreset> = emptyList(),
    activePreset: String = "",
    presetChipsRow: Boolean = false,
    onSelectPreset: (String) -> Unit = {},
    prefillText: String? = null,
    onPrefillConsumed: () -> Unit = {},
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val palette = LocalChatPalette.current
    var input by rememberSaveable { mutableStateOf("") }
    val listState = rememberLazyListState()
    var openArtifact by remember { mutableStateOf<Artifact?>(null) }
    // Full-screen zoomable viewer for a tapped chat image.
    var viewerTarget by remember { mutableStateOf<ChatAttachment?>(null) }
    // Object removal: the selected model decides text-prompt vs brush mask.
    var cleanupPromptTarget by remember { mutableStateOf<ChatAttachment?>(null) }
    var maskTarget by remember { mutableStateOf<ChatAttachment?>(null) }
    var cleanupPromptText by remember { mutableStateOf("") }

    // Object-removal routing shared by pending chips and message attachments:
    // text-prompt models open the prompt dialog, brush models the mask editor.
    val requestCleanup: (ChatAttachment) -> Unit = { attachment ->
        val model = com.aispotlight.android.providers.FalImageProvider.model(
            com.aispotlight.android.settings.AppSettings.shared(context)
                .imageModel(com.aispotlight.android.providers.FalImageProvider.Function.OBJECT_CLEANUP)
        )
        if (model?.cleanupByText == true) {
            cleanupPromptText = ""
            cleanupPromptTarget = attachment
        } else {
            maskTarget = attachment
        }
    }

    // Shared text arriving via SEND/PROCESS_TEXT lands as an editable quote.
    LaunchedEffect(prefillText) {
        if (!prefillText.isNullOrEmpty()) {
            input = prefillText.lines().joinToString("\n") { "> $it" } + "\n"
            onPrefillConsumed()
        }
    }

    // Transcribed speech lands in the input for editing before sending.
    LaunchedEffect(transcriptionResult) {
        if (!transcriptionResult.isNullOrEmpty()) {
            input = if (input.isBlank()) transcriptionResult else input.trimEnd() + " " + transcriptionResult
            onTranscriptionConsumed()
        }
    }

    // Follow the stream: keep the newest message in view — keyed on the LAST
    // message (id + streamed length), not the list size, so prepending an
    // older page never yanks the view down. The FIRST fill of a conversation
    // (cold start, chat switch) LANDS on the last message instantly — the old
    // animate-from-the-top scrolled the whole history past the eyes.
    val lastMessage = messages.lastOrNull()
    var anchored by remember { mutableStateOf(false) }
    LaunchedEffect(lastMessage?.id, lastMessage?.text?.length) {
        if (lastMessage == null) {
            // Conversation switch in flight: the list was reset — the next
            // fill is a fresh landing, not a new-message follow.
            anchored = false
            return@LaunchedEffect
        }
        if (anchored) {
            listState.animateScrollToItem(messages.size - 1)
        } else {
            listState.scrollToItem(messages.size - 1)
            anchored = true
        }
    }

    // Keyboard-open compensation. adjustResize + imePadding shrink the
    // viewport from the BOTTOM, but a forward LazyColumn anchors its scroll
    // to the TOP — so the composer rides up over the messages and the ones
    // next to it hide behind the keyboard until scrolled by hand. Follow the
    // IME inset frame-by-frame and shift the list by the same amount (the
    // Telegram behavior): what you were reading stays put above the composer.
    // Closing needs no compensation — the scroll-offset clamp of the growing
    // viewport pulls the content back down naturally.
    val density = androidx.compose.ui.platform.LocalDensity.current
    val imeInsets = androidx.compose.foundation.layout.WindowInsets.ime
    LaunchedEffect(Unit) {
        var previous = 0
        androidx.compose.runtime.snapshotFlow { imeInsets.getBottom(density) }
            .collect { bottom ->
                val delta = bottom - previous
                previous = bottom
                if (delta > 0) listState.scrollBy(delta.toFloat())
            }
    }

    // Camera capture (FileProvider); the gallery picker lives in the top-bar
    // ⋮ menu (MainActivity) since the paperclip moved out of the composer.
    var cameraTarget by remember { mutableStateOf<Pair<Uri, File>?>(null) }
    val cameraLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.TakePicture()
    ) { success ->
        val target = cameraTarget
        cameraTarget = null
        if (success && target != null) {
            // The import copies the bytes asynchronously; the cache-dir temp
            // file is cleaned up by the OS, so no eager delete here.
            onAttachImage(target.first)
        } else {
            target?.second?.delete()
        }
    }
    val micPermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        if (granted) onStartRecording()
    }

    // Decorative theme: the mac panel surface — radial/vertical gradient at the
    // spec's center (0.25, 0.10), the glass-panel wash for Halloween/Día, and
    // the signature grid/scanline pattern on top.
    val themedModifier = if (palette.isDynamic) Modifier else {
        Modifier.drawBehind {
            if (palette.radialBackground) {
                drawRect(
                    androidx.compose.ui.graphics.Brush.radialGradient(
                        colors = palette.backgroundColors,
                        center = Offset(size.width * 0.25f, size.height * 0.10f),
                        radius = maxOf(480.dp.toPx(), size.height * 0.75f),
                    )
                )
            } else {
                drawRect(androidx.compose.ui.graphics.Brush.verticalGradient(palette.backgroundColors))
            }
            // Hybrid glass (Halloween/Día): the spec's milky panel wash laid
            // over the backdrop gradient (mac: over the desktop blur).
            if (palette.glassSurface) drawRect(palette.panelTint)
            when (palette.pattern) {
                ThemePattern.GRID -> {
                    val step = 24.dp.toPx()
                    var x = 0f
                    while (x < size.width) {
                        drawLine(palette.patternColor, Offset(x, 0f), Offset(x, size.height))
                        x += step
                    }
                    var y = 0f
                    while (y < size.height) {
                        drawLine(palette.patternColor, Offset(0f, y), Offset(size.width, y))
                        y += step
                    }
                }
                ThemePattern.SCANLINES -> {
                    // 3dp period, 1px lines — the mac scanline spec.
                    val step = 3.dp.toPx()
                    var y = 0f
                    while (y < size.height) {
                        drawLine(palette.patternColor, Offset(0f, y), Offset(size.width, y), strokeWidth = 1f)
                        y += step
                    }
                }
                ThemePattern.NONE -> Unit
            }
        }
    }

    Box(modifier.fillMaxSize().then(themedModifier)) {
        // Theme ornaments (petals, sparkles, webs, papel picado) — fixed spec
        // positions with gentle animation loops, behind the chat content.
        ThemeDecorationsOverlay(palette.decoration, palette.dark)
        // Blueprint's reference crosses in the four panel corners.
        palette.cornerMarkColor?.let { BlueprintCornerMarks(it) }
        // Full-bleed layout: the themed background runs under the system bars;
        // content respects them. Extra top padding clears the floating header
        // pills — messages scroll beneath them.
        Column(
            Modifier
                .fillMaxSize()
                .systemBarsPadding()
                .imePadding()
        ) {
        LazyColumn(
            state = listState,
            modifier = Modifier.weight(1f).fillMaxWidth(),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(
                start = 12.dp, end = 12.dp, bottom = 12.dp, top = 12.dp + 48.dp,
            ),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            if (hasOlderMessages) {
                item(key = "load-older") {
                    TextButton(onClick = onLoadOlder, modifier = Modifier.fillMaxWidth()) {
                        Text(stringResource(R.string.chat_load_earlier))
                    }
                }
            }
            if (messages.isEmpty() && !isLoading) {
                item(key = "welcome") { WelcomeCard() }
            }
            items(messages, key = { it.id }) { message ->
                MessageBubble(
                    message,
                    // The reply still streaming in is always the last message;
                    // artifact cards use this to tell "fence still coming"
                    // from "stream ended with the fence never closed".
                    isStreamingReply = isLoading && !message.isUser && message.id == messages.lastOrNull()?.id,
                    onOpenArtifact = { openArtifact = it },
                    onImageTool = { attachment, function, prompt ->
                        onImageTool(attachment, function, prompt, null)
                    },
                    onRequestCleanup = requestCleanup,
                    onSaveToGallery = onSaveToGallery,
                    onExtractText = onExtractText,
                    onOpenImage = { viewerTarget = it },
                    // Smooth appearance/reorder — the mac panel's insert animation.
                    modifier = Modifier.animateItem(),
                )
            }
            if (statusText != null) {
                item(key = "thinking") { ThinkingIndicator(statusText) }
            }
        }

        // Error banner: transcription/attach/image-tool failures used to land
        // in a state nobody rendered — a keyless voice message just vanished.
        // Dismissible, above the composer.
        if (errorText != null) {
            Surface(
                color = MaterialTheme.colorScheme.errorContainer,
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 12.dp, vertical = 4.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        errorText,
                        color = MaterialTheme.colorScheme.onErrorContainer,
                        style = MaterialTheme.typography.bodySmall,
                        modifier = Modifier.weight(1f).padding(start = 12.dp, top = 8.dp, bottom = 8.dp),
                    )
                    IconButton(onClick = onErrorDismiss) {
                        Icon(
                            Icons.Filled.Close,
                            contentDescription = stringResource(R.string.action_close),
                            tint = MaterialTheme.colorScheme.onErrorContainer,
                        )
                    }
                }
            }
        }

        // Pending attachments. Exactly ONE image staged → a styled processing
        // button sits to its right (upscale / bg removal / object cleanup /
        // OCR): the old tap-the-thumbnail menu was undiscoverable. SEVERAL
        // staged → removable previews only, no processing offered (processing
        // one file out of a batch is undefined — the set goes to the model).
        if (pendingAttachments.size == 1) {
            val single = pendingAttachments.first()
            Row(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 12.dp, vertical = 4.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                PendingAttachmentChip(single, onRemove = { onRemoveAttachment(single.id) })
                PendingProcessButton(
                    attachment = single,
                    onImageTool = { att, function -> onImageTool(att, function, null, null) },
                    onRequestCleanup = requestCleanup,
                    onExtractText = onExtractText,
                    modifier = Modifier.weight(1f),
                )
            }
        } else if (pendingAttachments.isNotEmpty()) {
            Row(
                Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState())
                    .padding(horizontal = 12.dp, vertical = 4.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                for (attachment in pendingAttachments) {
                    PendingAttachmentChip(
                        attachment,
                        onRemove = { onRemoveAttachment(attachment.id) },
                    )
                }
            }
        }

        // Preset switcher as a chip row (the mac "chips" switcher style).
        if (presetChipsRow && presets.isNotEmpty()) {
            Row(
                Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState())
                    .padding(horizontal = 12.dp, vertical = 2.dp),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                for (preset in presets) {
                    androidx.compose.material3.FilterChip(
                        selected = preset.name == activePreset,
                        onClick = { onSelectPreset(preset.name) },
                        label = { Text("${preset.icon} ${preset.name}") },
                    )
                }
            }
        }

        // Composer top divider — themed (dashed Blueprint, dotted Día).
        ThemedComposerDivider(palette, Modifier.padding(horizontal = 8.dp))

        // Input bar — Telegram-style balance: the text pill owns the width
        // (camera lives INSIDE it), a single 48dp round action on the right
        // morphs mic ↔ send ↔ stop. The paperclip moved to the top-bar menu.
        Row(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 10.dp, vertical = 8.dp),
            verticalAlignment = Alignment.Bottom,
        ) {
            val fieldShape = if (palette.isDynamic) RoundedCornerShape(26.dp)
                else RoundedCornerShape(palette.inputRadius.dp)
            val fieldColor = if (palette.isDynamic) MaterialTheme.colorScheme.surfaceContainerHigh
                else palette.inputFill
            val textColor = if (palette.isDynamic) MaterialTheme.colorScheme.onSurface else palette.primaryText
            Row(
                Modifier
                    .weight(1f)
                    .heightIn(min = 48.dp)
                    .clip(fieldShape)
                    .background(fieldColor)
                    .then(
                        if (palette.isDynamic) Modifier
                        else Modifier.border(1.dp, palette.inputStroke, fieldShape)
                    ),
                verticalAlignment = Alignment.Bottom,
            ) {
                Box(
                    Modifier
                        .weight(1f)
                        // 12+24(line)+12 = exactly 48dp — the same height as
                        // the action button, so bottom alignment == centered.
                        .padding(start = 16.dp, top = 12.dp, bottom = 12.dp),
                    contentAlignment = Alignment.CenterStart,
                ) {
                    if (input.isEmpty()) {
                        val placeholderColor = if (palette.isDynamic) MaterialTheme.colorScheme.onSurfaceVariant
                            else palette.placeholderColor
                        if (isRecording) {
                            // Recording: pulsing dot + live elapsed counter
                            // (Telegram-style) in the theme's recording accent.
                            var recordSeconds by remember { mutableStateOf(0) }
                            LaunchedEffect(isRecording) {
                                recordSeconds = 0
                                while (true) {
                                    kotlinx.coroutines.delay(1000)
                                    recordSeconds++
                                }
                            }
                            val dotColor = if (palette.isDynamic) MaterialTheme.colorScheme.error
                                else (palette.recordingAccent ?: palette.accent)
                            val pulse = rememberInfiniteTransition(label = "recPulse")
                            val dotAlpha by pulse.animateFloat(
                                initialValue = 1f, targetValue = 0.25f,
                                animationSpec = infiniteRepeatable(tween(700), RepeatMode.Reverse),
                                label = "recDot",
                            )
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Box(
                                    Modifier
                                        .size(9.dp)
                                        .alpha(dotAlpha)
                                        .background(dotColor, CircleShape)
                                )
                                Spacer(Modifier.size(8.dp))
                                Text(
                                    "%d:%02d".format(recordSeconds / 60, recordSeconds % 60),
                                    color = if (palette.isDynamic) MaterialTheme.colorScheme.onSurface else palette.primaryText,
                                    style = MaterialTheme.typography.bodyLarge,
                                )
                                Spacer(Modifier.size(10.dp))
                                Text(
                                    stringResource(R.string.chat_recording),
                                    color = placeholderColor,
                                    style = MaterialTheme.typography.bodyLarge,
                                    maxLines = 1,
                                )
                            }
                        } else {
                            val placeholderText = when {
                                isTranscribing -> stringResource(R.string.chat_transcribing)
                                // Themed placeholders travel verbatim from the mac palettes.
                                palette.placeholder != null -> palette.placeholder
                                else -> stringResource(R.string.chat_placeholder)
                            }
                            if (palette.placeholderCaret && !isTranscribing) {
                                // Terminal's blinking block caret after the "$ …" prompt.
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Text(placeholderText, color = placeholderColor, style = MaterialTheme.typography.bodyLarge)
                                    Spacer(Modifier.size(3.dp))
                                    BlinkingCaret(palette.accent, height = 13.dp)
                                }
                            } else {
                                Text(placeholderText, color = placeholderColor, style = MaterialTheme.typography.bodyLarge)
                            }
                        }
                    }
                    BasicTextField(
                        value = input,
                        onValueChange = { input = it },
                        textStyle = MaterialTheme.typography.bodyLarge.copy(color = textColor),
                        cursorBrush = SolidColor(if (palette.isDynamic) MaterialTheme.colorScheme.primary else palette.accent),
                        maxLines = 6,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                // Camera inside the pill, bottom-anchored (Telegram's attach slot).
                IconButton(
                    onClick = {
                        val dir = File(context.cacheDir, "camera").apply { mkdirs() }
                        val file = File(dir, "capture-${System.currentTimeMillis()}.jpg")
                        val uri = FileProvider.getUriForFile(context, context.packageName + ".fileprovider", file)
                        cameraTarget = uri to file
                        cameraLauncher.launch(uri)
                    },
                    modifier = Modifier.size(48.dp),
                ) {
                    Icon(
                        Icons.Filled.PhotoCamera,
                        contentDescription = stringResource(R.string.chat_camera),
                        tint = if (palette.isDynamic) MaterialTheme.colorScheme.onSurfaceVariant
                        else palette.ink.copy(alpha = 0.85f),
                        modifier = Modifier.size(23.dp),
                    )
                }
            }
            Spacer(Modifier.size(8.dp))
            // Voice caption for a staged image: with attachments pending the
            // action slot below holds Send, so the mic gets its own slot —
            // dictating what to do with a photo must not require typing.
            // The transcript and the attachments then go out as one message.
            if (!isRecording && !isTranscribing && !isLoading &&
                input.isBlank() && pendingAttachments.isNotEmpty()
            ) {
                Box(Modifier.size(48.dp), contentAlignment = Alignment.Center) {
                    val micAction = { micPermission.launch(Manifest.permission.RECORD_AUDIO) }
                    if (palette.isDynamic) {
                        FilledIconButton(
                            onClick = micAction,
                            modifier = Modifier.size(48.dp),
                            colors = IconButtonDefaults.filledIconButtonColors(
                                containerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                                contentColor = MaterialTheme.colorScheme.onSurfaceVariant,
                            ),
                        ) {
                            Icon(Icons.Filled.Mic, contentDescription = stringResource(R.string.chat_dictate))
                        }
                    } else {
                        ThemedMicButton(palette, onClick = micAction)
                    }
                }
                Spacer(Modifier.size(8.dp))
            }
            // Single round action slot — every state renders at exactly 48dp,
            // the same height as the single-line pill: with the row bottom-
            // aligned, button and field share one center line, and on
            // multi-line growth the button stays at the bottom (Telegram).
            Box(Modifier.size(48.dp), contentAlignment = Alignment.Center) {
                when {
                    isRecording -> {
                        FilledIconButton(
                            onClick = onStopRecording,
                            modifier = Modifier.size(48.dp),
                            colors = IconButtonDefaults.filledIconButtonColors(
                                // Recording accent per spec (Día pink, Halloween orange).
                                containerColor = if (palette.isDynamic) MaterialTheme.colorScheme.error
                                else (palette.recordingAccent ?: palette.quoteColor ?: palette.accent),
                            ),
                        ) {
                            Icon(Icons.Filled.Stop, contentDescription = stringResource(R.string.chat_stop_recording))
                        }
                    }
                    isTranscribing -> {
                        CircularProgressIndicator(Modifier.size(24.dp), strokeWidth = 2.dp)
                    }
                    isLoading -> {
                        FilledIconButton(onClick = onStop, modifier = Modifier.size(48.dp)) {
                            Icon(Icons.Filled.Stop, contentDescription = stringResource(R.string.chat_stop))
                        }
                    }
                    input.isBlank() && pendingAttachments.isEmpty() -> {
                        val micAction = { micPermission.launch(Manifest.permission.RECORD_AUDIO) }
                        if (palette.isDynamic) {
                            FilledIconButton(
                                onClick = micAction,
                                modifier = Modifier.size(48.dp),
                                colors = IconButtonDefaults.filledIconButtonColors(
                                    containerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                                    contentColor = MaterialTheme.colorScheme.onSurfaceVariant,
                                ),
                            ) {
                                Icon(Icons.Filled.Mic, contentDescription = stringResource(R.string.chat_dictate))
                            }
                        } else {
                            // Themed mic: dashed circle (Día) or solid rounded
                            // square/circle matching the composer buttons (mac
                            // EnhancedVoiceButton idle look).
                            ThemedMicButton(palette, onClick = micAction)
                        }
                    }
                    else -> {
                        val sendAction = {
                            val text = input
                            input = ""
                            onSend(text)
                        }
                        if (palette.isDynamic) {
                            FilledIconButton(onClick = sendAction, modifier = Modifier.size(48.dp)) {
                                Icon(Icons.AutoMirrored.Filled.Send, contentDescription = stringResource(R.string.chat_send))
                            }
                        } else {
                            ThemedSendButton(palette, onClick = sendAction)
                        }
                    }
                }
            }
        }
    }
    }

    openArtifact?.let { artifact ->
        ArtifactViewer(artifact, onDismiss = { openArtifact = null })
    }

    viewerTarget?.let { attachment ->
        ImageViewer(attachment, onDismiss = { viewerTarget = null })
    }

    // Object removal via text prompt (Object Removal model).
    cleanupPromptTarget?.let { target ->
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { cleanupPromptTarget = null },
            title = { Text(stringResource(R.string.image_remove_object)) },
            text = {
                OutlinedTextField(
                    value = cleanupPromptText,
                    onValueChange = { cleanupPromptText = it },
                    placeholder = { Text(stringResource(R.string.image_remove_object_hint)) },
                    singleLine = true,
                )
            },
            confirmButton = {
                TextButton(
                    enabled = cleanupPromptText.isNotBlank(),
                    onClick = {
                        val prompt = cleanupPromptText
                        cleanupPromptTarget = null
                        onImageTool(target, com.aispotlight.android.providers.FalImageProvider.Function.OBJECT_CLEANUP, prompt, null)
                    },
                ) { Text(stringResource(R.string.action_ok)) }
            },
            dismissButton = {
                TextButton(onClick = { cleanupPromptTarget = null }) {
                    Text(stringResource(R.string.action_cancel))
                }
            },
        )
    }

    // Object removal via brush mask (Bria Eraser model).
    maskTarget?.let { target ->
        MaskEditorView(
            attachment = target,
            onRun = { maskBase64 ->
                maskTarget = null
                onImageTool(target, com.aispotlight.android.providers.FalImageProvider.Function.OBJECT_CLEANUP, null, maskBase64)
            },
            onDismiss = { maskTarget = null },
        )
    }
}

@Composable
private fun PendingAttachmentChip(
    attachment: ChatAttachment,
    onRemove: () -> Unit,
) {
    val context = LocalContext.current
    val bitmap = remember(attachment.id) { ImageStore.thumbnail(context, attachment, targetPx = 128) }
    Box {
        if (bitmap != null) {
            Image(
                bitmap.asImageBitmap(),
                contentDescription = attachment.filename,
                contentScale = ContentScale.Crop,
                modifier = Modifier
                    .size(64.dp)
                    .clip(RoundedCornerShape(10.dp)),
            )
        }
        IconButton(
            onClick = onRemove,
            modifier = Modifier
                .align(Alignment.TopEnd)
                .size(22.dp)
                .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.8f), CircleShape),
        ) {
            Icon(Icons.Filled.Close, contentDescription = null, modifier = Modifier.size(14.dp))
        }
    }
}

/**
 * The processing button beside a single staged image (the mac
 * ImageAttachmentActionsBar): a full-width styled pill opening the tool menu —
 * upscale / background removal / object cleanup / OCR. Hidden when no tool is
 * configured (no fal.ai and no Mistral key).
 */
@Composable
private fun PendingProcessButton(
    attachment: ChatAttachment,
    onImageTool: (ChatAttachment, com.aispotlight.android.providers.FalImageProvider.Function) -> Unit,
    onRequestCleanup: (ChatAttachment) -> Unit,
    onExtractText: (ChatAttachment) -> Unit,
    modifier: Modifier = Modifier,
) {
    val palette = LocalChatPalette.current
    val falReady = com.aispotlight.android.providers.FalImageProvider.isAvailable
    val ocrReady = com.aispotlight.android.providers.MistralOCRService.isAvailable
    if (!falReady && !ocrReady) return
    var menuOpen by remember { mutableStateOf(false) }
    // Keyboard guard (see the bubble menus): a focusable popup opened while
    // the IME is up dismisses itself on the keyboard-hide resize — hide the
    // keyboard first, open the menu once the inset settles.
    var menuRequested by remember { mutableStateOf(false) }
    val keyboard = androidx.compose.ui.platform.LocalSoftwareKeyboardController.current
    val density = androidx.compose.ui.platform.LocalDensity.current
    val imeInsets = androidx.compose.foundation.layout.WindowInsets.ime
    LaunchedEffect(menuRequested) {
        if (menuRequested) {
            keyboard?.hide()
            androidx.compose.runtime.snapshotFlow { imeInsets.getBottom(density) }
                .first { it == 0 }
            menuOpen = true
            menuRequested = false
        }
    }
    // Same anatomy as the composer's input pill: the theme's input fill,
    // stroke and corner radius (Blueprint's square 4dp, Día's soft round…);
    // dynamic theme keeps the Material tonal pill.
    val shape = if (palette.isDynamic) RoundedCornerShape(12.dp)
        else RoundedCornerShape(palette.inputRadius.dp)
    Box(modifier) {
        Row(
            Modifier
                .fillMaxWidth()
                .clip(shape)
                .background(
                    if (palette.isDynamic) MaterialTheme.colorScheme.surfaceContainerHigh
                    else palette.inputFill
                )
                .then(
                    if (palette.isDynamic) Modifier
                    else Modifier.border(1.dp, palette.inputStroke, shape)
                )
                .clickable { menuRequested = true }
                .padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.Center,
        ) {
            Icon(
                Icons.Filled.AutoFixHigh,
                contentDescription = null,
                tint = if (palette.isDynamic) MaterialTheme.colorScheme.primary else palette.accent,
                modifier = Modifier.size(18.dp),
            )
            Spacer(Modifier.width(8.dp))
            Text(
                stringResource(R.string.attachment_process),
                style = MaterialTheme.typography.labelLarge,
                maxLines = 1,
                color = if (palette.isDynamic) MaterialTheme.colorScheme.onSurface else palette.primaryText,
            )
        }
        ThemedDropdownMenu(
            expanded = menuOpen,
            onDismissRequest = { menuOpen = false },
        ) {
            if (falReady) {
                androidx.compose.material3.DropdownMenuItem(
                    text = { Text(stringResource(R.string.image_upscale)) },
                    onClick = {
                        menuOpen = false
                        onImageTool(attachment, com.aispotlight.android.providers.FalImageProvider.Function.UPSCALE)
                    },
                )
                androidx.compose.material3.DropdownMenuItem(
                    text = { Text(stringResource(R.string.image_remove_bg)) },
                    onClick = {
                        menuOpen = false
                        onImageTool(attachment, com.aispotlight.android.providers.FalImageProvider.Function.REMOVE_BACKGROUND)
                    },
                )
                androidx.compose.material3.DropdownMenuItem(
                    text = { Text(stringResource(R.string.image_remove_object)) },
                    onClick = {
                        menuOpen = false
                        onRequestCleanup(attachment)
                    },
                )
            }
            if (ocrReady) {
                androidx.compose.material3.DropdownMenuItem(
                    text = { Text(stringResource(R.string.image_extract_text)) },
                    onClick = {
                        menuOpen = false
                        onExtractText(attachment)
                    },
                )
            }
        }
    }
}

@Composable
private fun MessageBubble(
    message: ChatMessage,
    isStreamingReply: Boolean = false,
    onOpenArtifact: (Artifact) -> Unit,
    onImageTool: (ChatAttachment, com.aispotlight.android.providers.FalImageProvider.Function, String?) -> Unit,
    onRequestCleanup: (ChatAttachment) -> Unit,
    onSaveToGallery: (ChatAttachment) -> Unit,
    onExtractText: (ChatAttachment) -> Unit = {},
    onOpenImage: (ChatAttachment) -> Unit = {},
    modifier: Modifier = Modifier,
) {
    val isUser = message.isUser
    val palette = LocalChatPalette.current
    // Per-corner radii from the theme spec (Corners) — uniform for most
    // themes, asymmetric for Sakura; the dynamic (glass) look keeps the mac
    // Current theme's uniform 16.
    val corners = if (isUser) palette.userCorners else palette.assistantCorners
    val themed = !palette.isDynamic && !message.isError
    val shape = if (themed) {
        RoundedCornerShape(
            topStart = corners.topStart.dp, topEnd = corners.topEnd.dp,
            bottomEnd = corners.bottomEnd.dp, bottomStart = corners.bottomStart.dp,
        )
    } else {
        RoundedCornerShape(16.dp)
    }
    val clipboard = androidx.compose.ui.platform.LocalClipboardManager.current
    val stroke = if (themed) (if (isUser) palette.userStroke else palette.assistantStroke) else null
    // Telegram-style bubble metrics: text bubbles hug content up to ~82% of
    // the screen (capped for tablets); a voice message imposes a wide fixed
    // floor (~72%, cap 320dp) so the waveform + timestamp always get room —
    // a different minimum than text-only bubbles, which can stay tiny.
    val screenWidthDp = androidx.compose.ui.platform.LocalConfiguration.current.screenWidthDp
    // Wide-screen cap at 500dp: on an unfolded foldable or tablet a bubble
    // must not stretch into a full-width reading ribbon — the extra room
    // becomes margin, not line length.
    val bubbleMaxWidth = (screenWidthDp * 0.82f).dp.coerceAtMost(500.dp)
    val voiceContentWidth = (screenWidthDp * 0.72f).dp.coerceAtMost(320.dp)
    val context = LocalContext.current
    val haptics = androidx.compose.ui.platform.LocalHapticFeedback.current
    // Long-press context menu (the Telegram/WhatsApp convention) + a "select
    // text" escape hatch for partial copies (the ChatGPT pattern).
    var showMenu by remember { mutableStateOf(false) }
    var showSelectText by remember { mutableStateOf(false) }
    // Keyboard guard (same as the attachment menus): a focusable popup opened
    // while the IME is up dismisses itself on the keyboard-hide resize.
    var menuRequested by remember { mutableStateOf(false) }
    val keyboard = androidx.compose.ui.platform.LocalSoftwareKeyboardController.current
    val density = androidx.compose.ui.platform.LocalDensity.current
    val imeInsets = androidx.compose.foundation.layout.WindowInsets.ime
    LaunchedEffect(menuRequested) {
        if (menuRequested) {
            keyboard?.hide()
            androidx.compose.runtime.snapshotFlow { imeInsets.getBottom(density) }
                .first { it == 0 }
            showMenu = true
            menuRequested = false
        }
    }
    // Copy confirmation is ALWAYS ours: the Android 13+ system clipboard
    // overlay is suppressed or barely visible on many OEM skins, so relying
    // on it reads as "the tap did nothing".
    var justCopied by remember { mutableStateOf(false) }
    LaunchedEffect(justCopied) {
        if (justCopied) {
            kotlinx.coroutines.delay(1500)
            justCopied = false
        }
    }

    fun copyMessage() {
        clipboard.setText(androidx.compose.ui.text.AnnotatedString(message.text))
        justCopied = true
        android.widget.Toast.makeText(
            context, context.getString(R.string.artifact_copied), android.widget.Toast.LENGTH_SHORT
        ).show()
    }
    Column(
        modifier.fillMaxWidth(),
        horizontalAlignment = if (isUser) Alignment.End else Alignment.Start,
    ) {
        Box {
        Surface(
            color = when {
                message.isError -> MaterialTheme.colorScheme.errorContainer
                themed -> androidx.compose.ui.graphics.Color.Transparent
                isUser -> MaterialTheme.colorScheme.primaryContainer
                else -> MaterialTheme.colorScheme.surfaceVariant
            },
            shape = shape,
            modifier = Modifier
                // Telegram-style dynamic sizing: text bubbles hug their
                // content up to ~82% of the screen; voice bubbles get a
                // fixed wide floor from the player below.
                .widthIn(max = bubbleMaxWidth)
                // Synthwave dark: neon glow around the user bubble.
                .then(if (themed && isUser && palette.userGlow != null) {
                    Modifier.themedGlow(palette.userGlow, 7.dp, cornerRadius = corners.topStart.dp)
                } else Modifier)
                .then(when {
                    themed && isUser -> Modifier.background(palette.userBrush, shape)
                    themed -> Modifier.background(palette.assistantFill, shape)
                    else -> Modifier
                })
                .bubbleStroke(shape, stroke, minOf(corners.bottomStart, corners.bottomEnd).dp)
                .combinedClickable(
                    onClick = {},
                    onLongClick = {
                        if (message.text.isNotEmpty()) {
                            haptics.performHapticFeedback(androidx.compose.ui.hapticfeedback.HapticFeedbackType.LongPress)
                            menuRequested = true
                        }
                    },
                ),
        ) {
            Column(
                Modifier
                    // Voice bubbles size to their widest block (transcript /
                    // markdown), and the player below stretches to match, so
                    // the waveform always reaches the bubble edge.
                    .then(if (message.audioPath != null) {
                        Modifier.width(androidx.compose.foundation.layout.IntrinsicSize.Max)
                    } else Modifier)
                    .padding(horizontal = 14.dp, vertical = 10.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                // Assistant icon INSIDE the bubble, at the top (mac layout):
                // the brain for dynamic, a themed glyph — or the pumpkin /
                // sugar-skull art — for the decorative themes.
                if (!isUser && !message.isError) {
                    when {
                        palette.isDynamic -> Icon(
                            Icons.Outlined.Psychology,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.primary,
                            modifier = Modifier.size(16.dp),
                        )
                        palette.themeID == ChatThemeID.HALLOWEEN ->
                            PumpkinIconArt(palette.dark, Modifier.size(15.dp))
                        palette.themeID == ChatThemeID.DIA_DE_MUERTOS ->
                            SugarSkullArt(palette.dark, Modifier.size(16.dp, 17.dp))
                        palette.assistantGlyph.isNotEmpty() -> Text(
                            palette.assistantGlyph,
                            color = palette.glyphColor,
                            style = MaterialTheme.typography.labelMedium,
                        )
                    }
                }
                // Image thumbnails (long-press → image tools / save)
                for (attachment in message.attachments) {
                    AttachmentThumbnail(
                        attachment, onImageTool, onRequestCleanup, onSaveToGallery, onExtractText,
                        onOpen = onOpenImage,
                    )
                }
                // Voice message: inline player above the transcript. Its width
                // adapts to the screen and sets the bubble's voice floor; the
                // waveform bar count and the timestamp follow that width.
                message.audioPath?.let {
                    // Floor keeps voice-only bubbles wide enough for the
                    // waveform; fillMaxWidth stretches the player to the
                    // bubble's intrinsic width when text below is wider.
                    VoiceMessagePlayer(
                        it, isUser = isUser,
                        modifier = Modifier.widthIn(min = voiceContentWidth).fillMaxWidth(),
                    )
                }
                if (isUser) {
                    if (message.text.isNotEmpty()) {
                        Text(
                            message.text,
                            style = MaterialTheme.typography.bodyLarge,
                            color = if (themed) palette.userText else androidx.compose.ui.graphics.Color.Unspecified,
                        )
                    }
                } else {
                    val parsed = remember(message.text) { parseArtifacts(message.text) }
                    if (parsed.plainText.isNotEmpty()) {
                        MarkdownText(parsed.plainText, isStreaming = isStreamingReply)
                    }
                    for (artifact in parsed.artifacts) {
                        ArtifactCard(artifact, isStreaming = isStreamingReply, onOpen = { onOpenArtifact(artifact) })
                    }
                }
            }
        }
        androidx.compose.material3.DropdownMenu(
            expanded = showMenu,
            onDismissRequest = { showMenu = false },
        ) {
            androidx.compose.material3.DropdownMenuItem(
                text = { Text(stringResource(R.string.action_copy)) },
                leadingIcon = { Icon(Icons.Filled.ContentCopy, contentDescription = null) },
                onClick = {
                    showMenu = false
                    copyMessage()
                },
            )
            androidx.compose.material3.DropdownMenuItem(
                text = { Text(stringResource(R.string.action_select_text)) },
                leadingIcon = { Icon(Icons.Filled.SelectAll, contentDescription = null) },
                onClick = {
                    showMenu = false
                    showSelectText = true
                },
            )
            androidx.compose.material3.DropdownMenuItem(
                text = { Text(stringResource(R.string.action_share)) },
                leadingIcon = { Icon(Icons.Filled.Share, contentDescription = null) },
                onClick = {
                    showMenu = false
                    val intent = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
                        type = "text/plain"
                        putExtra(android.content.Intent.EXTRA_TEXT, message.text)
                    }
                    context.startActivity(android.content.Intent.createChooser(intent, null))
                },
            )
        }
        }
        // Partial copies: the whole message in a selection container — the
        // ChatGPT "Select text" pattern (cross-block selection in the bubble
        // itself is unreliable in Compose, same as SwiftUI on the mac).
        if (showSelectText) {
            androidx.compose.material3.AlertDialog(
                onDismissRequest = { showSelectText = false },
                confirmButton = {
                    TextButton(onClick = { showSelectText = false }) {
                        Text(stringResource(R.string.action_close))
                    }
                },
                text = {
                    androidx.compose.foundation.text.selection.SelectionContainer {
                        Text(
                            message.text,
                            modifier = Modifier.verticalScroll(rememberScrollState()),
                        )
                    }
                },
            )
        }
        // Timestamp UNDER the bubble (mac layout), in the theme's signature
        // style: [22:08] mono, 22:08:14, 10:08 PM letter-spaced, 10:08 ✿ …
        // Assistant replies carry a small copy icon beside it — the industry
        // action-row pattern (ChatGPT/Claude/Gemini), one action deep.
        Row(verticalAlignment = Alignment.CenterVertically) {
        Text(
            formatTimestamp(message.timestamp, palette.timestampStyle),
            style = MaterialTheme.typography.labelSmall.let {
                if (palette.timestampMono || palette.monospace) {
                    it.copy(fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace)
                } else it
            }.let {
                if (palette.timestampStyle == TimestampStyle.UPPER_MERIDIEM) {
                    it.copy(letterSpacing = androidx.compose.ui.unit.TextUnit(1.5f, androidx.compose.ui.unit.TextUnitType.Sp))
                } else it
            },
            color = if (themed) palette.timestampColor else MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 3.dp, start = 2.dp, end = 2.dp),
        )
        if (!isUser && !message.isError && message.text.isNotEmpty() && !isStreamingReply) {
            Icon(
                if (justCopied) Icons.Filled.Check else Icons.Filled.ContentCopy,
                contentDescription = stringResource(R.string.action_copy),
                tint = if (justCopied) {
                    if (themed) palette.accent else MaterialTheme.colorScheme.primary
                } else {
                    (if (themed) palette.timestampColor else MaterialTheme.colorScheme.onSurfaceVariant)
                        .copy(alpha = 0.8f)
                },
                modifier = Modifier
                    .padding(top = 3.dp, start = 8.dp)
                    .size(13.dp)
                    .clickable(enabled = !justCopied) { copyMessage() },
            )
        }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun AttachmentThumbnail(
    attachment: ChatAttachment,
    onImageTool: (ChatAttachment, com.aispotlight.android.providers.FalImageProvider.Function, String?) -> Unit,
    onRequestCleanup: (ChatAttachment) -> Unit,
    onSaveToGallery: (ChatAttachment) -> Unit,
    onExtractText: (ChatAttachment) -> Unit = {},
    onOpen: (ChatAttachment) -> Unit = {},
) {
    val context = LocalContext.current
    val bitmap = remember(attachment.id) { ImageStore.thumbnail(context, attachment, targetPx = 512) }
    var menuOpen by remember { mutableStateOf(false) }
    // Same keyboard guard as the pending chip: a focusable popup opened while
    // the IME is up dismisses itself on the keyboard-hide resize.
    var menuRequested by remember { mutableStateOf(false) }
    val keyboard = androidx.compose.ui.platform.LocalSoftwareKeyboardController.current
    val density = androidx.compose.ui.platform.LocalDensity.current
    val imeInsets = androidx.compose.foundation.layout.WindowInsets.ime
    LaunchedEffect(menuRequested) {
        if (menuRequested) {
            keyboard?.hide()
            androidx.compose.runtime.snapshotFlow { imeInsets.getBottom(density) }
                .first { it == 0 }
            menuOpen = true
            menuRequested = false
        }
    }
    if (bitmap != null) {
        Box {
            // Telegram-style preview metrics: keep the image's own aspect
            // ratio inside 300×340dp caps instead of cropping into a fixed
            // full-width 180dp ribbon (which on a foldable/tablet blew the
            // photo up into a wall-to-wall sliver).
            val aspect = bitmap.width.toFloat() / bitmap.height.toFloat()
            Image(
                bitmap.asImageBitmap(),
                contentDescription = attachment.filename,
                contentScale = ContentScale.Fit,
                modifier = Modifier
                    .widthIn(max = 300.dp)
                    .heightIn(max = 340.dp)
                    .aspectRatio(aspect, matchHeightConstraintsFirst = aspect < 1f)
                    .clip(RoundedCornerShape(12.dp))
                    .combinedClickable(
                        // Tap = full-screen zoomable preview; long-press = tools.
                        onClick = { onOpen(attachment) },
                        onLongClick = { menuRequested = true },
                    ),
            )
            ThemedDropdownMenu(
                expanded = menuOpen,
                onDismissRequest = { menuOpen = false },
            ) {
                val falReady = com.aispotlight.android.providers.FalImageProvider.isAvailable
                if (falReady) {
                    androidx.compose.material3.DropdownMenuItem(
                        text = { Text(stringResource(R.string.image_upscale)) },
                        onClick = {
                            menuOpen = false
                            onImageTool(attachment, com.aispotlight.android.providers.FalImageProvider.Function.UPSCALE, null)
                        },
                    )
                    androidx.compose.material3.DropdownMenuItem(
                        text = { Text(stringResource(R.string.image_remove_bg)) },
                        onClick = {
                            menuOpen = false
                            onImageTool(attachment, com.aispotlight.android.providers.FalImageProvider.Function.REMOVE_BACKGROUND, null)
                        },
                    )
                    androidx.compose.material3.DropdownMenuItem(
                        text = { Text(stringResource(R.string.image_remove_object)) },
                        onClick = {
                            menuOpen = false
                            onRequestCleanup(attachment)
                        },
                    )
                }
                // OCR "Extract text" (the mac pending-attachment action):
                // layout-aware markdown lands in the chat as a structured,
                // copyable bubble. Mistral-only on Android (ML Kit lacks
                // Cyrillic), so gated on the Mistral key.
                if (com.aispotlight.android.providers.MistralOCRService.isAvailable) {
                    androidx.compose.material3.DropdownMenuItem(
                        text = { Text(stringResource(R.string.image_extract_text)) },
                        onClick = {
                            menuOpen = false
                            onExtractText(attachment)
                        },
                    )
                }
                androidx.compose.material3.DropdownMenuItem(
                    text = { Text(stringResource(R.string.image_save_gallery)) },
                    onClick = {
                        menuOpen = false
                        onSaveToGallery(attachment)
                    },
                )
            }
        }
    }
}

/** Empty-chat welcome (the mac panel's greeting). */
@Composable
private fun WelcomeCard() {
    val palette = LocalChatPalette.current
    Column(
        Modifier.fillMaxWidth().padding(vertical = 48.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        // The old ✳️ ornament is gone, but its slot keeps its exact height
        // (alpha 0) so the greeting text below doesn't shift.
        Text("✳️", style = MaterialTheme.typography.headlineLarge, modifier = Modifier.alpha(0f))
        Spacer(Modifier.size(8.dp))
        Text(
            stringResource(R.string.chat_welcome_title),
            style = MaterialTheme.typography.titleMedium,
            color = if (palette.isDynamic) MaterialTheme.colorScheme.onBackground else palette.primaryText,
        )
        Text(
            stringResource(R.string.chat_welcome_body),
            style = MaterialTheme.typography.bodySmall,
            color = if (palette.isDynamic) MaterialTheme.colorScheme.onSurfaceVariant else palette.secondaryText,
        )
    }
}

/** Port of the macOS per-theme timestamp formats (POSIX-stable patterns). */
private fun formatTimestamp(timestamp: Long, style: TimestampStyle): String {
    val date = java.util.Date(timestamp)
    // en-US-POSIX analog: the themed formats are part of the design and must
    // not drift with the device locale (mac uses en_US_POSIX formatters too).
    fun fmt(pattern: String) = java.text.SimpleDateFormat(pattern, java.util.Locale.US).format(date)
    val calendar = java.util.Calendar.getInstance().apply { time = date }
    return when (style) {
        TimestampStyle.PLAIN -> fmt("HH:mm")
        TimestampStyle.BRACKETED -> "[${fmt("HH:mm")}]"
        TimestampStyle.SECONDS -> fmt("HH:mm:ss")
        TimestampStyle.UPPER_MERIDIEM -> fmt("hh:mm a").uppercase()
        // Halloween: «10:08 p.m.» — meridiem computed by hour, like the mac.
        TimestampStyle.LOWER_MERIDIEM ->
            "${fmt("hh:mm")} ${if (calendar.get(java.util.Calendar.HOUR_OF_DAY) < 12) "a.m." else "p.m."}"
        TimestampStyle.FLOWER -> "${fmt("HH:mm")} ✿"
    }
}

/**
 * "Thinking…" indicator: the themed five-bar equalizer (see ThinkingEqualizer
 * in Decorations.kt — a 1:1 port of the mac ThinkingIndicator) + status line.
 */
@Composable
private fun ThinkingIndicator(status: String) {
    val palette = LocalChatPalette.current
    Row(verticalAlignment = Alignment.CenterVertically) {
        ThinkingEqualizer(palette, accentFallback = MaterialTheme.colorScheme.primary)
        Spacer(Modifier.size(8.dp))
        Text(
            status,
            style = MaterialTheme.typography.bodySmall,
            color = if (palette.isDynamic) MaterialTheme.colorScheme.onSurfaceVariant else palette.secondaryText,
        )
    }
}

/**
 * Themed mic button (mac EnhancedVoiceButton idle look): shape follows
 * `composerButtonRadius` (null → circle), `micDashed` picks the dashed (Día)
 * vs solid (Blueprint/Terminal/…) outline, fill and glyph from the palette.
 */
@Composable
private fun ThemedMicButton(palette: ChatPalette, onClick: () -> Unit) {
    val shape = palette.composerButtonRadius?.let { RoundedCornerShape(it.dp) } ?: CircleShape
    val border = palette.micStroke ?: palette.micColor ?: palette.accent
    Box(
        Modifier
            .size(48.dp)
            .padding(4.dp)
            .then(
                if (palette.micDashed) {
                    // Dashed outline over a soft tinted fill (Día).
                    Modifier
                        .background(
                            if (palette.dark) border.copy(alpha = 0.15f) else Color.White.copy(alpha = 0.5f),
                            shape,
                        )
                        .dashedBorder(border.copy(alpha = 0.7f), shape)
                } else {
                    Modifier
                        .background(palette.micFill ?: Color.White.copy(alpha = 0.5f), shape)
                        .border(1.dp, palette.micStroke ?: palette.inputStroke, shape)
                }
            )
            .clip(shape)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            Icons.Filled.Mic,
            contentDescription = stringResource(R.string.chat_dictate),
            tint = palette.micGlyphColor ?: palette.micColor ?: palette.accent,
            modifier = Modifier.size(20.dp),
        )
    }
}

/** Dashed 1.5dp [1,3] outline — the Día mic ring. */
private fun Modifier.dashedBorder(color: Color, shape: androidx.compose.ui.graphics.Shape): Modifier =
    drawBehind {
        val outline = shape.createOutline(size, layoutDirection, this)
        drawOutline(
            outline,
            color = color,
            style = androidx.compose.ui.graphics.drawscope.Stroke(
                width = 1.5.dp.toPx(),
                cap = androidx.compose.ui.graphics.StrokeCap.Round,
                pathEffect = androidx.compose.ui.graphics.PathEffect.dashPathEffect(
                    floatArrayOf(1.dp.toPx(), 3.dp.toPx())
                ),
            ),
        )
    }

/**
 * Themed send button: the glowing jack-o'-lantern for Halloween, the marigold
 * flower for Día, otherwise a circle / Blueprint rounded square in the
 * palette's fill (gradient on Synthwave/Pastel) with its neon glow.
 */
@Composable
private fun ThemedSendButton(palette: ChatPalette, onClick: () -> Unit) {
    val description = stringResource(R.string.chat_send)
    when (palette.themeID) {
        ChatThemeID.HALLOWEEN -> {
            // Glowing jack-o'-lantern send button (spec §2a).
            Box(
                Modifier
                    .size(48.dp)
                    .padding(5.dp)
                    .themedGlow(palette.sendGlow, if (palette.dark) 8.dp else 6.dp,
                        cornerRadius = 16.dp, yOffset = if (palette.dark) 0.dp else 2.dp)
                    .clip(CircleShape)
                    .clickable(onClick = onClick),
                contentAlignment = Alignment.Center,
            ) {
                JackOLanternArt(palette.dark, Modifier.size(34.dp, 32.dp))
            }
        }
        ChatThemeID.DIA_DE_MUERTOS -> {
            // Marigold flower send button (with glow + white sparkle).
            Box(
                Modifier
                    .size(48.dp)
                    .padding(5.dp)
                    .themedGlow(palette.sendGlow, 6.dp, cornerRadius = 17.dp)
                    .clip(CircleShape)
                    .clickable(onClick = onClick),
                contentAlignment = Alignment.Center,
            ) {
                MarigoldFlowerArt(palette.dark, withInner = true, withSparkle = true,
                    modifier = Modifier.size(34.dp))
            }
        }
        else -> {
            val shape = palette.composerButtonRadius?.let { RoundedCornerShape(it.dp) } ?: CircleShape
            Box(
                Modifier
                    .size(48.dp)
                    .padding(4.dp)
                    .themedGlow(palette.sendGlow, 6.dp,
                        cornerRadius = palette.composerButtonRadius?.dp ?: 16.dp)
                    .background(palette.sendBrush, shape)
                    .clip(shape)
                    .clickable(onClick = onClick),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.AutoMirrored.Filled.Send,
                    contentDescription = description,
                    tint = palette.sendGlyph,
                    modifier = Modifier.size(18.dp),
                )
            }
        }
    }
}
