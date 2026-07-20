package com.aispotlight.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * Eclipse settings primitives — the claude.ai/design prototype's structure:
 * a section is ONE glass card (subtle gradient fill, 1dp border, 20dp
 * corners, soft shadow with an orange cast) whose rows are separated by
 * hairline dividers; the section title sits above in uppercase accent
 * lettering. Replaces the former M3 Expressive split-card stacks.
 */

/** Collects the group's rows so dividers can be placed between them. */
class SettingsGroupScope internal constructor() {
    internal val items = mutableListOf<@Composable () -> Unit>()
    fun item(content: @Composable () -> Unit) {
        items.add(content)
    }
}

/**
 * One settings section: uppercase accent header + a glass card stack with
 * hairline dividers between rows.
 */
@Composable
fun SettingsGroup(
    title: String? = null,
    modifier: Modifier = Modifier,
    builder: SettingsGroupScope.() -> Unit,
) {
    val ecl = LocalEclipsePalette.current
    val scope = SettingsGroupScope().apply(builder)
    if (scope.items.isEmpty()) return
    val shape = RoundedCornerShape(20.dp)
    Column(modifier.fillMaxWidth()) {
        if (title != null) {
            Text(
                title.uppercase(),
                fontSize = 11.sp,
                letterSpacing = 1.2.sp,
                fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold,
                color = ecl.accent,
                modifier = Modifier.padding(start = 18.dp, top = 6.dp, bottom = 8.dp),
            )
        }
        Column(
            Modifier
                // Soft drop shadow with the eclipse-orange cast under the card.
                .themedGlow(
                    (if (ecl.dark) ecl.glow.copy(alpha = 0.10f) else ecl.glow.copy(alpha = 0.14f)),
                    14.dp, cornerRadius = 20.dp, yOffset = 6.dp,
                )
                .clip(shape)
                .background(Brush.verticalGradient(listOf(ecl.stackTop, ecl.stackBottom)))
                .border(1.dp, ecl.stackBorder, shape),
        ) {
            scope.items.forEachIndexed { index, item ->
                if (index > 0) HorizontalDivider(thickness = 1.dp, color = ecl.divider)
                Box(
                    Modifier
                        .fillMaxWidth()
                        .defaultMinSize(minHeight = 56.dp)
                        .padding(horizontal = 16.dp, vertical = 13.dp),
                    contentAlignment = Alignment.CenterStart,
                ) {
                    item()
                }
            }
        }
    }
}

/** Title + optional supporting line, used inside custom rows. */
@Composable
fun SettingsRowLabel(title: String, subtitle: String? = null, modifier: Modifier = Modifier) {
    val ecl = LocalEclipsePalette.current
    Column(modifier) {
        Text(title, style = MaterialTheme.typography.bodyLarge, color = ecl.text)
        if (subtitle != null) {
            Text(
                subtitle,
                style = MaterialTheme.typography.bodySmall,
                color = ecl.sub,
            )
        }
    }
}

/** Full-row toggle: tapping anywhere flips the eclipse switch. */
@Composable
fun SettingsSwitchRow(
    title: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    subtitle: String? = null,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable { onCheckedChange(!checked) },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        SettingsRowLabel(title, subtitle, Modifier.weight(1f))
        Spacer(Modifier.width(12.dp))
        EclipseSwitch(checked = checked, onCheckedChange = onCheckedChange)
    }
}

/**
 * Category row for the settings home screen: glass icon circle with the
 * accent-tinted outline icon, title, current-value subtitle and a chevron.
 */
@Composable
fun SettingsNavRow(
    icon: ImageVector,
    title: String,
    subtitle: String?,
    onClick: () -> Unit,
) {
    val ecl = LocalEclipsePalette.current
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier
                .size(40.dp)
                .background(ecl.iconBg, CircleShape)
                .border(1.dp, ecl.iconBorder, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                icon,
                contentDescription = null,
                tint = ecl.accent,
                modifier = Modifier.size(20.dp),
            )
        }
        Spacer(Modifier.width(16.dp))
        SettingsRowLabel(title, subtitle, Modifier.weight(1f))
        Icon(
            Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = ecl.chevron,
        )
    }
}

/** Small helper note under a group (bodySmall, muted, indented). */
@Composable
fun SettingsFootnote(text: String, isError: Boolean = false) {
    val ecl = LocalEclipsePalette.current
    Text(
        text,
        style = MaterialTheme.typography.bodySmall,
        color = if (isError) ecl.delete else ecl.sub,
        modifier = Modifier.padding(horizontal = 18.dp, vertical = 4.dp),
    )
}
