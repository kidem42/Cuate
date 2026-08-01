package com.aispotlight.android.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.aispotlight.android.R
import com.aispotlight.android.hermes.HermesModelOptions

/**
 * Model-lock picker for Hermes sessions — replaces the flat
 * "slug · vendor/model" dropdown that dumped every provider's whole catalog
 * into one unscrollable menu (user feedback 2026-07-30). Structure instead
 * of chaos: collapsible provider sections, vendor subheaders inside each
 * (models arrive as "anthropic/claude-…", "openai/gpt-…"), a search field
 * across everything, and a Refresh button mapped to the gateway's
 * `?refresh=true` cache drop.
 */
@Composable
fun HermesModelPicker(
    options: HermesModelOptions?,
    /** The currently locked (provider slug, model) pair, if any. */
    selected: Pair<String, String>?,
    /** Non-null adds the "as configured in the agent" row (settings default). */
    onPickAgentDefault: (() -> Unit)?,
    onPick: (provider: String, model: String) -> Unit,
    onRefresh: () -> Unit,
    onDismiss: () -> Unit,
) {
    var query by remember { mutableStateOf("") }
    // Providers collapse by default except the agent's current one (or a
    // lone provider); a live search overrides and shows every match. A tap
    // on a header records an explicit user choice in [overrides].
    val overrides = remember { mutableStateOf<Map<String, Boolean>>(emptyMap()) }
    val providers = options?.providers.orEmpty()
    val initiallyExpanded = remember(providers, selected) {
        providers.filter { provider ->
            provider.isCurrent || providers.size == 1 ||
                // The section holding the session's model opens too — the
                // checkmark must be visible without digging.
                (selected != null && selected.second in provider.models &&
                    (selected.first.isEmpty() || selected.first == provider.slug))
        }.map { it.slug }.toSet()
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(stringResource(R.string.hermes_menu_model))
                    // The session's ACTIVE model, right where the choice is
                    // made — the checkmark deep in a collapsed section was
                    // not an answer to "what am I talking to?".
                    val active = selected?.second ?: options?.current?.second
                    if (active != null) {
                        Text(
                            stringResource(R.string.hermes_model_active, active.substringAfterLast("/")),
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.primary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
                IconButton(onClick = onRefresh) {
                    Icon(
                        Icons.Filled.Refresh,
                        contentDescription = stringResource(R.string.hermes_model_refresh),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        },
        text = {
            Column {
                OutlinedTextField(
                    value = query,
                    onValueChange = { query = it },
                    placeholder = { Text(stringResource(R.string.hermes_model_search)) },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                )
                val filter = query.trim().lowercase()
                LazyColumn(Modifier.heightIn(max = 420.dp).padding(top = 8.dp)) {
                    if (onPickAgentDefault != null && filter.isEmpty()) {
                        item {
                            ModelRow(
                                title = stringResource(R.string.hermes_model_agent_default),
                                subtitle = options?.current?.let { "${it.first} · ${it.second}" },
                                checked = selected == null,
                                onClick = onPickAgentDefault,
                            )
                        }
                    }
                    if (providers.isEmpty()) {
                        item {
                            Text(
                                stringResource(R.string.hermes_model_empty),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.padding(vertical = 12.dp),
                            )
                        }
                    }
                    for (provider in providers) {
                        val matches = if (filter.isEmpty()) provider.models
                            else provider.models.filter {
                                it.lowercase().contains(filter) ||
                                    provider.name.lowercase().contains(filter) ||
                                    provider.slug.lowercase().contains(filter)
                            }
                        if (matches.isEmpty()) continue
                        val open = filter.isNotEmpty() ||
                            (overrides.value[provider.slug] ?: (provider.slug in initiallyExpanded))
                        item(key = "provider-${provider.slug}") {
                            Row(
                                Modifier
                                    .fillMaxWidth()
                                    .clickable {
                                        overrides.value = overrides.value + (provider.slug to !open)
                                    }
                                    .padding(vertical = 10.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(6.dp),
                            ) {
                                Text(
                                    provider.name,
                                    style = MaterialTheme.typography.titleSmall,
                                    modifier = Modifier.weight(1f, fill = false),
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                                if (provider.isCurrent) {
                                    Text(
                                        stringResource(R.string.hermes_model_current),
                                        style = MaterialTheme.typography.labelSmall,
                                        color = MaterialTheme.colorScheme.primary,
                                    )
                                }
                                Text(
                                    "${matches.size}",
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                                Icon(
                                    if (open) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
                                    contentDescription = null,
                                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.size(18.dp),
                                )
                            }
                        }
                        if (!open) continue
                        // Vendor subgroups: "anthropic/claude-…" sorts under
                        // an "anthropic" subheader; models without a vendor
                        // prefix land in a headerless group first.
                        val groups = matches.groupBy { it.substringBefore("/", "") }
                            .toSortedMap(compareBy({ it.isNotEmpty() }, { it }))
                        for ((vendor, models) in groups) {
                            if (vendor.isNotEmpty() && groups.size > 1) {
                                item(key = "vendor-${provider.slug}-$vendor") {
                                    Text(
                                        vendor,
                                        style = MaterialTheme.typography.labelMedium,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        modifier = Modifier.padding(start = 8.dp, top = 6.dp, bottom = 2.dp),
                                    )
                                }
                            }
                            for (model in models) {
                                item(key = "model-${provider.slug}-$model") {
                                    val short = model.substringAfter("/")
                                    // An empty selected provider means the pair
                                    // came from the session list (model only) —
                                    // match the mark on the model alone.
                                    val checked = selected != null &&
                                        selected.second == model &&
                                        (selected.first.isEmpty() || selected.first == provider.slug)
                                    ModelRow(
                                        title = short,
                                        subtitle = if (short != model) model else null,
                                        checked = checked,
                                        onClick = { onPick(provider.slug, model) },
                                        indent = 8.dp,
                                    )
                                }
                            }
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) {
                Text(stringResource(R.string.action_close))
            }
        },
    )
}

@Composable
private fun ModelRow(
    title: String,
    subtitle: String?,
    checked: Boolean,
    onClick: () -> Unit,
    indent: androidx.compose.ui.unit.Dp = 0.dp,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(start = indent, top = 6.dp, bottom = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(
                title,
                style = MaterialTheme.typography.bodyMedium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (subtitle != null) {
                Text(
                    subtitle,
                    style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        if (checked) {
            Icon(
                Icons.Filled.Check,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(18.dp),
            )
        }
    }
}
