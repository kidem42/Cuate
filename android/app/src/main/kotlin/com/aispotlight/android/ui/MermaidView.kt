package com.aispotlight.android.ui

import android.annotation.SuppressLint
import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.os.Environment
import android.provider.MediaStore
import android.webkit.WebView
import android.widget.Toast
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Image as ImageIcon
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.aispotlight.android.R
import kotlinx.coroutines.launch

/**
 * Inline mermaid diagram in a chat bubble: rendered offscreen (MermaidRenderer)
 * and shown as a bitmap on a themed card — no live WebViews in the transcript,
 * so scrolling stays cheap. Tap opens the interactive viewer (live SVG, pinch
 * zoom, export). A diagram that fails mermaid's parser degrades to a regular
 * code block with a warning badge. Port of MermaidBlockView.swift.
 */
@Composable
fun MermaidBlock(code: String, complete: Boolean) {
    val context = LocalContext.current
    val palette = LocalChatPalette.current
    val themed = !palette.isDynamic
    val accent = if (themed) palette.accent else MaterialTheme.colorScheme.primary
    // Dark from the actual surface the bubble sits on, so exotic chat themes
    // (Terminal, Halloween dark) get the dark diagram card too.
    val dark = MaterialTheme.colorScheme.background.luminance() < 0.5f
    val theme = remember(accent, dark) { MermaidTheme.make(accent, dark) }

    var result by remember { mutableStateOf<MermaidRenderer.RenderResult?>(null) }
    var showViewer by rememberSaveable { mutableStateOf(false) }

    LaunchedEffect(theme.key, code, complete) {
        if (complete) result = MermaidRenderer.render(context, code, theme)
    }

    when (val rendered = if (complete) result else null) {
        null -> GeneratingCard()
        is MermaidRenderer.RenderResult.Failure -> {
            Column {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        Icons.Filled.Warning,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.error,
                        modifier = Modifier.size(14.dp),
                    )
                    Text(
                        stringResource(R.string.mermaid_error),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.error,
                        modifier = Modifier.padding(start = 4.dp, bottom = 2.dp),
                    )
                }
                CodeBlock("mermaid", code)
            }
        }
        is MermaidRenderer.RenderResult.Success -> {
            Image(
                bitmap = rendered.bitmap.asImageBitmap(),
                contentDescription = stringResource(R.string.mermaid_diagram),
                contentScale = ContentScale.Fit,
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(max = 420.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(theme.backgroundColor)
                    .clickable { showViewer = true }
                    .padding(10.dp),
            )
            if (showViewer) {
                MermaidViewer(code = code, theme = theme, onDismiss = { showViewer = false })
            }
        }
    }
}

@Composable
private fun GeneratingCard() {
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.surface,
        tonalElevation = 2.dp,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(12.dp),
        ) {
            CircularProgressIndicator(modifier = Modifier.size(22.dp), strokeWidth = 2.dp)
            Text(
                stringResource(R.string.mermaid_generating),
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.padding(start = 10.dp),
            )
        }
    }
}

/**
 * Full-screen viewer: live SVG in a WebView with pinch zoom, a Code toggle,
 * copy source, save SVG (always the light theme — exports land in documents
 * that assume a light background) and save PNG (what you see, current theme).
 */
@OptIn(ExperimentalMaterial3Api::class)
@SuppressLint("SetJavaScriptEnabled")
@Composable
private fun MermaidViewer(code: String, theme: MermaidTheme, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var showCode by rememberSaveable { mutableStateOf(false) }
    val title = MermaidRenderer.extractTitle(code) ?: stringResource(R.string.mermaid_diagram)

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Scaffold(
            topBar = {
                TopAppBar(
                    title = { Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                    navigationIcon = {
                        IconButton(onClick = onDismiss) {
                            Icon(Icons.Filled.Close, contentDescription = "Close")
                        }
                    },
                    actions = {
                        IconButton(onClick = { copySource(context, title, code) }) {
                            Icon(Icons.Filled.ContentCopy, contentDescription = stringResource(R.string.artifact_copy))
                        }
                        // Share the rendered diagram as a PNG attachment — on
                        // mobile the messenger hand-off is the primary export.
                        IconButton(onClick = {
                            scope.launch {
                                when (val r = MermaidRenderer.render(context, code, theme)) {
                                    is MermaidRenderer.RenderResult.Success ->
                                        sharePng(context, r.bitmap, fileStemOf(title))
                                    is MermaidRenderer.RenderResult.Failure -> saveFailed(context, r.message)
                                }
                            }
                        }) {
                            Icon(Icons.Filled.Share, contentDescription = stringResource(R.string.artifact_share))
                        }
                        // Save PNG: the rendered bitmap in the CURRENT theme.
                        IconButton(onClick = {
                            scope.launch {
                                when (val r = MermaidRenderer.render(context, code, theme)) {
                                    is MermaidRenderer.RenderResult.Success ->
                                        savePng(context, r.bitmap, fileStemOf(title))
                                    is MermaidRenderer.RenderResult.Failure -> saveFailed(context, r.message)
                                }
                            }
                        }) {
                            Icon(Icons.Filled.ImageIcon, contentDescription = stringResource(R.string.mermaid_save_png))
                        }
                        // Save SVG: re-render with the LIGHT theme for portability.
                        IconButton(onClick = {
                            scope.launch {
                                val light = MermaidTheme.make(
                                    accent = androidx.compose.ui.graphics.Color(0xFF2A78D6),
                                    dark = false,
                                )
                                when (val r = MermaidRenderer.render(context, code, light)) {
                                    is MermaidRenderer.RenderResult.Success ->
                                        saveSvg(context, r.svg, fileStemOf(title))
                                    is MermaidRenderer.RenderResult.Failure -> saveFailed(context, r.message)
                                }
                            }
                        }) {
                            Icon(Icons.Filled.Download, contentDescription = stringResource(R.string.mermaid_save_svg))
                        }
                        IconButton(onClick = { showCode = !showCode }) {
                            Icon(Icons.Filled.Code, contentDescription = "Code")
                        }
                    },
                )
            },
        ) { padding ->
            Column(Modifier.padding(padding).fillMaxSize()) {
                if (showCode) {
                    Text(
                        code,
                        fontFamily = FontFamily.Monospace,
                        fontSize = 12.sp,
                        modifier = Modifier
                            .fillMaxSize()
                            .verticalScroll(rememberScrollState())
                            .padding(12.dp),
                    )
                } else {
                    AndroidView(
                        factory = { ctx ->
                            WebView(ctx).apply {
                                settings.javaScriptEnabled = true
                                settings.setSupportZoom(true)
                                settings.builtInZoomControls = true
                                settings.displayZoomControls = false
                                settings.useWideViewPort = true
                                loadDataWithBaseURL(
                                    null,
                                    MermaidRenderer.previewHtml(ctx, code, theme),
                                    "text/html", "utf-8", null,
                                )
                            }
                        },
                        update = { webView ->
                            if (webView.tag != code + theme.key) {
                                webView.tag = code + theme.key
                                webView.loadDataWithBaseURL(
                                    null,
                                    MermaidRenderer.previewHtml(webView.context, code, theme),
                                    "text/html", "utf-8", null,
                                )
                            }
                        },
                        modifier = Modifier.fillMaxSize(),
                    )
                }
            }
        }
    }
}

// MARK: - Export

private fun fileStemOf(title: String): String =
    title.replace(Regex("[^\\p{L}\\p{N} _-]"), "").trim().ifEmpty { "diagram" }

private fun copySource(context: Context, title: String, code: String) {
    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
    clipboard.setPrimaryClip(android.content.ClipData.newPlainText(title, code))
    Toast.makeText(context, context.getString(R.string.artifact_copied), Toast.LENGTH_SHORT).show()
}

private fun saveFailed(context: Context, message: String) {
    Toast.makeText(context, context.getString(R.string.artifact_save_failed, message), Toast.LENGTH_SHORT).show()
}

/** Saves into Downloads via MediaStore (no storage permission needed). */
private fun saveToDownloads(context: Context, name: String, mime: String, write: (java.io.OutputStream) -> Unit) {
    val values = ContentValues().apply {
        put(MediaStore.Downloads.DISPLAY_NAME, name)
        put(MediaStore.Downloads.MIME_TYPE, mime)
        put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
    }
    try {
        val uri = context.contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("MediaStore insert failed")
        context.contentResolver.openOutputStream(uri)?.use(write)
        Toast.makeText(context, context.getString(R.string.artifact_saved), Toast.LENGTH_SHORT).show()
    } catch (e: Exception) {
        saveFailed(context, e.message ?: "")
    }
}

private fun savePng(context: Context, bitmap: Bitmap, stem: String) =
    saveToDownloads(context, "$stem.png", "image/png") { out ->
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
    }

/**
 * Shares the diagram as a real .png attachment via the FileProvider-served
 * cache dir (the shareArtifact pattern: ClipData mirrors the stream so the
 * chooser forwards the read grant to whichever target the user picks).
 */
private fun sharePng(context: Context, bitmap: Bitmap, stem: String) {
    try {
        val dir = java.io.File(context.cacheDir, "artifacts").apply { mkdirs() }
        val file = java.io.File(dir, "$stem.png")
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        val uri = androidx.core.content.FileProvider.getUriForFile(
            context, context.packageName + ".fileprovider", file
        )
        val intent = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
            type = "image/png"
            putExtra(android.content.Intent.EXTRA_STREAM, uri)
            putExtra(android.content.Intent.EXTRA_SUBJECT, stem)
            clipData = android.content.ClipData.newRawUri(stem, uri)
            addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(android.content.Intent.createChooser(intent, stem))
    } catch (e: Exception) {
        Toast.makeText(context, e.message, Toast.LENGTH_SHORT).show()
    }
}

private fun saveSvg(context: Context, svg: String, stem: String) =
    saveToDownloads(context, "$stem.svg", "image/svg+xml") { out ->
        out.write(svg.toByteArray(Charsets.UTF_8))
    }
