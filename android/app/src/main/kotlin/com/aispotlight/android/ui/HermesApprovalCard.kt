package com.aispotlight.android.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import com.aispotlight.android.R
import com.aispotlight.android.hermes.HermesApprovalLedger

/** Stateless permission-card molecule; the ViewModel owns request lifecycle. */
@Composable
fun HermesApprovalCard(
    entry: HermesApprovalLedger.Entry,
    stopping: Boolean,
    resolve: (Boolean) -> Unit,
    refresh: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(modifier = modifier.fillMaxWidth(), shape = MaterialTheme.shapes.medium,
        color = MaterialTheme.colorScheme.surfaceContainer) {
        Column(Modifier.padding(12.dp)) {
            Text(stringResource(R.string.hermes_approval_title), style = MaterialTheme.typography.titleSmall)
            SelectionContainer {
                Text(entry.request.command, modifier = Modifier.padding(vertical = 8.dp), fontFamily = FontFamily.Monospace)
            }
            Text(android.net.Uri.parse(entry.request.endpoint).host ?: entry.request.endpoint,
                style = MaterialTheme.typography.bodySmall)
            if (entry.phase == HermesApprovalLedger.Phase.UNCERTAIN) {
                Text(stringResource(R.string.hermes_approval_uncertain), style = MaterialTheme.typography.bodySmall)
                OutlinedButton(onClick = refresh, enabled = !stopping) {
                    Text(stringResource(R.string.hermes_approval_refresh))
                }
            } else {
                val enabled = entry.phase == HermesApprovalLedger.Phase.READY && !stopping
                Button(onClick = { resolve(true) }, enabled = enabled) {
                    Text(stringResource(R.string.hermes_approval_once))
                }
                OutlinedButton(onClick = { resolve(false) }, enabled = enabled) {
                    Text(stringResource(R.string.hermes_approval_deny))
                }
            }
        }
    }
}
