package com.aispotlight.android.ui

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.os.Environment
import android.provider.MediaStore
import android.webkit.WebView
import android.widget.Toast
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Language
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties

/**
 * Artifacts: a complete HTML page or Markdown document the model returns in a
 * fenced block, shown as a compact card that opens a full preview.
 * Port of the ArtifactView.swift concept.
 */
data class Artifact(
    val kind: Kind,
    val content: String,
    val title: String,
    /**
     * A fence still open when the stream ended (mid-stream, or the reply was
     * cut off): the card renders as openable but flagged "may be cut off" —
     * the macOS truncation-handling behavior.
     */
    val truncated: Boolean = false,
) {
    enum class Kind { HTML, MARKDOWN }
}

/** A message split into plain text and embedded artifacts. */
data class ArtifactParse(
    val plainText: String,
    val artifacts: List<Artifact>,
)

/**
 * Detects deliverable documents in a reply, matching the macOS parser
 * (`MarkdownBlocksView.codeOrArtifact`): a fence labeled `html`, `markdown`
 * or `md` at ANY tick count (3+), or an unlabeled fence whose body starts
 * with `<!doctype`/`<html`. The closing fence is a backticks-only line at
 * least as long as the opening one (CommonMark), so inner ``` fences of a
 * ````markdown document stay content. The surrounding commentary stays as
 * plain markdown text.
 */
fun parseArtifacts(text: String): ArtifactParse {
    val artifacts = mutableListOf<Artifact>()
    val plain = StringBuilder()
    var i = 0
    val lines = text.lines()
    while (i < lines.size) {
        val trimmed = lines[i].trim()
        val ticks = trimmed.takeWhile { it == '`' }.length
        if (ticks >= 3) {
            val language = trimmed.drop(ticks).trim().lowercase()
            val body = StringBuilder()
            var j = i + 1
            var closed = false
            while (j < lines.size) {
                val t = lines[j].trim()
                val closeTicks = t.takeWhile { it == '`' }.length
                if (closeTicks >= ticks && t.drop(closeTicks).isEmpty()) { closed = true; break }
                body.appendLine(lines[j])
                j++
            }
            val content = body.toString().trimEnd()
            val lower = content.trimStart().lowercase()
            val looksLikeDocument = lower.startsWith("<!doctype") || lower.startsWith("<html")
            val kind = when {
                language == "html" || (language.isEmpty() && looksLikeDocument) -> Artifact.Kind.HTML
                language == "markdown" || language == "md" -> Artifact.Kind.MARKDOWN
                else -> null
            }
            // A closed fence is a complete document; an OPEN fence running to
            // the end of the reply is one still streaming in or cut off by the
            // token limit — still a card, flagged via `truncated`.
            if (kind != null && content.isNotEmpty()) {
                val title = if (kind == Artifact.Kind.HTML) {
                    Regex("<title[^>]*>([^<]*)</title>", RegexOption.IGNORE_CASE)
                        .find(content)?.groupValues?.get(1)?.trim().takeUnless { it.isNullOrEmpty() }
                        ?: "Interactive page"
                } else {
                    content.lineSequence().firstOrNull { it.trimStart().startsWith("#") }
                        ?.trimStart()?.trimStart('#')?.trim().takeUnless { it.isNullOrEmpty() }
                        ?: "Document"
                }
                artifacts.add(Artifact(
                    kind = kind,
                    content = content,
                    title = title,
                    truncated = !closed,
                ))
                i = j + 1
                continue
            }
            // Any other fence (```python, plain ``` …) stays inline code:
            // emit it into the plain text verbatim, including its body, so
            // body lines are never re-scanned for fence openers.
            plain.appendLine(lines[i])
            for (k in (i + 1)..minOf(j, lines.size - 1)) plain.appendLine(lines[k])
            i = j + 1
            continue
        }
        plain.appendLine(lines[i])
        i++
    }
    return ArtifactParse(plainText = plain.toString().trim(), artifacts = artifacts)
}

// MARK: - Card

@Composable
fun ArtifactCard(
    artifact: Artifact,
    /**
     * The reply this card belongs to is still streaming in. An open fence then
     * means "generating" (card disabled, no truncation warning) — the mac
     * ArtifactCardView behavior; once the stream is over an open fence renders
     * as a finished, openable card flagged "may be cut off".
     */
    isStreaming: Boolean = false,
    onOpen: () -> Unit,
) {
    val generating = artifact.truncated && isStreaming
    Surface(
        onClick = onOpen,
        enabled = !generating,
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.surface,
        tonalElevation = 2.dp,
        modifier = Modifier.fillMaxWidth(),
    ) {
        ListItem(
            headlineContent = {
                Text(
                    if (generating) androidx.compose.ui.res.stringResource(com.aispotlight.android.R.string.artifact_generating)
                    else artifact.title,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            },
            supportingContent = {
                val bytes = artifact.content.toByteArray(Charsets.UTF_8).size
                val size = if (bytes < 1024) "$bytes B" else "${bytes / 1024} KB"
                val hint = androidx.compose.ui.res.stringResource(
                    if (artifact.kind == Artifact.Kind.HTML) com.aispotlight.android.R.string.artifact_html_hint
                    else com.aispotlight.android.R.string.artifact_md_hint
                )
                val truncated = androidx.compose.ui.res.stringResource(com.aispotlight.android.R.string.artifact_truncated)
                Text(
                    when {
                        generating -> size
                        artifact.truncated -> "⚠ $truncated • $size"
                        else -> "$hint • $size"
                    },
                    style = MaterialTheme.typography.bodySmall,
                )
            },
            leadingContent = {
                if (generating) {
                    androidx.compose.material3.CircularProgressIndicator(
                        modifier = Modifier.size(22.dp),
                        strokeWidth = 2.dp,
                    )
                } else {
                    Icon(
                        if (artifact.kind == Artifact.Kind.HTML) Icons.Filled.Language else Icons.Filled.Description,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.primary,
                    )
                }
            },
            colors = ListItemDefaults.colors(containerColor = androidx.compose.ui.graphics.Color.Transparent),
        )
    }
}

// MARK: - Viewer

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ArtifactViewer(artifact: Artifact, onDismiss: () -> Unit) {
    val context = LocalContext.current
    var showCode by rememberSaveable { mutableStateOf(false) }

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Scaffold(
            topBar = {
                TopAppBar(
                    title = { Text(artifact.title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                    navigationIcon = {
                        IconButton(onClick = onDismiss) {
                            Icon(Icons.Filled.Close, contentDescription = "Close")
                        }
                    },
                    actions = {
                        if (artifact.kind == Artifact.Kind.HTML) {
                            IconButton(onClick = { openInBrowser(context, artifact) }) {
                                Icon(Icons.Filled.Language, contentDescription = androidx.compose.ui.res.stringResource(
                                    com.aispotlight.android.R.string.artifact_open_browser
                                ))
                            }
                        }
                        IconButton(onClick = { copyArtifact(context, artifact) }) {
                            Icon(Icons.Filled.ContentCopy, contentDescription = androidx.compose.ui.res.stringResource(
                                com.aispotlight.android.R.string.artifact_copy
                            ))
                        }
                        IconButton(onClick = { shareArtifact(context, artifact) }) {
                            Icon(Icons.Filled.Share, contentDescription = androidx.compose.ui.res.stringResource(
                                com.aispotlight.android.R.string.artifact_share
                            ))
                        }
                        IconButton(onClick = { saveArtifact(context, artifact) }) {
                            Icon(Icons.Filled.Download, contentDescription = "Save")
                        }
                        IconButton(onClick = { showCode = !showCode }) {
                            Icon(Icons.Filled.Code, contentDescription = "Code")
                        }
                    },
                )
            },
        ) { padding ->
            Column(Modifier.padding(padding).fillMaxSize()) {
                when {
                    showCode -> Text(
                        artifact.content,
                        fontFamily = FontFamily.Monospace,
                        fontSize = 12.sp,
                        modifier = Modifier
                            .fillMaxSize()
                            .verticalScroll(rememberScrollState())
                            .padding(12.dp),
                    )
                    artifact.kind == Artifact.Kind.HTML -> AndroidView(
                        factory = { ctx ->
                            WebView(ctx).apply {
                                settings.javaScriptEnabled = true
                                settings.domStorageEnabled = true
                                loadDataWithBaseURL(null, artifact.content, "text/html", "utf-8", null)
                            }
                        },
                        update = { webView ->
                            // Re-load only when the content actually changed.
                            if (webView.tag != artifact.content) {
                                webView.tag = artifact.content
                                webView.loadDataWithBaseURL(null, artifact.content, "text/html", "utf-8", null)
                            }
                        },
                        modifier = Modifier.fillMaxSize(),
                    )
                    else -> MarkdownText(
                        artifact.content,
                        modifier = Modifier
                            .fillMaxSize()
                            .verticalScroll(rememberScrollState())
                            .padding(16.dp),
                    )
                }
            }
        }
    }
}

private val Artifact.fileExtension: String
    get() = if (kind == Artifact.Kind.HTML) "html" else "md"

private val Artifact.mimeType: String
    get() = if (kind == Artifact.Kind.HTML) "text/html" else "text/markdown"

/** Safe file-name stem derived from the artifact title (the mac `fileStem`). */
private fun fileStem(title: String): String =
    title.replace(Regex("[^\\p{L}\\p{N} _-]"), "").trim().ifEmpty { "artifact" }

/** Writes the artifact into the FileProvider-served cache dir. */
private fun writeToCache(context: Context, artifact: Artifact): android.net.Uri {
    val dir = java.io.File(context.cacheDir, "artifacts").apply { mkdirs() }
    val file = java.io.File(dir, fileStem(artifact.title) + "." + artifact.fileExtension)
    file.writeText(artifact.content)
    return androidx.core.content.FileProvider.getUriForFile(
        context, context.packageName + ".fileprovider", file
    )
}

/** Writes the page to cache and opens it in the user's browser (FileProvider). */
private fun openInBrowser(context: Context, artifact: Artifact) {
    try {
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(writeToCache(context, artifact), "text/html")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        context.startActivity(Intent.createChooser(intent, artifact.title))
    } catch (e: Exception) {
        Toast.makeText(context, e.message, Toast.LENGTH_SHORT).show()
    }
}

/**
 * Shares the artifact as a real .html/.md file (FileProvider stream with the
 * proper mime), so mail/messenger/Drive receive an attachment, not a wall of
 * pasted markup. No EXTRA_TEXT on purpose: targets that handle both would
 * otherwise paste the whole document alongside the attachment.
 */
private fun shareArtifact(context: Context, artifact: Artifact) {
    try {
        val uri = writeToCache(context, artifact)
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = artifact.mimeType
            putExtra(Intent.EXTRA_STREAM, uri)
            putExtra(Intent.EXTRA_SUBJECT, artifact.title)
            // ClipData mirrors the stream so the chooser can forward the URI
            // read grant to whichever target the user picks.
            clipData = android.content.ClipData.newRawUri(artifact.title, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(Intent.createChooser(intent, artifact.title))
    } catch (e: Exception) {
        Toast.makeText(context, e.message, Toast.LENGTH_SHORT).show()
    }
}

/** Copies the raw document source to the clipboard (the mac Copy action). */
private fun copyArtifact(context: Context, artifact: Artifact) {
    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
    clipboard.setPrimaryClip(android.content.ClipData.newPlainText(artifact.title, artifact.content))
    // Always our own confirmation: the 13+ system clipboard overlay is
    // suppressed on many OEM skins, and a silent copy reads as a dead button.
    Toast.makeText(context, context.getString(com.aispotlight.android.R.string.artifact_copied), Toast.LENGTH_SHORT).show()
}

/** Saves the artifact into Downloads via MediaStore (no storage permission needed). */
private fun saveArtifact(context: Context, artifact: Artifact) {
    val extension = artifact.fileExtension
    val mime = artifact.mimeType
    val safeName = fileStem(artifact.title)
    val values = ContentValues().apply {
        put(MediaStore.Downloads.DISPLAY_NAME, "$safeName.$extension")
        put(MediaStore.Downloads.MIME_TYPE, mime)
        put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
    }
    try {
        val uri = context.contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("MediaStore insert failed")
        context.contentResolver.openOutputStream(uri)?.use { out ->
            out.write(artifact.content.toByteArray(Charsets.UTF_8))
        }
        Toast.makeText(context, context.getString(com.aispotlight.android.R.string.artifact_saved), Toast.LENGTH_SHORT).show()
    } catch (e: Exception) {
        Toast.makeText(
            context,
            context.getString(com.aispotlight.android.R.string.artifact_save_failed, e.message ?: ""),
            Toast.LENGTH_SHORT
        ).show()
    }
}
