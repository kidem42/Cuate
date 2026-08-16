package com.aispotlight.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * Lightweight Markdown renderer: fenced code, headings, lists, task lists,
 * blockquotes, tables, dividers + inline bold/italic/code/links.
 * The Compose analog of `MarkdownBlocksView.swift`.
 */

// @Immutable so a block is a skippable composable parameter: a re-parse
// produces value-equal instances, and rows whose block didn't change are
// skipped instead of rebuilding their AnnotatedStrings on every chunk.
@androidx.compose.runtime.Immutable
private sealed class MdBlock {
    data class Paragraph(val text: String) : MdBlock()
    data class Heading(val level: Int, val text: String) : MdBlock()
    /** `closed` is false while the fence is still streaming in (no closing line yet). */
    data class Code(val language: String, val code: String, val closed: Boolean = true) : MdBlock()
    data class Quote(val lines: List<String>) : MdBlock()
    data class ListItem(val marker: String, val text: String, val indent: Int) : MdBlock()
    data class Table(val rows: List<List<String>>) : MdBlock()
    object Divider : MdBlock()
}

/**
 * Incremental parse for the streaming reply (the light-weight analog of the
 * desktop StreamingReplyModel): everything before the last SAFE boundary —
 * a blank line with no code fence left open — is parsed once and cached;
 * only the live tail re-parses on each chunk. Long answers stop getting
 * heavier as they grow: the tail is the current paragraph or open fence,
 * not the whole message.
 */
private class StreamingParseCache {
    private var stableEnd = 0
    private var stableBlocks = mutableListOf<MdBlock>()
    private var fullText = ""

    fun blocksFor(text: String): List<MdBlock> {
        // A rewrite (retry, error replacement) invalidates the cache: the new
        // text no longer extends the stable prefix.
        if (stableEnd > text.length || !text.regionMatches(0, fullText, 0, stableEnd)) {
            stableEnd = 0
            stableBlocks = mutableListOf()
        }
        fullText = text

        // Advance the stable frontier over COMPLETE lines only (the last line
        // is still streaming): a blank line is a boundary, unless a ``` fence
        // is open across it — fences swallow blank lines, so the frontier
        // waits for the fence to close.
        var boundary = stableEnd
        var scan = stableEnd
        var fenceOpen = false
        while (true) {
            val nl = text.indexOf('\n', scan)
            if (nl < 0) break
            val line = text.substring(scan, nl).trim()
            if (line.startsWith("```")) fenceOpen = !fenceOpen
            if (line.isEmpty() && !fenceOpen) boundary = nl + 1
            scan = nl + 1
        }
        if (boundary > stableEnd) {
            stableBlocks.addAll(parseBlocks(text.substring(stableEnd, boundary)))
            stableEnd = boundary
        }
        return stableBlocks + parseBlocks(text.substring(stableEnd))
    }
}

private fun parseBlocks(markdown: String): List<MdBlock> {
    val blocks = mutableListOf<MdBlock>()
    val lines = markdown.lines()
    var i = 0
    val paragraph = StringBuilder()
    // depth → the number the next ordered item at that depth gets.
    val orderedCounters = mutableMapOf<Int, Int>()

    fun flushParagraph() {
        if (paragraph.isNotEmpty()) {
            blocks.add(MdBlock.Paragraph(paragraph.toString().trim()))
            paragraph.clear()
        }
    }

    while (i < lines.size) {
        val line = lines[i]
        val trimmed = line.trim()
        when {
            // Fenced code (``` or ````)
            trimmed.startsWith("```") -> {
                flushParagraph()
                val fence = trimmed.takeWhile { it == '`' }
                val language = trimmed.removePrefix(fence).trim()
                val code = StringBuilder()
                i++
                while (i < lines.size && !lines[i].trim().startsWith(fence)) {
                    code.appendLine(lines[i])
                    i++
                }
                blocks.add(MdBlock.Code(language, code.toString().trimEnd(), closed = i < lines.size))
            }
            // Heading
            trimmed.startsWith("#") -> {
                flushParagraph()
                val level = trimmed.takeWhile { it == '#' }.length.coerceAtMost(4)
                blocks.add(MdBlock.Heading(level, trimmed.dropWhile { it == '#' }.trim()))
            }
            // Divider
            trimmed == "---" || trimmed == "***" || trimmed == "___" -> {
                flushParagraph()
                blocks.add(MdBlock.Divider)
            }
            // Blockquote
            trimmed.startsWith(">") -> {
                flushParagraph()
                val quote = mutableListOf<String>()
                while (i < lines.size && lines[i].trim().startsWith(">")) {
                    quote.add(lines[i].trim().removePrefix(">").trim())
                    i++
                }
                i--
                blocks.add(MdBlock.Quote(quote))
            }
            // Table (| a | b |)
            trimmed.startsWith("|") && trimmed.endsWith("|") -> {
                flushParagraph()
                val rows = mutableListOf<List<String>>()
                while (i < lines.size) {
                    val rowLine = lines[i].trim()
                    if (!(rowLine.startsWith("|") && rowLine.endsWith("|"))) break
                    val cells = rowLine.trim('|').split("|").map { it.trim() }
                    // Skip the |---|---| separator row.
                    if (!cells.all { cell -> cell.isNotEmpty() && cell.all { it == '-' || it == ':' } }) {
                        rows.add(cells)
                    }
                    i++
                }
                i--
                if (rows.isNotEmpty()) blocks.add(MdBlock.Table(rows))
            }
            // List item (bullet, task, numbered)
            Regex("""^(\s*)([-*+]|\d+[.)])\s+.*""").matches(line) -> {
                flushParagraph()
                val match = Regex("""^(\s*)([-*+]|\d+[.)])\s+(.*)""").find(line)!!
                val (indentStr, marker, text) = match.destructured
                val depth = indentStr.length / 2
                // Task list: "- [ ] item" / "- [x] item" → checkbox glyph.
                val task = Regex("""^\[([ xX])]\s+(.*)""").find(text)
                if (task != null) {
                    val (state, taskText) = task.destructured
                    val box = if (state.equals("x", ignoreCase = true)) "☑" else "☐"
                    orderedCounters.keys.filter { it >= depth }.forEach { orderedCounters.remove(it) }
                    blocks.add(MdBlock.ListItem(box, taskText, depth))
                } else if (marker.first().isDigit()) {
                    // The list COUNTS, it does not echo: models write "1." for
                    // every item and rely on markdown to number them, and a
                    // list that opens at "3." keeps counting from three
                    // (CommonMark). Deeper levels reset when we come back up.
                    orderedCounters.keys.filter { it > depth }.forEach { orderedCounters.remove(it) }
                    val next = orderedCounters[depth]
                        ?: (marker.dropLast(1).toIntOrNull() ?: 1)
                    orderedCounters[depth] = next + 1
                    blocks.add(MdBlock.ListItem("$next.", text, depth))
                } else {
                    orderedCounters.keys.filter { it >= depth }.forEach { orderedCounters.remove(it) }
                    blocks.add(MdBlock.ListItem(marker, text, depth))
                }
            }
            trimmed.isEmpty() -> flushParagraph()
            else -> {
                if (paragraph.isNotEmpty()) paragraph.append("\n")
                paragraph.append(line)
            }
        }
        i++
    }
    flushParagraph()
    return blocks
}

/**
 * Raw-URL autolink (the mac NSDataDetector pass): a bare `https://…` or
 * `www.…` in the reply becomes clickable — models rarely bother with
 * `[label](url)` syntax. Trailing punctuation stays outside the link.
 */
private val rawUrlRegex = Regex("""(https?://|www\.)[^\s<>()\[\]{}"'`]+""")

private fun trimUrlEnd(url: String): String = url.trimEnd('.', ',', ';', ':', '!', '?')

/**
 * Agent-file mentions in prose (desktop 4.4): the same root prefixes the
 * chip extractor recognizes, matched inline so the path becomes a tap
 * target instead of dead text.
 */
private val agentPathRegex = Regex(
    """(?:~|/Users|/home|/root|/srv|/mnt|/tmp|/private|/var|/opt|/etc)/[A-Za-z0-9._\-/~]+"""
)

/** Inline markdown → AnnotatedString: **bold**, *italic*, `code`, [links](url), raw URLs. */
fun inlineMarkdown(
    text: String,
    linkColor: Color,
    codeBackground: Color,
    codeColor: Color = Color.Unspecified,
    onCodeTap: ((String) -> Unit)? = null,
    /** Agent chats: taps on file paths route to the reverse courier. */
    onPathTap: ((String) -> Unit)? = null,
): AnnotatedString =
    buildAnnotatedString {
        var i = 0
        while (i < text.length) {
            when {
                text.startsWith("**", i) -> {
                    val end = text.indexOf("**", i + 2)
                    if (end > 0) {
                        pushStyle(SpanStyle(fontWeight = FontWeight.Bold))
                        append(inlineMarkdown(text.substring(i + 2, end), linkColor, codeBackground, codeColor, onCodeTap, onPathTap))
                        pop()
                        i = end + 2
                    } else { append(text[i]); i++ }
                }
                text.startsWith("`", i) -> {
                    val end = text.indexOf("`", i + 1)
                    if (end > 0) {
                        val code = text.substring(i + 1, end)
                        // Tap-to-copy on the chip (Telegram / mac CopyLink
                        // semantics): the span itself is the copy affordance.
                        if (onCodeTap != null) {
                            pushLink(LinkAnnotation.Clickable("copy-code",
                                linkInteractionListener = { onCodeTap(code) }))
                        }
                        pushStyle(SpanStyle(
                            fontFamily = FontFamily.Monospace,
                            background = codeBackground,
                            color = codeColor,
                            fontSize = 13.sp,
                        ))
                        append(code)
                        pop()
                        if (onCodeTap != null) pop()
                        i = end + 1
                    } else { append(text[i]); i++ }
                }
                text.startsWith("http://", i) || text.startsWith("https://", i) ||
                    text.startsWith("www.", i) -> {
                    val match = rawUrlRegex.matchAt(text, i)
                    if (match != null) {
                        val visible = trimUrlEnd(match.value)
                        val url = if (visible.startsWith("www.")) "https://$visible" else visible
                        pushLink(LinkAnnotation.Url(url))
                        pushStyle(SpanStyle(color = linkColor, textDecoration = TextDecoration.Underline))
                        append(visible)
                        pop()
                        pop()
                        i += visible.length
                    } else { append(text[i]); i++ }
                }
                text.startsWith("[", i) -> {
                    val closeBracket = text.indexOf("](", i)
                    val closeParen = if (closeBracket > 0) text.indexOf(")", closeBracket + 2) else -1
                    if (closeBracket > 0 && closeParen > 0) {
                        val label = text.substring(i + 1, closeBracket)
                        val url = text.substring(closeBracket + 2, closeParen)
                        pushLink(LinkAnnotation.Url(url))
                        pushStyle(SpanStyle(color = linkColor, textDecoration = TextDecoration.Underline))
                        append(label)
                        pop()
                        pop()
                        i = closeParen + 1
                    } else { append(text[i]); i++ }
                }
                onPathTap != null && (text[i] == '/' || text[i] == '~') &&
                    (i == 0 || text[i - 1].isWhitespace() || text[i - 1] in "`'\"([") -> {
                    val match = agentPathRegex.matchAt(text, i)
                    if (match != null) {
                        var visible = match.value
                        while (visible.isNotEmpty() && visible.last() in ".,;:!?)") visible = visible.dropLast(1)
                        val path = visible
                        pushLink(LinkAnnotation.Clickable("agent-file",
                            linkInteractionListener = { onPathTap(path) }))
                        pushStyle(SpanStyle(
                            fontFamily = FontFamily.Monospace,
                            color = linkColor,
                            textDecoration = TextDecoration.Underline,
                            fontSize = 13.sp,
                        ))
                        append(visible)
                        pop()
                        pop()
                        i += visible.length
                    } else { append(text[i]); i++ }
                }
                text.startsWith("*", i) && !text.startsWith("**", i) -> {
                    val end = text.indexOf("*", i + 1)
                    if (end > 0 && end > i + 1) {
                        pushStyle(SpanStyle(fontStyle = FontStyle.Italic))
                        append(text.substring(i + 1, end))
                        pop()
                        i = end + 1
                    } else { append(text[i]); i++ }
                }
                else -> { append(text[i]); i++ }
            }
        }
    }

@Composable
fun MarkdownText(
    markdown: String,
    modifier: Modifier = Modifier,
    baseStyle: TextStyle = MaterialTheme.typography.bodyLarge,
    /** The reply is still streaming in — an open ```mermaid fence then means "drawing". */
    isStreaming: Boolean = false,
    /** Agent chats: taps on in-text file paths route to the reverse courier. */
    onPathTap: ((String) -> Unit)? = null,
) {
    // Streaming replies parse incrementally (stable prefix cached, live tail
    // re-parsed); settled messages parse once per text as before.
    val streamingCache = remember { StreamingParseCache() }
    val blocks = if (isStreaming) streamingCache.blocksFor(markdown)
        else remember(markdown) { parseBlocks(markdown) }
    val palette = LocalChatPalette.current
    val themed = !palette.isDynamic
    // Palette-driven roles (mac MarkdownBlocksView): the theme's ink accent
    // for links/bullets, the spec's own code chip + quote bar colors.
    val linkColor = if (themed) palette.ink else MaterialTheme.colorScheme.primary
    val codeBg = if (themed) (palette.inlineCodeFill ?: palette.codeFill)
        else MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.7f)
    val inlineCodeColor = if (themed) (palette.inlineCodeText ?: palette.codeText) else Color.Unspecified
    val quoteBar = if (themed) (palette.quoteColor ?: palette.accent)
        else MaterialTheme.colorScheme.primary.copy(alpha = 0.5f)
    val bulletColor = if (themed) (palette.bulletColor ?: palette.ink) else Color.Unspecified
    val secondary = if (themed) palette.secondaryText else MaterialTheme.colorScheme.onSurfaceVariant

    // Inline-code chips copy on tap (Telegram / mac CopyLink semantics). The
    // system clipboard overlay is unreliable on OEM skins — toast ourselves.
    val clipboard = androidx.compose.ui.platform.LocalClipboardManager.current
    val context = androidx.compose.ui.platform.LocalContext.current
    // remember-ed so the lambda reference is stable across recompositions —
    // an unstable callback would defeat per-block skipping below.
    val onCodeTap: (String) -> Unit = remember(clipboard, context) {
        { code ->
            clipboard.setText(AnnotatedString(code))
            android.widget.Toast.makeText(
                context,
                context.getString(com.aispotlight.android.R.string.artifact_copied),
                android.widget.Toast.LENGTH_SHORT,
            ).show()
        }
    }

    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        // key(index): stable-prefix blocks keep their position while the
        // stream grows, so their rows recompose only if their block changed
        // (value equality via @Immutable data classes) — per-chunk work is
        // the live tail, not the whole message.
        blocks.forEachIndexed { index, block ->
            androidx.compose.runtime.key(index) {
            when (block) {
                is MdBlock.Paragraph -> Text(
                    inlineMarkdown(block.text, linkColor, codeBg, inlineCodeColor, onCodeTap, onPathTap),
                    style = baseStyle,
                )
                is MdBlock.Heading -> Text(
                    inlineMarkdown(block.text, linkColor, codeBg, inlineCodeColor, onCodeTap, onPathTap),
                    style = when (block.level) {
                        1 -> MaterialTheme.typography.headlineSmall
                        2 -> MaterialTheme.typography.titleLarge
                        3 -> MaterialTheme.typography.titleMedium
                        else -> MaterialTheme.typography.titleSmall
                    },
                    fontWeight = FontWeight.Bold,
                )
                is MdBlock.Code ->
                    // ```mermaid renders as a native inline diagram (mac
                    // MermaidBlockView); once the stream is over an open fence
                    // still gets a render attempt — the parser decides whether
                    // it degrades to source.
                    if (block.language.equals("mermaid", ignoreCase = true)) {
                        MermaidBlock(block.code, complete = block.closed || !isStreaming)
                    } else {
                        CodeBlock(block.language, block.code)
                    }
                is MdBlock.Quote -> Row {
                    androidx.compose.foundation.layout.Box(
                        Modifier
                            .width(3.dp)
                            .background(quoteBar)
                            .padding(vertical = 2.dp)
                    )
                    Text(
                        inlineMarkdown(block.lines.joinToString("\n"), linkColor, codeBg, inlineCodeColor, onCodeTap, onPathTap),
                        style = baseStyle.copy(fontStyle = FontStyle.Italic),
                        color = secondary,
                        modifier = Modifier.padding(start = 10.dp),
                    )
                }
                is MdBlock.ListItem -> Row(Modifier.padding(start = (block.indent * 16).dp)) {
                    // Themed bullet glyph (— ❯ ❀ ✦ ✿) in the theme's ink.
                    val bullet = when {
                        block.marker == "☐" || block.marker == "☑" -> block.marker
                        block.marker.first().isDigit() -> block.marker
                        else -> palette.bulletGlyph.takeIf { themed } ?: "•"
                    }
                    Text(bullet, style = baseStyle, color = bulletColor, modifier = Modifier.padding(end = 8.dp))
                    Text(inlineMarkdown(block.text, linkColor, codeBg, inlineCodeColor, onCodeTap, onPathTap), style = baseStyle)
                }
                is MdBlock.Table -> MarkdownTable(block.rows, linkColor, codeBg, inlineCodeColor, baseStyle, onCodeTap)
                MdBlock.Divider -> HorizontalDivider(
                    color = if (themed) palette.ink.copy(alpha = 0.18f) else androidx.compose.material3.DividerDefaults.color,
                )
            }
            }
        }
    }
}

/** Internal (not private): MermaidBlock reuses it as the source fallback. */
@Composable
internal fun CodeBlock(language: String, code: String) {
    val clipboard = androidx.compose.ui.platform.LocalClipboardManager.current
    val palette = LocalChatPalette.current
    val themed = !palette.isDynamic
    // Copy feedback: the glyph flashes into a checkmark (the ChatGPT/GitHub
    // code-block affordance) — a silent copy reads as a broken button.
    var justCopied by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(false) }
    androidx.compose.runtime.LaunchedEffect(justCopied) {
        if (justCopied) {
            kotlinx.coroutines.delay(1200)
            justCopied = false
        }
    }
    // Fenced code renders as a separate card in the theme's own code colors
    // (mac MarkdownBlocksView code card).
    val cardBg = if (themed) palette.codeFill else MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.6f)
    val codeColor = if (themed) palette.codeText else Color.Unspecified
    val chrome = if (themed) palette.secondaryText else MaterialTheme.colorScheme.onSurfaceVariant
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(cardBg)
            .padding(12.dp)
    ) {
        Row(modifier = Modifier.fillMaxWidth()) {
            Text(
                language,
                style = MaterialTheme.typography.labelSmall,
                color = chrome,
                modifier = Modifier.weight(1f).padding(bottom = 4.dp),
            )
            // Tap-to-copy — the code block is a deliverable, same as on macOS.
            Text(
                if (justCopied) "✓" else "⧉",
                color = if (justCopied) (if (themed) palette.accent else MaterialTheme.colorScheme.primary) else chrome,
                modifier = Modifier.clickable {
                    clipboard.setText(AnnotatedString(code))
                    justCopied = true
                },
            )
        }
        Text(
            code,
            fontFamily = FontFamily.Monospace,
            fontSize = 13.sp,
            color = codeColor,
            modifier = Modifier.horizontalScroll(rememberScrollState()),
        )
    }
}

@Composable
private fun MarkdownTable(
    rows: List<List<String>>,
    linkColor: Color,
    codeBg: Color,
    inlineCodeColor: Color,
    baseStyle: TextStyle,
    onCodeTap: ((String) -> Unit)? = null,
) {
    val palette = LocalChatPalette.current
    val tableBg = if (palette.isDynamic) MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f)
        else palette.ink.copy(alpha = 0.08f)
    Column(
        Modifier
            .horizontalScroll(rememberScrollState())
            .clip(RoundedCornerShape(8.dp))
            .background(tableBg)
            .padding(8.dp)
    ) {
        rows.forEachIndexed { rowIndex, row ->
            Row {
                for (cell in row) {
                    Text(
                        inlineMarkdown(cell, linkColor, codeBg, inlineCodeColor, onCodeTap),
                        style = if (rowIndex == 0) baseStyle.copy(fontWeight = FontWeight.Bold) else baseStyle,
                        modifier = Modifier
                            .width(140.dp)
                            .padding(horizontal = 6.dp, vertical = 3.dp),
                    )
                }
            }
            if (rowIndex == 0) HorizontalDivider(
                color = if (palette.isDynamic) androidx.compose.material3.DividerDefaults.color
                else palette.ink.copy(alpha = 0.22f),
            )
        }
    }
}
