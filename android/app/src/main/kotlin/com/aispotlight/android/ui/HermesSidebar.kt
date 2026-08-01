package com.aispotlight.android.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalDrawerSheet
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.aispotlight.android.R
import com.aispotlight.android.data.Conversation

/**
 * Hermes sessions sidebar — the Android drawer with the FULL desktop 4.0
 * feature set: create, rename, pin, color, delete, unread badges. Sessions
 * are conversation rows (`hermesSessionId`); pins/colors live in settings
 * keyed by SESSION id, exactly like the desktop `hermes.pinnedSessions` /
 * `hermes.sessionColors`.
 */

/** The desktop session palette: none + six accents. */
private val sessionColorChoices = listOf(
    null, "#F9A211", "#5B8DEF", "#4CAF7D", "#B96AD9", "#E5484D", "#8A8F98",
)

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun HermesSidebar(
    threads: List<Conversation>,
    activeId: String?,
    unreadIds: Set<String>,
    pinnedSessionIds: Set<String>,
    sessionColors: Map<String, String>,
    onOpen: (String) -> Unit,
    onNewSession: () -> Unit,
    /** A gateway create is in flight — the button shows it and goes inert. */
    creatingSession: Boolean = false,
    onRename: (conversationId: String, title: String) -> Unit,
    onTogglePin: (sessionId: String) -> Unit,
    onSetColor: (sessionId: String, hex: String?) -> Unit,
    onDelete: (conversationId: String) -> Unit,
) {
    // Pinned first (their own recency order inside), then by recency —
    // desktop sidebar sort.
    val sorted = remember(threads, pinnedSessionIds) {
        threads.sortedWith(
            compareByDescending<Conversation> { it.hermesSessionId in pinnedSessionIds }
                .thenByDescending { it.updatedAt }
        )
    }
    var renameTarget by remember { mutableStateOf<Conversation?>(null) }
    var deleteTarget by remember { mutableStateOf<Conversation?>(null) }

    ModalDrawerSheet(modifier = Modifier.width(300.dp).fillMaxHeight()) {
        Row(
            Modifier
                .fillMaxWidth()
                .padding(start = 16.dp, end = 8.dp, top = 16.dp, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("🪽", style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.width(8.dp))
            Text(
                stringResource(R.string.hermes_role),
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.weight(1f),
            )
        }
        HorizontalDivider()
        LazyColumn(Modifier.weight(1f)) {
            items(sorted.size, key = { sorted[it].id }) { index ->
                val thread = sorted[index]
                SessionRow(
                    thread = thread,
                    isActive = thread.id == activeId,
                    hasUnread = thread.id in unreadIds,
                    isPinned = thread.hermesSessionId in pinnedSessionIds,
                    colorHex = sessionColors[thread.hermesSessionId],
                    onOpen = { onOpen(thread.id) },
                    onRename = { renameTarget = thread },
                    onTogglePin = { thread.hermesSessionId?.let(onTogglePin) },
                    onSetColor = { hex -> thread.hermesSessionId?.let { onSetColor(it, hex) } },
                    onDelete = { deleteTarget = thread },
                )
            }
        }
        HorizontalDivider()
        Row(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(10.dp))
                .combinedClickable(enabled = !creatingSession, onClick = onNewSession)
                .padding(horizontal = 16.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (creatingSession) {
                // Session create = 2 slow round-trips to a remote gateway;
                // without visible progress the taps multiplied into
                // identical sessions (user feedback 2026-07-31).
                androidx.compose.material3.CircularProgressIndicator(
                    modifier = Modifier.size(18.dp),
                    strokeWidth = 2.dp,
                )
                Spacer(Modifier.width(10.dp))
                Text(
                    stringResource(R.string.hermes_creating_session),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            } else {
                Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(10.dp))
                Text(stringResource(R.string.hermes_new_session), style = MaterialTheme.typography.bodyMedium)
            }
        }
    }

    // Rename dialog (sidebar action; the gateway follows).
    renameTarget?.let { target ->
        var draft by remember(target.id) { mutableStateOf(target.title) }
        AlertDialog(
            onDismissRequest = { renameTarget = null },
            title = { Text(stringResource(R.string.hermes_rename)) },
            text = {
                OutlinedTextField(
                    value = draft,
                    onValueChange = { draft = it },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    onRename(target.id, draft)
                    renameTarget = null
                }) { Text(stringResource(R.string.action_save)) }
            },
            dismissButton = {
                TextButton(onClick = { renameTarget = null }) {
                    Text(stringResource(R.string.action_cancel))
                }
            },
        )
    }

    deleteTarget?.let { target ->
        AlertDialog(
            onDismissRequest = { deleteTarget = null },
            title = { Text(stringResource(R.string.hermes_delete_title)) },
            text = { Text(stringResource(R.string.hermes_delete_message)) },
            confirmButton = {
                TextButton(onClick = {
                    onDelete(target.id)
                    deleteTarget = null
                }) { Text(stringResource(R.string.action_delete)) }
            },
            dismissButton = {
                TextButton(onClick = { deleteTarget = null }) {
                    Text(stringResource(R.string.action_cancel))
                }
            },
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun SessionRow(
    thread: Conversation,
    isActive: Boolean,
    hasUnread: Boolean,
    isPinned: Boolean,
    colorHex: String?,
    onOpen: () -> Unit,
    onRename: () -> Unit,
    onTogglePin: () -> Unit,
    onSetColor: (String?) -> Unit,
    onDelete: () -> Unit,
) {
    var menuOpen by remember { mutableStateOf(false) }
    val accent = colorHex?.let { hex ->
        try { Color(android.graphics.Color.parseColor(hex)) } catch (_: Exception) { null }
    }
    Box {
        Row(
            Modifier
                .fillMaxWidth()
                .background(
                    if (isActive) MaterialTheme.colorScheme.secondaryContainer.copy(alpha = 0.55f)
                    else Color.Transparent
                )
                .combinedClickable(onClick = onOpen, onLongClick = { menuOpen = true })
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // Session color dot (the desktop color mark); plain wing without.
            if (accent != null) {
                Box(Modifier.size(10.dp).clip(CircleShape).background(accent))
            } else {
                Text("🪽", style = MaterialTheme.typography.labelMedium)
            }
            Spacer(Modifier.width(10.dp))
            Text(
                thread.title,
                style = MaterialTheme.typography.bodyMedium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            if (isPinned) {
                Icon(
                    Icons.Filled.PushPin,
                    contentDescription = null,
                    modifier = Modifier.size(13.dp),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.width(6.dp))
            }
            if (hasUnread) {
                Box(
                    Modifier
                        .size(8.dp)
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.primary)
                )
            } else if (isActive) {
                Icon(
                    Icons.Filled.Check,
                    contentDescription = null,
                    modifier = Modifier.size(15.dp),
                    tint = MaterialTheme.colorScheme.primary,
                )
            }
        }
        DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
            DropdownMenuItem(
                text = { Text(stringResource(R.string.hermes_rename)) },
                onClick = { menuOpen = false; onRename() },
            )
            DropdownMenuItem(
                text = {
                    Text(stringResource(
                        if (isPinned) R.string.hermes_unpin_session else R.string.hermes_pin_session
                    ))
                },
                onClick = { menuOpen = false; onTogglePin() },
            )
            // Color swatches in one row (the desktop palette).
            Row(Modifier.padding(horizontal = 12.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for (choice in sessionColorChoices) {
                    val swatch = choice?.let { hex ->
                        try { Color(android.graphics.Color.parseColor(hex)) } catch (_: Exception) { null }
                    }
                    Box(
                        Modifier
                            .size(22.dp)
                            .clip(CircleShape)
                            .background(swatch ?: MaterialTheme.colorScheme.surfaceVariant)
                            .combinedClickable(onClick = {
                                menuOpen = false
                                onSetColor(choice)
                            }),
                        contentAlignment = Alignment.Center,
                    ) {
                        if (choice == colorHex || (choice == null && colorHex == null)) {
                            Icon(
                                Icons.Filled.Check,
                                contentDescription = null,
                                modifier = Modifier.size(13.dp),
                                tint = if (swatch != null) Color.White
                                    else MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }
            }
            HorizontalDivider()
            DropdownMenuItem(
                text = {
                    Text(
                        stringResource(R.string.hermes_delete_session),
                        color = MaterialTheme.colorScheme.error,
                    )
                },
                onClick = { menuOpen = false; onDelete() },
            )
        }
    }
}
