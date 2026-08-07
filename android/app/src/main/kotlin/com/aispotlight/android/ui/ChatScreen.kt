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
import androidx.compose.foundation.layout.fillMaxHeight
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
import androidx.compose.material.icons.filled.BrokenImage
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.SelectAll
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.PushPin
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
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
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
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import com.aispotlight.android.R
import com.aispotlight.android.data.ChatAttachment
import com.aispotlight.android.data.ChatMessage
import com.aispotlight.android.data.ImageStore
import java.io.File

/**
 * Widest the chat column is ever laid out, however much room the window has.
 * A conversation is read like a column of text: past a comfortable measure the
 * extra width stops helping and starts hurting — the two speakers drift to
 * opposite edges of an 11" tablet with a void between them. Anything wider
 * becomes margin. Phones and folded foldables never reach this cap, so their
 * layout is untouched; the header (MainActivity's floating pills) shares it so
 * the whole screen reads as one column.
 */
val ChatContentMaxWidth = 720.dp

/**
 * Width of the chat column the content actually lives in — bubbles, media and
 * the voice player size against THIS, never against the raw window. On a
 * tablet the two differ by a factor of two, and sizing against the window is
 * what made every element look inflated while the conversation itself fell
 * apart.
 */
val LocalChatContentWidth = androidx.compose.runtime.compositionLocalOf { 400.dp }

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
    /** Any non-image file (documents, archives…) staged as an attachment. */
    onAttachFile: (Uri) -> Unit = {},
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
    /** Identity of the conversation on screen — the bottom-landing anchor. */
    conversationKey: String = "",
    /** Agent (Hermes) chat plumbing: skills autocomplete, pins, step details. */
    isHermes: Boolean = false,
    hermesSkills: List<com.aispotlight.android.hermes.HermesSkill> = emptyList(),
    pinnedMessages: List<ChatMessage> = emptyList(),
    onTogglePin: ((ChatMessage) -> Unit)? = null,
    /** Pages the pin into the window; returns its index in the list (or -1). */
    onLocatePin: suspend (String) -> Int = { -1 },
    onStepDetails: (suspend (String) -> List<com.aispotlight.android.hermes.HermesChatService.StepDetail>)? = null,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val palette = LocalChatPalette.current
    var input by rememberSaveable { mutableStateOf("") }
    val listState = rememberLazyListState()
    // One voice transport for the whole chat: a single active playback,
    // auto-advance down the queue (oldest → newest) on completion.
    val voicePlayback = remember { VoicePlaybackCoordinator() }
    androidx.compose.runtime.SideEffect {
        voicePlayback.queue = messages.mapNotNull { it.audioPath }
    }
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

    // Pin-to-bottom is an INVARIANT, not an animation (the desktop 3.20
    // contract): the list follows the stream only while the user is at the
    // bottom. "At the bottom" = the last item is still on screen — a growing
    // streamed bubble keeps that true while its own bottom runs past the
    // viewport, so following continues; scrolling up past the last bubble
    // detaches. There is no flag to clear: the derived check re-attaches the
    // moment the user returns (or taps the jump-to-latest button).
    val pinnedToBottom by remember {
        derivedStateOf {
            val info = listState.layoutInfo
            val lastVisible = info.visibleItemsInfo.lastOrNull()
            lastVisible == null || lastVisible.index >= info.totalItemsCount - 1
        }
    }

    // Follow the stream — keyed on the LAST message (id + streamed length),
    // not the list size, so prepending an older page never yanks the view
    // down. The FIRST fill of a conversation (cold start, chat switch) LANDS
    // on the last message instantly — the old animate-from-the-top scrolled
    // the whole history past the eyes. Scroll targets use the LAYOUT index
    // (totalItemsCount - 1), not messages.size - 1: the load-older row and
    // the thinking indicator are list items too.
    val lastMessage = messages.lastOrNull()
    // Anchored PER CONVERSATION, not once per screen: a thread switch swaps
    // the message list without an empty gap, so a plain boolean never reset
    // and an opened Hermes session landed wherever the old scroll offset
    // was — the top (e2e 2026-07-27). A changed key = a fresh landing on
    // the newest message, instantly.
    var anchoredKey by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(conversationKey, lastMessage?.id, lastMessage?.text?.length) {
        if (lastMessage == null) {
            // Conversation switch in flight: the list was reset — the next
            // fill is a fresh landing, not a new-message follow.
            anchoredKey = null
            return@LaunchedEffect
        }
        val lastIndex = (listState.layoutInfo.totalItemsCount - 1).coerceAtLeast(0)
        when {
            anchoredKey != conversationKey -> {
                listState.scrollToItem(lastIndex)
                anchoredKey = conversationKey
            }
            // The user's own send always returns to the bottom; a streaming
            // reply follows only while the reader stays pinned — it never
            // yanks back someone who scrolled up to reread.
            lastMessage.isUser || pinnedToBottom ->
                listState.animateScrollToItem(lastIndex)
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

    // The composer's attach button opens ONE sheet (gallery grid + camera +
    // any file) — the Telegram model. The old split (photo picker in the ⋮
    // menu, a separate agent-only file item) made "attach" mean two
    // different things depending on the chat you were in.
    var showAttachSheet by remember { mutableStateOf(false) }
    // The sheet and the IME must not fight over the bottom of the screen:
    // the keyboard goes down as the sheet comes up.
    val composerKeyboard = androidx.compose.ui.platform.LocalSoftwareKeyboardController.current

    // Camera capture (FileProvider) — launched from the sheet's camera tile.
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

    // Wide screens get MARGINS, not a wider conversation. Left to fill an 11"
    // tablet the column pins the two speakers to opposite edges with half a
    // screen of void between them, and the composer becomes a one-line field an
    // arm's length wide. Capped, everything inside measures exactly as it does
    // on a phone (where the cap never binds).
    val contentWidth = minOf(
        androidx.compose.ui.platform.LocalConfiguration.current.screenWidthDp.dp,
        ChatContentMaxWidth,
    )
    androidx.compose.runtime.CompositionLocalProvider(
        LocalChatContentWidth provides contentWidth
    ) {
    Box(modifier.fillMaxSize().then(themedModifier)) {
        // Theme ornaments (petals, sparkles, webs, papel picado) — fixed spec
        // positions with gentle animation loops, behind the chat content.
        // Deliberately OUTSIDE the capped column: the decoration is part of the
        // background and keeps running to the screen edges.
        ThemeDecorationsOverlay(palette.decoration, palette.dark)
        // Blueprint's reference crosses in the four panel corners.
        palette.cornerMarkColor?.let { BlueprintCornerMarks(it) }
        // Full-bleed layout: the themed background runs under the system bars;
        // content respects them. Extra top padding clears the floating header
        // pills — messages scroll beneath them.
        Column(
            Modifier
                .fillMaxHeight()
                .widthIn(max = ChatContentMaxWidth)
                .fillMaxWidth()
                .align(Alignment.TopCenter)
                .systemBarsPadding()
                .imePadding()
        ) {
        Box(Modifier.weight(1f).fillMaxWidth()) {
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize(),
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
                    voicePlayback = voicePlayback,
                    // HTML opens like a normal link — the real browser
                    // (the in-app WebView starved CDN pages); Markdown
                    // keeps the in-app preview.
                    onOpenArtifact = {
                        if (it.kind == Artifact.Kind.HTML) openInBrowser(context, it)
                        else openArtifact = it
                    },
                    onImageTool = { attachment, function, prompt ->
                        onImageTool(attachment, function, prompt, null)
                    },
                    onRequestCleanup = requestCleanup,
                    onSaveToGallery = onSaveToGallery,
                    onExtractText = onExtractText,
                    onOpenImage = { viewerTarget = it },
                    isHermes = isHermes,
                    onTogglePin = onTogglePin,
                    onStepDetails = onStepDetails,
                    // Smooth appearance/reorder — the mac panel's insert animation.
                    modifier = Modifier.animateItem(),
                )
            }
            if (statusText != null) {
                item(key = "thinking") { ThinkingIndicator(statusText) }
            }
        }

        // Pinned-messages bar (Telegram semantics, the desktop 4.2 bar): the
        // snippet of the target pin + k/n under the floating header. Tap
        // mechanics mirror the desktop exactly: if the shown pin is
        // off-screen the first tap brings you TO it; cycling to the next pin
        // only starts once the current target is in view. ✕ unpins the shown
        // one. Pins outside the loaded window page themselves in.
        if (pinnedMessages.isNotEmpty()) {
            var pinCursor by remember(pinnedMessages.size) { mutableStateOf(0) }
            val cursorIndex = pinCursor % pinnedMessages.size
            val currentPin = pinnedMessages[cursorIndex]
            val pinScope = rememberCoroutineScope()
            Surface(
                onClick = {
                    pinScope.launch {
                        val index = onLocatePin(currentPin.id)
                        if (index < 0) return@launch
                        val layoutIndex = index + if (hasOlderMessages) 1 else 0
                        val visible = listState.layoutInfo.visibleItemsInfo
                            .any { it.index == layoutIndex }
                        if (visible && pinnedMessages.size > 1) {
                            val next = (cursorIndex + 1) % pinnedMessages.size
                            val nextIndex = onLocatePin(pinnedMessages[next].id)
                            if (nextIndex >= 0) {
                                listState.animateScrollToItem(
                                    nextIndex + if (hasOlderMessages) 1 else 0
                                )
                            }
                            pinCursor = next
                        } else {
                            listState.animateScrollToItem(layoutIndex)
                            pinCursor = cursorIndex
                        }
                    }
                },
                shape = RoundedCornerShape(12.dp),
                color = MaterialTheme.colorScheme.surface.copy(alpha = 0.92f),
                shadowElevation = 2.dp,
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .padding(top = 54.dp, start = 12.dp, end = 12.dp)
                    .fillMaxWidth(),
            ) {
                Row(
                    Modifier.padding(start = 12.dp, end = 4.dp, top = 4.dp, bottom = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(
                        Icons.Filled.PushPin,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.size(16.dp),
                    )
                    Spacer(Modifier.width(8.dp))
                    Text(
                        currentPin.text.replace("\n", " ").take(80),
                        style = MaterialTheme.typography.bodySmall,
                        maxLines = 1,
                        overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                    if (pinnedMessages.size > 1) {
                        Spacer(Modifier.width(8.dp))
                        Text(
                            "${cursorIndex + 1}/${pinnedMessages.size}",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    // ✕ unpins the SHOWN pin and resets the cycle (desktop).
                    onTogglePin?.let { toggle ->
                        IconButton(
                            onClick = {
                                toggle(currentPin)
                                pinCursor = 0
                            },
                            modifier = Modifier.size(32.dp),
                        ) {
                            Icon(
                                Icons.Filled.Close,
                                contentDescription = stringResource(R.string.action_unpin),
                                modifier = Modifier.size(14.dp),
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }
            }
        }

        // Jump-to-latest: the way back after detaching from the bottom mid-
        // stream (the desktop 3.20 affordance). Sits above the composer edge;
        // tapping re-pins, and the derived pinnedToBottom hides it again.
        androidx.compose.animation.AnimatedVisibility(
            visible = anchoredKey == conversationKey && !pinnedToBottom,
            enter = androidx.compose.animation.fadeIn(),
            exit = androidx.compose.animation.fadeOut(),
            modifier = Modifier.align(Alignment.BottomEnd).padding(end = 16.dp, bottom = 12.dp),
        ) {
            val scope = rememberCoroutineScope()
            Surface(
                onClick = {
                    scope.launch {
                        val lastIndex = (listState.layoutInfo.totalItemsCount - 1).coerceAtLeast(0)
                        listState.animateScrollToItem(lastIndex)
                    }
                },
                shape = CircleShape,
                color = MaterialTheme.colorScheme.secondaryContainer,
                shadowElevation = 4.dp,
            ) {
                Icon(
                    Icons.Filled.KeyboardArrowDown,
                    contentDescription = stringResource(R.string.chat_jump_latest),
                    tint = MaterialTheme.colorScheme.onSecondaryContainer,
                    modifier = Modifier.padding(8.dp).size(24.dp),
                )
            }
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

        // `/` skills autocomplete (agent chats, desktop 4.0): prefix-filtered
        // agent skills with descriptions; a tap completes the command.
        if (isHermes && input.startsWith("/") && !input.contains(' ') && hermesSkills.isNotEmpty()) {
            val query = input.drop(1)
            val matches = hermesSkills
                .filter { it.name.startsWith(query, ignoreCase = true) }
                .take(6)
            if (matches.isNotEmpty()) {
                Column(
                    Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 12.dp, vertical = 4.dp),
                ) {
                    for (skill in matches) {
                        Column(
                            Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(10.dp))
                                .clickable { input = "/${skill.name} " }
                                .padding(horizontal = 10.dp, vertical = 6.dp),
                        ) {
                            Text(
                                "/${skill.name}",
                                style = MaterialTheme.typography.bodyMedium,
                                fontWeight = androidx.compose.ui.text.font.FontWeight.Bold,
                            )
                            if (skill.description.isNotEmpty()) {
                                Text(
                                    skill.description,
                                    style = MaterialTheme.typography.bodySmall,
                                    maxLines = 1,
                                    overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        }
                    }
                }
            }
        }

        // Session model + reasoning effort moved to the top-bar ⋮ menu
        // (2026-07-27): the composer chips ate a whole row of screen for
        // controls touched once per session.

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
                // Attach inside the pill, bottom-anchored (Telegram's attach
                // slot): opens the sheet — recent photos, camera, any file.
                IconButton(
                    onClick = {
                        composerKeyboard?.hide()
                        showAttachSheet = true
                    },
                    modifier = Modifier.size(48.dp),
                ) {
                    Icon(
                        Icons.Filled.AttachFile,
                        contentDescription = stringResource(R.string.chat_attach),
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
    }

    if (showAttachSheet) {
        AttachmentSheet(
            onAttachImages = { uris -> uris.forEach(onAttachImage) },
            onCamera = {
                showAttachSheet = false
                val dir = File(context.cacheDir, "camera").apply { mkdirs() }
                val file = File(dir, "capture-${System.currentTimeMillis()}.jpg")
                val uri = FileProvider.getUriForFile(context, context.packageName + ".fileprovider", file)
                cameraTarget = uri to file
                cameraLauncher.launch(uri)
            },
            onAttachFile = onAttachFile,
            onDismiss = { showAttachSheet = false },
        )
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
    val isImage = attachment.mimeType.startsWith("image")
    val bitmap = remember(attachment.id) {
        if (isImage) ImageStore.thumbnail(context, attachment, targetPx = 128) else null
    }
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
        } else {
            // Non-image file staged for the agent courier: a filename pill
            // (desktop 4.2 "pills above the composer").
            Row(
                Modifier
                    .clip(RoundedCornerShape(10.dp))
                    .background(MaterialTheme.colorScheme.surfaceVariant)
                    .padding(start = 10.dp, end = 26.dp, top = 10.dp, bottom = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    Icons.Filled.AttachFile,
                    contentDescription = null,
                    modifier = Modifier.size(16.dp),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.width(6.dp))
                Text(
                    attachment.filename,
                    style = MaterialTheme.typography.bodySmall,
                    maxLines = 1,
                    overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                    modifier = Modifier.widthIn(max = 140.dp),
                )
            }
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

/**
 * The folded transcript of a voice bubble: a compact chevron row that expands
 * to the full text. The text is ALWAYS reachable this way — including while
 * the reply is still being voiced and after a failed synthesis — the audio is
 * a presentation on top of it, never a gate.
 */
@Composable
private fun TranscriptDisclosure(
    expanded: Boolean,
    onToggle: () -> Unit,
    tint: Color,
    content: @Composable () -> Unit,
) {
    Column {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .clip(RoundedCornerShape(8.dp))
                .clickable(onClick = onToggle)
                .padding(vertical = 2.dp),
        ) {
            Icon(
                if (expanded) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
                contentDescription = null,
                tint = tint,
                modifier = Modifier.size(18.dp),
            )
            Spacer(Modifier.width(4.dp))
            Text(
                stringResource(
                    if (expanded) R.string.voice_hide_transcript else R.string.voice_show_transcript
                ),
                style = MaterialTheme.typography.labelMedium,
                color = tint,
            )
        }
        androidx.compose.animation.AnimatedVisibility(expanded) {
            Box(Modifier.padding(top = 6.dp)) { content() }
        }
    }
}

@Composable
private fun MessageBubble(
    message: ChatMessage,
    isStreamingReply: Boolean = false,
    voicePlayback: VoicePlaybackCoordinator,
    onOpenArtifact: (Artifact) -> Unit,
    onImageTool: (ChatAttachment, com.aispotlight.android.providers.FalImageProvider.Function, String?) -> Unit,
    onRequestCleanup: (ChatAttachment) -> Unit,
    onSaveToGallery: (ChatAttachment) -> Unit,
    onExtractText: (ChatAttachment) -> Unit = {},
    onOpenImage: (ChatAttachment) -> Unit = {},
    /** Agent chats: reply paths become chips, the step journal renders. */
    isHermes: Boolean = false,
    onTogglePin: ((ChatMessage) -> Unit)? = null,
    onStepDetails: (suspend (String) -> List<com.aispotlight.android.hermes.HermesChatService.StepDetail>)? = null,
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
    val chatContentWidth = LocalChatContentWidth.current
    // Voice bubbles fold their transcript under the player (Telegram-style):
    // the voice block leads, the text expands on demand. While a spoken reply
    // is still being synthesized (`voicePending`) the same fold hides the
    // streamed text behind a pulsing placeholder — no text-then-audio lag on
    // screen. A VOICE message that never got audio (TTS failed, stream
    // killed) falls out of both flags and renders as plain text.
    val voicePending = !isUser && !message.isError && message.audioPath == null &&
        message.messageType == ChatMessage.Type.VOICE && isStreamingReply
    val voiceFolded = (message.audioPath != null || voicePending) &&
        !message.isError && message.text.isNotEmpty()
    var transcriptExpanded by rememberSaveable(message.id) { mutableStateOf(false) }
    // Wide-screen cap at 500dp: on an unfolded foldable or tablet a bubble
    // must not stretch into a full-width reading ribbon — the extra room
    // becomes margin, not line length. Measured against the chat COLUMN, not
    // the window: on a tablet the window is ~1280dp while the column is 720dp,
    // and the proportions only mean anything against the latter.
    val bubbleMaxWidth = (chatContentWidth * 0.82f).coerceAtMost(500.dp)
    val voiceContentWidth = (chatContentWidth * 0.72f).coerceAtMost(320.dp)
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
                    .then(if (message.audioPath != null || voicePending) {
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
                        coordinator = voicePlayback,
                        modifier = Modifier.widthIn(min = voiceContentWidth).fillMaxWidth(),
                    )
                }
                // The voice being synthesized: the player's silhouette holds
                // the bubble's voice shape until the real audio lands.
                if (voicePending) {
                    PendingVoiceBar(
                        isUser = false,
                        modifier = Modifier.widthIn(min = voiceContentWidth).fillMaxWidth(),
                    )
                }
                // The transcript of a voice bubble sits folded under the
                // player; everything else renders inline as before.
                val transcriptTint = when {
                    themed -> if (isUser) palette.userText.copy(alpha = 0.75f) else palette.secondaryText
                    else -> MaterialTheme.colorScheme.onSurfaceVariant
                }
                if (isUser) {
                    // Agent file note ("Attached files…\n- path") renders as
                    // inline images / chips, not raw paths — the text block
                    // stays in the stored message for the agent to read
                    // (AgentAttachNote is the shared cross-device contract).
                    val attachSplit = remember(message.text, isHermes) {
                        if (isHermes) com.aispotlight.android.hermes.AgentAttachNote.split(message.text)
                        else com.aispotlight.android.hermes.AgentAttachNote.Split(message.text, emptyList())
                    }
                    if (attachSplit.display.isNotEmpty()) {
                        val body = @Composable {
                            Text(
                                attachSplit.display,
                                style = MaterialTheme.typography.bodyLarge,
                                color = if (themed) palette.userText else androidx.compose.ui.graphics.Color.Unspecified,
                            )
                        }
                        if (voiceFolded) {
                            TranscriptDisclosure(
                                expanded = transcriptExpanded,
                                onToggle = { transcriptExpanded = !transcriptExpanded },
                                tint = transcriptTint,
                                content = body,
                            )
                        } else {
                            body()
                        }
                    }
                    if (attachSplit.paths.isNotEmpty()) {
                        // Images the courier put on the agent's host render
                        // inline — that is what makes a photo sent from
                        // ANOTHER device visible here (this phone holds no
                        // pixels for it). The sending device already shows
                        // its local attachment, so it skips this to avoid
                        // showing the same image twice (desktop parity).
                        val imagePaths = if (message.attachments.isEmpty()) {
                            attachSplit.paths.filter {
                                it.substringAfterLast('.', "").lowercase() in
                                    com.aispotlight.android.hermes.HermesFileCourier.imageExtensions
                            }
                        } else {
                            emptyList()
                        }
                        for (path in imagePaths) {
                            AgentNoteImage(path, message.timestamp)
                        }
                        val filePaths = attachSplit.paths.filterNot { it in imagePaths }
                        if (filePaths.isNotEmpty()) {
                            AgentPathChips(
                                text = "", message.timestamp, onOpenArtifact,
                                explicitPaths = filePaths,
                            )
                        }
                    }
                } else {
                    val parsed = remember(message.text) { parseArtifacts(message.text) }
                    // In-text file paths tap through to the reverse courier
                    // (agent replies only — ordinary chats keep plain text).
                    val agentPathOpener = rememberAgentPathOpener(onOpenArtifact)
                    val body = @Composable {
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            // Collapsible tool-step journal (agent replies):
                            // what the agent ran before answering; rows expand
                            // into command/output/exit code fetched lazily.
                            message.agentSteps?.let { steps ->
                                AgentStepJournalView(message.id, steps, onStepDetails)
                            }
                            if (parsed.plainText.isNotEmpty()) {
                                MarkdownText(
                                    parsed.plainText,
                                    isStreaming = isStreamingReply,
                                    onPathTap = if (isHermes) agentPathOpener else null,
                                )
                            }
                            for (artifact in parsed.artifacts) {
                                ArtifactCard(artifact, isStreaming = isStreamingReply, onOpen = { onOpenArtifact(artifact) })
                            }
                            // Files the agent mentioned by path → chips /
                            // preview cards (reverse courier, desktop 4.4).
                            if (isHermes && !isStreamingReply && message.text.isNotEmpty()) {
                                AgentPathChips(message.text, message.timestamp, onOpenArtifact)
                            }
                        }
                    }
                    if (voiceFolded) {
                        TranscriptDisclosure(
                            expanded = transcriptExpanded,
                            onToggle = { transcriptExpanded = !transcriptExpanded },
                            tint = transcriptTint,
                            content = body,
                        )
                    } else {
                        body()
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
            // Pin/unpin (Telegram semantics): the bar above the transcript
            // shows the pins and cycles through them.
            if (onTogglePin != null) {
                androidx.compose.material3.DropdownMenuItem(
                    text = {
                        Text(stringResource(
                            if (message.pinned) R.string.action_unpin else R.string.action_pin
                        ))
                    },
                    leadingIcon = { Icon(Icons.Filled.PushPin, contentDescription = null) },
                    onClick = {
                        showMenu = false
                        onTogglePin(message)
                    },
                )
            }
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
            // ratio inside a width/height cap instead of cropping into a fixed
            // full-width 180dp ribbon (which on a foldable/tablet blew the
            // photo up into a wall-to-wall sliver). The width follows the chat
            // column but stays inside 300…360dp: a phone keeps exactly the
            // preview it had, a tablet's wider column earns a little more.
            val aspect = bitmap.width.toFloat() / bitmap.height.toFloat()
            val previewMaxWidth = (LocalChatContentWidth.current * 0.62f)
                .coerceIn(300.dp, 360.dp)
            Image(
                bitmap.asImageBitmap(),
                contentDescription = attachment.filename,
                contentScale = ContentScale.Fit,
                modifier = Modifier
                    .widthIn(max = previewMaxWidth)
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
    } else if (!attachment.mimeType.startsWith("image")) {
        // Non-image file the user sent to the agent — a filename pill (the
        // desktop AgentAttachPillsView look; the bytes went via the courier).
        Row(
            Modifier
                .clip(RoundedCornerShape(10.dp))
                .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.7f))
                .padding(horizontal = 10.dp, vertical = 7.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                Icons.Filled.AttachFile,
                contentDescription = null,
                modifier = Modifier.size(14.dp),
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.width(5.dp))
            Text(
                attachment.filename,
                style = MaterialTheme.typography.bodySmall,
                fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                maxLines = 1,
                overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                modifier = Modifier.widthIn(max = 220.dp),
            )
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
        TimestampStyle.SNOW -> "${fmt("HH:mm")} ❄"
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
                    .then(
                        // Yule's gold band just inside the circle's edge.
                        palette.sendRim?.let { Modifier.border(2.5.dp, it, shape) } ?: Modifier
                    )
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

/**
 * Collapsible tool-step journal of an agent reply (desktop 4.0/4.2): the
 * header shows the step count; expanding lists "tool · status · duration";
 * expanding a ROW lazily fetches its command, output and exit code from the
 * gateway transcript (the summary alone is persisted).
 */
@Composable
private fun AgentStepJournalView(
    messageId: String,
    summary: String,
    onStepDetails: (suspend (String) -> List<com.aispotlight.android.hermes.HermesChatService.StepDetail>)?,
) {
    val steps = remember(summary) { com.aispotlight.android.hermes.HermesChatService.parseSteps(summary) }
    if (steps.isEmpty()) return
    var expanded by rememberSaveable(messageId) { mutableStateOf(false) }
    var details by remember(messageId) {
        mutableStateOf<List<com.aispotlight.android.hermes.HermesChatService.StepDetail>?>(null)
    }
    var expandedStep by remember(messageId) { mutableStateOf(-1) }
    val scope = rememberCoroutineScope()
    val chrome = MaterialTheme.colorScheme.onSurfaceVariant
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f))
            .padding(horizontal = 10.dp, vertical = 6.dp),
    ) {
        Row(
            Modifier.fillMaxWidth().clickable { expanded = !expanded },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                if (expanded) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
                contentDescription = null,
                tint = chrome,
                modifier = Modifier.size(18.dp),
            )
            Spacer(Modifier.width(6.dp))
            Text(
                stringResource(R.string.hermes_steps, steps.size),
                style = MaterialTheme.typography.labelMedium,
                color = chrome,
            )
        }
        if (expanded) {
            steps.forEachIndexed { index, (tool, status, detail) ->
                Column(
                    Modifier
                        .fillMaxWidth()
                        .clickable {
                            if (expandedStep == index) {
                                expandedStep = -1
                            } else {
                                expandedStep = index
                                if (details == null && onStepDetails != null) {
                                    scope.launch { details = onStepDetails(messageId) }
                                }
                            }
                        }
                        .padding(vertical = 4.dp),
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            if (status == "running") "●" else "✓",
                            style = MaterialTheme.typography.labelSmall,
                            color = if (status == "running") MaterialTheme.colorScheme.primary else chrome,
                        )
                        Spacer(Modifier.width(6.dp))
                        Text(
                            tool,
                            style = MaterialTheme.typography.bodySmall,
                            fontWeight = androidx.compose.ui.text.font.FontWeight.Medium,
                        )
                        detail?.let {
                            Spacer(Modifier.width(8.dp))
                            Text(
                                it,
                                style = MaterialTheme.typography.labelSmall,
                                color = chrome,
                                maxLines = 1,
                                overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                            )
                        }
                    }
                    if (expandedStep == index) {
                        val stepDetail = details?.getOrNull(index)
                        when {
                            onStepDetails == null -> { }
                            stepDetail == null -> CircularProgressIndicator(
                                modifier = Modifier.padding(6.dp).size(16.dp),
                                strokeWidth = 2.dp,
                            )
                            else -> Column(Modifier.padding(start = 14.dp, top = 4.dp)) {
                                stepDetail.command?.takeIf { it.isNotEmpty() }?.let { command ->
                                    Text(
                                        command,
                                        fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                                        fontSize = 12.sp,
                                        modifier = Modifier.horizontalScroll(rememberScrollState()),
                                    )
                                }
                                stepDetail.output?.takeIf { it.isNotEmpty() }?.let { output ->
                                    Text(
                                        output.take(2000),
                                        fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                                        fontSize = 11.sp,
                                        color = chrome,
                                        maxLines = 14,
                                        modifier = Modifier
                                            .padding(top = 2.dp)
                                            .horizontalScroll(rememberScrollState()),
                                    )
                                }
                                stepDetail.exitCode?.let { code ->
                                    Text(
                                        "exit $code",
                                        style = MaterialTheme.typography.labelSmall,
                                        color = if (code == 0) chrome else MaterialTheme.colorScheme.error,
                                        modifier = Modifier.padding(top = 2.dp),
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/**
 * Opens a reverse-courier copy the way the desktop does: HTML/Markdown in
 * the artifact viewer (same card/viewer as fenced deliverables), anything
 * else exported to Downloads with a toast.
 */
private fun openAgentCopy(
    context: android.content.Context,
    file: java.io.File,
    path: String,
    onOpenArtifact: (Artifact) -> Unit,
) {
    val courier = com.aispotlight.android.hermes.HermesFileCourier
    val name = path.substringAfterLast("/").ifEmpty { file.name }
    val ext = name.substringAfterLast('.', "").lowercase()
    if (ext in courier.artifactExtensions && file.length() <= 4 * 1024 * 1024) {
        onOpenArtifact(
            Artifact(
                kind = if (ext == "md" || ext == "markdown") Artifact.Kind.MARKDOWN else Artifact.Kind.HTML,
                content = file.readText(),
                title = name,
            )
        )
    } else {
        val saved = courier.exportToDownloads(context, file, name)
        android.widget.Toast.makeText(
            context,
            if (saved != null) context.getString(R.string.hermes_file_saved, saved)
            else context.getString(R.string.hermes_file_download_failed),
            android.widget.Toast.LENGTH_SHORT,
        ).show()
    }
}

/**
 * Tap handler for IN-TEXT agent file paths (Markdown onPathTap) — the chip
 * action minus the chrome: open the fetched copy, download it first when
 * the courier is configured, or copy the path as the last resort.
 */
@Composable
private fun rememberAgentPathOpener(onOpenArtifact: (Artifact) -> Unit): (String) -> Unit {
    val context = LocalContext.current
    val settings = remember(context) { com.aispotlight.android.settings.AppSettings.shared(context) }
    val clipboard = androidx.compose.ui.platform.LocalClipboardManager.current
    val scope = rememberCoroutineScope()
    val openArtifactState = androidx.compose.runtime.rememberUpdatedState(onOpenArtifact)
    return remember(context, settings, scope) {
        { path: String ->
            val courier = com.aispotlight.android.hermes.HermesFileCourier
            when {
                // Fresh-first: re-download even over a cached copy (the
                // agent may have edited the file); cache = offline fallback.
                // Directories are copy-only — nothing to fetch.
                courier.canFetchRemote(settings) &&
                    com.aispotlight.android.hermes.HermesFilePaths.isListableFile(path) -> {
                    scope.launch {
                        val fetched = courier.fetchRemote(context, settings, path)
                            ?: courier.fetchedCopy(path)
                        if (fetched != null) {
                            openAgentCopy(context, fetched, path, openArtifactState.value)
                        } else {
                            clipboard.setText(androidx.compose.ui.text.AnnotatedString(path))
                            android.widget.Toast.makeText(
                                context, context.getString(R.string.hermes_file_download_failed),
                                android.widget.Toast.LENGTH_SHORT,
                            ).show()
                        }
                    }
                    Unit
                }
                courier.fetchedCopy(path) != null ->
                    openAgentCopy(context, courier.fetchedCopy(path)!!, path, openArtifactState.value)
                else -> {
                    clipboard.setText(androidx.compose.ui.text.AnnotatedString(path))
                    android.widget.Toast.makeText(
                        context, context.getString(R.string.artifact_copied),
                        android.widget.Toast.LENGTH_SHORT,
                    ).show()
                }
            }
        }
    }
}

/**
 * File paths the agent mentioned in its reply → chips (desktop
 * AgentFileChipsView, 4.4 reverse-courier parity). With the dashboard
 * courier configured a chip DOWNLOADS the file: HTML/Markdown open in the
 * artifact viewer (and auto-fetch themselves into a preview card without a
 * tap), everything else is saved to Downloads. Without the courier the chip
 * copies the path — the old consolation prize.
 */
/**
 * Inline render of an image the courier put on the agent's host (attach
 * note path, user bubble): silently fetched into the app cache through the
 * dashboard files API — the pixels live only on the agent's machine when
 * the photo was sent from another device. Falls back to a copy-the-path
 * chip when the courier can't run or the fetch fails.
 */
@Composable
private fun AgentNoteImage(
    path: String,
    /** The mentioning message's timestamp — freshness the cache must satisfy. */
    messageTimestamp: Long,
) {
    val context = LocalContext.current
    val settings = remember(context) { com.aispotlight.android.settings.AppSettings.shared(context) }
    val courier = com.aispotlight.android.hermes.HermesFileCourier
    var copy by remember(path) { mutableStateOf(courier.fetchedCopy(path)) }
    var failed by remember(path) { mutableStateOf(false) }
    LaunchedEffect(path, messageTimestamp) {
        if (!courier.hasFreshCopy(path, messageTimestamp)) {
            val fetched = courier.autoFetchArtifact(context, settings, path, messageTimestamp)
            if (fetched != null) {
                copy = fetched
                failed = false
            } else if (copy == null) {
                failed = true
            }
        }
    }
    val file = copy
    when {
        file != null -> {
            // Decode subsampled off the UI thread; lastModified in the key —
            // a refresh overwrites the copy in place (same file, new bytes).
            var bitmap by remember(path, file.lastModified()) {
                mutableStateOf<android.graphics.Bitmap?>(null)
            }
            LaunchedEffect(path, file.lastModified()) {
                bitmap = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                    val bounds = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
                    android.graphics.BitmapFactory.decodeFile(file.path, bounds)
                    var sample = 1
                    while (bounds.outWidth / sample > 2048 || bounds.outHeight / sample > 2048) sample *= 2
                    android.graphics.BitmapFactory.decodeFile(
                        file.path,
                        android.graphics.BitmapFactory.Options().apply { inSampleSize = sample },
                    )
                }
            }
            bitmap?.let { decoded ->
                // Same preview metrics as AttachmentThumbnail: own aspect
                // ratio inside the chat column's width cap.
                val aspect = decoded.width.toFloat() / decoded.height.toFloat()
                val previewMaxWidth = (LocalChatContentWidth.current * 0.62f)
                    .coerceIn(300.dp, 360.dp)
                Image(
                    decoded.asImageBitmap(),
                    contentDescription = path.substringAfterLast('/'),
                    contentScale = ContentScale.Fit,
                    modifier = Modifier
                        .widthIn(max = previewMaxWidth)
                        .heightIn(max = 320.dp)
                        .aspectRatio(aspect)
                        .clip(RoundedCornerShape(12.dp)),
                )
            }
        }
        failed -> {
            // Honest fallback: the pixels are unreachable (courier not
            // configured, file gone from the host) — a chip that copies
            // the path instead of silently nothing.
            val clipboard = androidx.compose.ui.platform.LocalClipboardManager.current
            androidx.compose.material3.AssistChip(
                onClick = { clipboard.setText(androidx.compose.ui.text.AnnotatedString(path)) },
                leadingIcon = {
                    Icon(
                        Icons.Filled.BrokenImage, contentDescription = null,
                        modifier = Modifier.size(16.dp),
                    )
                },
                label = {
                    Text(
                        path.substringAfterLast('/'),
                        maxLines = 1,
                        overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                    )
                },
            )
        }
        else -> Box(
            Modifier
                .size(width = 220.dp, height = 140.dp)
                .clip(RoundedCornerShape(12.dp))
                .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f)),
            contentAlignment = Alignment.Center,
        ) {
            androidx.compose.material3.CircularProgressIndicator(
                modifier = Modifier.size(20.dp), strokeWidth = 2.dp,
            )
        }
    }
}

@Composable
private fun AgentPathChips(
    text: String,
    /** The mentioning message's timestamp — freshness the cache must satisfy. */
    messageTimestamp: Long,
    onOpenArtifact: (Artifact) -> Unit,
    /** Bypass extraction: the caller already knows the paths (attach note). */
    explicitPaths: List<String>? = null,
) {
    // Directories are dropped outright: the gateway is always remote from a
    // phone — nothing to fetch, nothing to open, the chip was pure noise.
    val paths = remember(text, explicitPaths) {
        explicitPaths ?: com.aispotlight.android.hermes.HermesFilePaths.extract(text)
            .filter { com.aispotlight.android.hermes.HermesFilePaths.isListableFile(it) }
    }
    if (paths.isEmpty()) return
    val clipboard = androidx.compose.ui.platform.LocalClipboardManager.current
    val context = LocalContext.current
    val settings = remember(context) { com.aispotlight.android.settings.AppSettings.shared(context) }
    val courier = com.aispotlight.android.hermes.HermesFileCourier
    val scope = rememberCoroutineScope()
    var fetchingPath by remember { mutableStateOf<String?>(null) }
    // Bumped when a silent auto-fetch lands: the chip graduates to a card.
    var fetchTick by remember { mutableStateOf(0) }

    val copyPath: (String) -> Unit = { path ->
        clipboard.setText(androidx.compose.ui.text.AnnotatedString(path))
        android.widget.Toast.makeText(
            context, context.getString(R.string.artifact_copied),
            android.widget.Toast.LENGTH_SHORT,
        ).show()
    }

    /** Open a local copy: artifact viewer for HTML/Markdown, Downloads export otherwise. */
    val openCopy: (java.io.File, String) -> Unit = { file, path ->
        openAgentCopy(context, file, path, onOpenArtifact)
    }

    // Silent auto-fetch (desktop 4.4): remote HTML/Markdown pull themselves
    // into the app cache so the preview card appears without a tap. The
    // courier refreshes copies OLDER than this message — the agent edited
    // the file and a new reply mentions it again.
    LaunchedEffect(text, fetchTick) {
        var landed = false
        for (path in paths) {
            val ext = path.substringAfterLast('.', "").lowercase()
            if (ext !in courier.artifactExtensions) continue
            if (courier.hasFreshCopy(path, messageTimestamp)) continue
            if (courier.autoFetchArtifact(context, settings, path, messageTimestamp) != null) landed = true
        }
        if (landed) fetchTick++
    }

    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        // Fetched HTML/Markdown render as full artifact preview cards —
        // identical to fenced deliverables (one visual language).
        val cardPaths = paths.filter { path ->
            fetchTick >= 0 &&
                path.substringAfterLast('.', "").lowercase() in courier.artifactExtensions &&
                courier.fetchedCopy(path) != null
        }
        for (path in cardPaths) {
            val copy = courier.fetchedCopy(path) ?: continue
            // lastModified in the key: a refresh overwrites the copy in
            // place — same file, new bytes — and the card must re-read.
            val artifact = remember(path, fetchTick, copy.lastModified()) {
                val name = path.substringAfterLast("/")
                val ext = name.substringAfterLast('.', "").lowercase()
                if (copy.length() <= 4 * 1024 * 1024) Artifact(
                    kind = if (ext == "md" || ext == "markdown") Artifact.Kind.MARKDOWN else Artifact.Kind.HTML,
                    content = copy.readText(),
                    title = name,
                ) else null
            }
            if (artifact != null) {
                ArtifactCard(artifact, onOpen = { onOpenArtifact(artifact) })
            }
        }
        val chipPaths = paths.filterNot { it in cardPaths }
        if (chipPaths.isNotEmpty()) Row(
            Modifier.horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            for (path in chipPaths) {
                // Directories get no download affordance — nothing to fetch
                // through the files API; the chip honestly copies the path.
                val canFetch = courier.canFetchRemote(settings) &&
                    com.aispotlight.android.hermes.HermesFilePaths.isListableFile(path)
                androidx.compose.material3.AssistChip(
                    enabled = fetchingPath != path,
                    onClick = {
                        when {
                            // Fresh-first even with a cached copy: the agent
                            // may have edited the file since — the stale
                            // copy is only the offline fallback.
                            canFetch && fetchingPath == null -> {
                                fetchingPath = path
                                scope.launch {
                                    val fetched = courier.fetchRemote(context, settings, path)
                                        ?: courier.fetchedCopy(path)
                                    fetchingPath = null
                                    if (fetched != null) {
                                        fetchTick++
                                        openCopy(fetched, path)
                                    } else {
                                        copyPath(path)
                                        android.widget.Toast.makeText(
                                            context, context.getString(R.string.hermes_file_download_failed),
                                            android.widget.Toast.LENGTH_SHORT,
                                        ).show()
                                    }
                                }
                            }
                            courier.fetchedCopy(path) != null ->
                                openCopy(courier.fetchedCopy(path)!!, path)
                            else -> copyPath(path)
                        }
                    },
                    leadingIcon = {
                        when {
                            fetchingPath == path -> androidx.compose.material3.CircularProgressIndicator(
                                modifier = Modifier.size(14.dp), strokeWidth = 1.5.dp,
                            )
                            courier.fetchedCopy(path) != null -> Icon(
                                Icons.Filled.Description, contentDescription = null,
                                modifier = Modifier.size(16.dp),
                            )
                            canFetch -> Icon(
                                Icons.Filled.Download, contentDescription = null,
                                modifier = Modifier.size(16.dp),
                            )
                            else -> Icon(
                                Icons.Filled.ContentCopy, contentDescription = null,
                                modifier = Modifier.size(16.dp),
                            )
                        }
                    },
                    label = {
                        Text(
                            path.substringAfterLast("/").ifEmpty { path },
                            maxLines = 1,
                            overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                        )
                    },
                )
            }
        }
    }
}
