package com.aispotlight.android.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.aispotlight.android.R
import com.aispotlight.android.core.ModelInfo
import com.aispotlight.android.settings.AppSettings
import java.util.Date
import java.util.Locale

/**
 * The OpenRouter catalog inside the app: search, filters, descriptions and
 * prices from the cached `/models` payload — no trip to the website. A row
 * tap expands the details; "Select" hands the slug back.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OpenRouterModelBrowserSheet(
    settings: AppSettings,
    onDismiss: () -> Unit,
    onSelect: (String) -> Unit,
) {
    val catalog by settings.openRouterCatalog.collectAsState()
    var query by remember { mutableStateOf("") }
    var filterVision by remember { mutableStateOf(false) }
    var filterFiles by remember { mutableStateOf(false) }
    var filterTools by remember { mutableStateOf(false) }
    var filterReasoning by remember { mutableStateOf(false) }
    var filterFree by remember { mutableStateOf(false) }
    // Hide models the account's privacy settings leave no endpoint for.
    var filterAllowed by remember { mutableStateOf(true) }
    val allowedModels by settings.openRouterAllowedModels.collectAsState()
    var sort by remember { mutableStateOf(0) } // 0 newest, 1 cheapest, 2 name
    var expandedId by remember { mutableStateOf<String?>(null) }
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val uriHandler = LocalUriHandler.current
    val context = LocalContext.current

    val needle = query.trim().lowercase()
    val models = catalog.values.filter { info ->
        if (filterVision && !info.supportsVision) return@filter false
        if (filterFiles && !info.supportsFiles) return@filter false
        if (filterTools && !info.supportsTools) return@filter false
        if (filterReasoning && !info.supportsReasoning) return@filter false
        if (filterFree && !info.isFree) return@filter false
        if (filterAllowed && allowedModels != null && info.id !in allowedModels!!) return@filter false
        needle.isEmpty() || info.id.lowercase().contains(needle) ||
            (info.name ?: "").lowercase().contains(needle) ||
            (info.summary ?: "").lowercase().contains(needle)
    }.let { list ->
        when (sort) {
            0 -> list.sortedByDescending { it.createdAt ?: 0L }
            1 -> list.sortedBy { (it.promptPricePerToken ?: 0.0) + (it.completionPricePerToken ?: 0.0) }
            else -> list.sortedBy { (it.name ?: it.id).lowercase() }
        }
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = MaterialTheme.colorScheme.surfaceContainer,
    ) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.or_browser_title), style = MaterialTheme.typography.titleMedium)
                Spacer(Modifier.weight(1f))
                Text(
                    stringResource(R.string.or_count, models.size),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Spacer(Modifier.height(8.dp))
            OutlinedTextField(
                value = query,
                onValueChange = { query = it },
                modifier = Modifier.fillMaxWidth(),
                label = { Text(stringResource(R.string.or_search)) },
                singleLine = true,
                colors = eclipseFieldColors(),
            )
            Spacer(Modifier.height(8.dp))
            Row(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
            ) {
                EclipseChip(stringResource(R.string.or_filter_vision), filterVision, onClick = { filterVision = !filterVision })
                EclipseChip(stringResource(R.string.or_filter_files), filterFiles, onClick = { filterFiles = !filterFiles })
                EclipseChip(stringResource(R.string.or_filter_tools), filterTools, onClick = { filterTools = !filterTools })
                EclipseChip(stringResource(R.string.or_filter_reasoning), filterReasoning, onClick = { filterReasoning = !filterReasoning })
                EclipseChip(stringResource(R.string.or_filter_free), filterFree, onClick = { filterFree = !filterFree })
                if (allowedModels != null) {
                    EclipseChip(stringResource(R.string.or_filter_allowed), filterAllowed, onClick = { filterAllowed = !filterAllowed })
                }
            }
            Spacer(Modifier.height(6.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                EclipseChip(stringResource(R.string.or_sort_newest), sort == 0, onClick = { sort = 0 })
                EclipseChip(stringResource(R.string.or_sort_cheapest), sort == 1, onClick = { sort = 1 })
                EclipseChip(stringResource(R.string.or_sort_name), sort == 2, onClick = { sort = 2 })
            }
            Spacer(Modifier.height(8.dp))
            HorizontalDivider()
            LazyColumn(Modifier.fillMaxWidth().weight(1f, fill = false)) {
                items(models, key = { it.id }) { info ->
                    val expanded = expandedId == info.id
                    val allowed = allowedModels?.contains(info.id) ?: true
                    Column(
                        Modifier
                            .fillMaxWidth()
                            .clickable { expandedId = if (expanded) null else info.id }
                            .padding(vertical = 8.dp)
                            .alpha(if (allowed) 1f else 0.45f),
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                info.name ?: info.id,
                                style = MaterialTheme.typography.bodyMedium,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.weight(1f),
                            )
                            Spacer(Modifier.width(8.dp))
                            Text(
                                priceLabel(info, context),
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                info.id,
                                style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace),
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.weight(1f),
                            )
                            info.contextLength?.let {
                                Spacer(Modifier.width(8.dp))
                                Text(
                                    compact(it),
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        }
                        Text(
                            capabilitySummary(info),
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        if (!allowed) {
                            Text(
                                stringResource(R.string.or_not_allowed_detail),
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.error,
                            )
                        }
                        if (expanded) {
                            Spacer(Modifier.height(6.dp))
                            Text(
                                info.summary?.takeIf { it.isNotBlank() } ?: stringResource(R.string.or_no_description),
                                style = MaterialTheme.typography.bodySmall,
                            )
                            Spacer(Modifier.height(6.dp))
                            val details = buildList {
                                add("${stringResource(R.string.or_per_1m)}: ${priceLabel(info, context)}")
                                info.contextLength?.let { add("${stringResource(R.string.or_context)}: ${compact(it)}") }
                                info.maxCompletionTokens?.let { add("${stringResource(R.string.or_max_output)}: ${compact(it)}") }
                                info.createdAt?.let {
                                    add("${stringResource(R.string.or_added)}: " +
                                        java.text.DateFormat.getDateInstance(java.text.DateFormat.MEDIUM).format(Date(it * 1000)))
                                }
                            }
                            for (line in details) {
                                Text(line, style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            Spacer(Modifier.height(6.dp))
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                EclipseTextButton(stringResource(R.string.or_select), onClick = { onSelect(info.id) })
                                EclipseTextButton(stringResource(R.string.or_open_page), onClick = {
                                    uriHandler.openUri("https://openrouter.ai/${info.id}")
                                })
                            }
                        }
                    }
                    HorizontalDivider()
                }
            }
            Spacer(Modifier.height(16.dp))
        }
    }
}

private fun capabilitySummary(info: ModelInfo): String {
    val parts = mutableListOf<String>()
    if (info.supportsVision) parts.add("images")
    if (info.supportsFiles) parts.add("documents")
    if (info.supportsTools) parts.add("tools")
    if (info.supportsReasoning) parts.add("reasoning")
    if (info.isFree) parts.add("free")
    return parts.joinToString(" · ")
}

/** "$2.00 / $10.00" per 1M tokens; "free" when both are zero. */
private fun priceLabel(info: ModelInfo, context: android.content.Context): String {
    if (info.isFree) return context.getString(R.string.or_filter_free).lowercase()
    val input = (info.promptPricePerToken ?: 0.0) * 1_000_000
    val output = (info.completionPricePerToken ?: 0.0) * 1_000_000
    return "${money(input)} / ${money(output)}"
}

private fun money(value: Double): String =
    if (value < 1) String.format(Locale.US, "$%.3f", value) else String.format(Locale.US, "$%.2f", value)

/** 1000000 → "1M", 128000 → "128K". */
private fun compact(tokens: Int): String = when {
    tokens >= 1_000_000 -> {
        val m = tokens / 1_000_000.0
        if (m == Math.floor(m)) "${m.toInt()}M" else String.format(Locale.US, "%.1fM", m)
    }
    tokens >= 1_000 -> "${tokens / 1_000}K"
    else -> tokens.toString()
}
