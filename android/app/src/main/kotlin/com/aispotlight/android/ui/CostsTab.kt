package com.aispotlight.android.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aispotlight.android.R
import com.aispotlight.android.core.ProviderID
import com.aispotlight.android.core.TokenUsage
import com.aispotlight.android.data.AppDatabase
import com.aispotlight.android.data.SpendKind
import com.aispotlight.android.data.SpendRecordEntity
import com.aispotlight.android.data.SpendTracker
import com.aispotlight.android.providers.PricingCatalog
import com.aispotlight.android.settings.AppSettings
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

/**
 * Settings → Costs: local spend analytics over the append-only ledger.
 * Eclipse-styled (glass card groups, chips, orange accent); adaptive — the
 * two chart groups sit side by side when the window is wide enough (tablets,
 * unfolded foldables), and content is width-capped so it never stretches
 * edge-to-edge on large screens.
 */
@Composable
fun CostsTab(settings: AppSettings) {
    val context = LocalContext.current
    val ecl = LocalEclipsePalette.current

    val sessionUSD by SpendTracker.sessionUSD.collectAsState()
    val todayUSD by SpendTracker.todayUSD.collectAsState()
    val monthUSD by SpendTracker.monthUSD.collectAsState()
    val budget by SpendTracker.monthlyBudgetUSD.collectAsState()

    var selectedMonthStart by rememberSaveable {
        mutableStateOf(SpendTracker.monthBounds(System.currentTimeMillis()).first)
    }
    var records by remember { mutableStateOf<List<SpendRecordEntity>>(emptyList()) }
    var currentMonthChats by remember { mutableStateOf<List<SpendRecordEntity>>(emptyList()) }
    var earliest by remember { mutableStateOf<Long?>(null) }
    var byModel by rememberSaveable { mutableStateOf(false) }
    var reloadTick by remember { mutableStateOf(0) }

    LaunchedEffect(Unit) { SpendTracker.refreshTotals() }
    LaunchedEffect(selectedMonthStart, reloadTick) {
        val dao = AppDatabase.get(context).spendDao()
        earliest = dao.earliestTimestamp()
        records = dao.recordsBetween(selectedMonthStart, nextMonthStart(selectedMonthStart))
        val (curStart, curEnd) = SpendTracker.monthBounds(System.currentTimeMillis())
        currentMonthChats = dao.recordsBetween(curStart, curEnd).filter { it.kind == SpendKind.CHAT.raw }
    }

    val openRouterCatalog by settings.openRouterCatalog.collectAsState()
    // Display cost: fixed at write time, or a live re-quote for records that
    // had no known price back then (model added to the catalog later).
    fun displayCost(record: SpendRecordEntity): Double? {
        record.costUSD?.let { return it }
        if (record.kind != SpendKind.CHAT.raw && record.kind != SpendKind.SUMMARY.raw) return null
        val provider = ProviderID.fromId(record.provider) ?: return null
        if (provider == ProviderID.OPENROUTER) {
            val info = openRouterCatalog[record.model]
            val p = info?.promptPricePerToken
            val c = info?.completionPricePerToken
            if (p != null && c != null) {
                return record.usage.inputTokens * p + record.usage.outputTokens * c +
                    record.usage.cacheReadTokens * p + record.usage.cacheWriteTokens * p
            }
        }
        return PricingCatalog.pricing(provider, record.model)?.cost(record.usage)
    }

    // ── Aggregates ─────────────────────────────────────────────────────────
    val modelLines = remember(records, openRouterCatalog) {
        buildModelLines(records) { displayCost(it) }
    }
    val providerGroups = remember(modelLines, records) {
        buildProviderGroups(modelLines, records)
    }
    val dailySlices = remember(records, byModel, openRouterCatalog) {
        buildDailySlices(records, byModel) { displayCost(it) }
    }
    val avg = remember(currentMonthChats, records) {
        // Current-month chats; falls back to the selected month's records when
        // the dedicated query hasn't landed yet (or the user browses history).
        val chats = currentMonthChats.ifEmpty {
            records.filter { it.kind == SpendKind.CHAT.raw }
        }
        if (chats.isEmpty()) null else Triple(
            chats.sumOf { it.inputTokens + it.cacheReadTokens + it.cacheWriteTokens } / chats.size,
            chats.sumOf { it.outputTokens } / chats.size,
            chats.size,
        )
    }

    // Width-capped, centered content — phones use full width, tablets and
    // unfolded foldables get a comfortable column instead of edge-to-edge.
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val wide = maxWidth >= 760.dp
        Column(
            Modifier
                .widthIn(max = 720.dp)
                .align(Alignment.TopCenter)
                .fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            summaryGroup(sessionUSD, todayUSD, monthUSD, budget, avg, ecl)

            if (records.isEmpty()) {
                SettingsGroup { item { Text(stringResource(R.string.costs_empty), color = ecl.sub) } }
            } else if (wide) {
                // Tablet / unfolded: charts side by side.
                Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                    Box(Modifier.weight(1f)) {
                        dailyChartGroup(
                            dailySlices, byModel, { byModel = it },
                            selectedMonthStart, earliest,
                            onStepMonth = { selectedMonthStart = stepMonth(selectedMonthStart, it, earliest) },
                            ecl,
                        )
                    }
                    Box(Modifier.weight(1f)) { topModelsGroup(modelLines, ecl) }
                }
                breakdownGroup(providerGroups, ecl)
            } else {
                dailyChartGroup(
                    dailySlices, byModel, { byModel = it },
                    selectedMonthStart, earliest,
                    onStepMonth = { selectedMonthStart = stepMonth(selectedMonthStart, it, earliest) },
                    ecl,
                )
                topModelsGroup(modelLines, ecl)
                breakdownGroup(providerGroups, ecl)
            }

            budgetGroup(budget, ecl)
        }
    }
}

// ── Summary ────────────────────────────────────────────────────────────────

@Composable
private fun summaryGroup(
    sessionUSD: Double,
    todayUSD: Double,
    monthUSD: Double,
    budget: Double,
    avg: Triple<Int, Int, Int>?,
    ecl: EclipsePalette,
) {
    SettingsGroup(title = stringResource(R.string.tab_costs)) {
        item { valueRow(stringResource(R.string.costs_session), SpendTracker.usd(sessionUSD), ecl) }
        item { valueRow(stringResource(R.string.costs_today), SpendTracker.usd(todayUSD), ecl) }
        item {
            Column(Modifier.fillMaxWidth()) {
                valueRow(stringResource(R.string.costs_month), SpendTracker.usd(monthUSD), ecl)
                // Sub-row of "This month": always present, so the metric is
                // discoverable even before the first chat record lands.
                Row(
                    Modifier.fillMaxWidth().padding(start = 16.dp, top = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        stringResource(R.string.costs_avg_per_message),
                        style = MaterialTheme.typography.bodyMedium, color = ecl.sub,
                        modifier = Modifier.weight(1f),
                    )
                    Text(
                        if (avg != null) {
                            "${stringResource(R.string.costs_tokens_in)} ${compact(avg.first)} · " +
                                "${stringResource(R.string.costs_tokens_out)} ${compact(avg.second)}"
                        } else "—",
                        style = MaterialTheme.typography.bodyMedium, color = ecl.sub,
                    )
                }
                if (budget > 0) {
                    val fraction = (monthUSD / budget).coerceIn(0.0, 1.0).toFloat()
                    val fillColor = when {
                        monthUSD >= budget -> ecl.delete
                        monthUSD >= budget * 0.8 -> Color(0xFFF08A2E)
                        else -> null // accent gradient
                    }
                    Box(
                        Modifier
                            .fillMaxWidth()
                            .padding(top = 10.dp)
                            .height(6.dp)
                            .clip(CircleShape)
                            .background(ecl.track),
                    ) {
                        Box(
                            Modifier
                                .fillMaxWidth(fraction)
                                .height(6.dp)
                                .clip(CircleShape)
                                .background(
                                    if (fillColor != null) Brush.horizontalGradient(listOf(fillColor, fillColor))
                                    else Brush.horizontalGradient(ecl.accentGradient)
                                ),
                        )
                    }
                    Text(
                        "${SpendTracker.usd(monthUSD)} / ${SpendTracker.usd(budget)}",
                        style = MaterialTheme.typography.bodySmall, color = ecl.sub,
                        modifier = Modifier.padding(top = 4.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun valueRow(label: String, value: String, ecl: EclipsePalette) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(label, style = MaterialTheme.typography.bodyLarge, color = ecl.text, modifier = Modifier.weight(1f))
        Text(value, style = MaterialTheme.typography.bodyLarge, color = ecl.text, fontWeight = FontWeight.Medium)
    }
}

// ── Daily chart ────────────────────────────────────────────────────────────

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun dailyChartGroup(
    slices: List<DaySlice>,
    byModel: Boolean,
    onDimension: (Boolean) -> Unit,
    monthStart: Long,
    earliest: Long?,
    onStepMonth: (Int) -> Unit,
    ecl: EclipsePalette,
) {
    SettingsGroup(title = stringResource(R.string.costs_daily_chart)) {
        item {
            Column(Modifier.fillMaxWidth()) {
                // Month picker row.
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        stringResource(R.string.costs_period),
                        style = MaterialTheme.typography.bodyLarge, color = ecl.text,
                        modifier = Modifier.weight(1f),
                    )
                    val canBack = earliest != null &&
                        SpendTracker.monthBounds(earliest).first < monthStart
                    val canForward = monthStart < SpendTracker.monthBounds(System.currentTimeMillis()).first
                    IconButton(onClick = { onStepMonth(-1) }, enabled = canBack) {
                        Icon(
                            Icons.AutoMirrored.Filled.KeyboardArrowLeft,
                            contentDescription = stringResource(R.string.costs_prev_month),
                            tint = if (canBack) ecl.accent else ecl.chevron,
                        )
                    }
                    Text(
                        monthTitle(monthStart),
                        style = MaterialTheme.typography.bodyLarge, color = ecl.text,
                        fontWeight = FontWeight.Medium,
                    )
                    IconButton(onClick = { onStepMonth(1) }, enabled = canForward) {
                        Icon(
                            Icons.AutoMirrored.Filled.KeyboardArrowRight,
                            contentDescription = stringResource(R.string.costs_next_month),
                            tint = if (canForward) ecl.accent else ecl.chevron,
                        )
                    }
                }
                // Dimension chips.
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(bottom = 12.dp)) {
                    EclipseChip(stringResource(R.string.costs_by_providers), selected = !byModel, onClick = { onDimension(false) })
                    EclipseChip(stringResource(R.string.costs_by_models), selected = byModel, onClick = { onDimension(true) })
                }
                DailyBarChart(slices, monthStart, ecl)
                // Legend.
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    modifier = Modifier.padding(top = 10.dp),
                ) {
                    slices.map { it.label to it.color }.distinct().take(8).forEach { (label, color) ->
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Box(Modifier.size(8.dp).background(color, CircleShape))
                            Spacer(Modifier.width(5.dp))
                            Text(label, fontSize = 11.sp, color = ecl.sub)
                        }
                    }
                }
            }
        }
    }
}

/** Stacked bars, one per day of the month, with day-number labels underneath.
 *  Pure Canvas — no chart library. */
@Composable
private fun DailyBarChart(slices: List<DaySlice>, monthStart: Long, ecl: EclipsePalette) {
    val daysInMonth = Calendar.getInstance().apply { timeInMillis = monthStart }
        .getActualMaximum(Calendar.DAY_OF_MONTH)
    // day → ordered segments.
    val byDay = slices.groupBy { it.day }
    val maxTotal = byDay.values.maxOfOrNull { day -> day.sumOf { it.cost } } ?: 0.0
    val gridColor = ecl.divider
    val textMeasurer = androidx.compose.ui.text.rememberTextMeasurer()
    val labelStyle = androidx.compose.ui.text.TextStyle(fontSize = 9.sp, color = ecl.sub)
    Canvas(Modifier.fillMaxWidth().height(176.dp)) {
        if (maxTotal <= 0.0) return@Canvas
        val labelZone = 16.dp.toPx()
        val chartHeight = size.height - labelZone
        val slot = size.width / daysInMonth
        val barWidth = slot * 0.68f
        // Hairline baseline + midline.
        drawLine(gridColor, start = center.copy(x = 0f, y = chartHeight), end = center.copy(x = size.width, y = chartHeight))
        drawLine(gridColor, start = center.copy(x = 0f, y = chartHeight / 2), end = center.copy(x = size.width, y = chartHeight / 2))
        for ((day, segments) in byDay) {
            val x = slot * (day - 1) + (slot - barWidth) / 2
            var top = chartHeight
            for (segment in segments.sortedBy { it.label }) {
                val h = (segment.cost / maxTotal * chartHeight).toFloat()
                top -= h
                drawRoundRect(
                    color = segment.color,
                    topLeft = androidx.compose.ui.geometry.Offset(x, top),
                    size = androidx.compose.ui.geometry.Size(barWidth, h),
                    cornerRadius = androidx.compose.ui.geometry.CornerRadius(2.dp.toPx()),
                )
            }
        }
        // Day-of-month labels: 1, 5, 10, … plus the last day; skip a label
        // that would crowd the final one.
        val labelDays = (listOf(1) + (5..daysInMonth step 5)).filter { it <= daysInMonth }
            .let { days -> if (daysInMonth - (days.lastOrNull() ?: 0) >= 3) days + daysInMonth else days }
        for (day in labelDays) {
            val layout = textMeasurer.measure(
                androidx.compose.ui.text.AnnotatedString("$day"), style = labelStyle
            )
            val x = (slot * (day - 1) + slot / 2 - layout.size.width / 2)
                .coerceIn(0f, size.width - layout.size.width)
            drawText(
                layout,
                topLeft = androidx.compose.ui.geometry.Offset(x, chartHeight + 3.dp.toPx()),
            )
        }
    }
}

// ── Top models ─────────────────────────────────────────────────────────────

@Composable
private fun topModelsGroup(lines: List<ModelLine>, ecl: EclipsePalette) {
    val top = lines.filter { it.cost > 0 }.take(6)
    if (top.isEmpty()) return
    val maxCost = top.maxOf { it.cost }
    SettingsGroup(title = stringResource(R.string.costs_top_models)) {
        item {
            Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                for (line in top) {
                    Column {
                        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                line.shortLabel, style = MaterialTheme.typography.bodyMedium,
                                color = ecl.text, modifier = Modifier.weight(1f),
                            )
                            Text(
                                SpendTracker.usd(line.cost),
                                style = MaterialTheme.typography.bodyMedium, color = ecl.sub,
                            )
                        }
                        Box(
                            Modifier
                                .fillMaxWidth((line.cost / maxCost).toFloat().coerceAtLeast(0.02f))
                                .padding(top = 4.dp)
                                .height(6.dp)
                                .clip(CircleShape)
                                .background(providerColor(line.provider)),
                        )
                    }
                }
            }
        }
    }
}

// ── Breakdown (grouped by provider) ────────────────────────────────────────

@Composable
private fun breakdownGroup(groups: List<ProviderGroup>, ecl: EclipsePalette) {
    val collapsed = remember { mutableStateMapOf<String, Boolean>() }
    SettingsGroup(title = stringResource(R.string.costs_breakdown)) {
        for (group in groups) {
            item {
                val isCollapsed = collapsed[group.provider] == true
                Column(Modifier.fillMaxWidth()) {
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .clickable { collapsed[group.provider] = !isCollapsed },
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Box(Modifier.size(8.dp).background(providerColor(group.provider), CircleShape))
                        Spacer(Modifier.width(8.dp))
                        Text(
                            group.label, style = MaterialTheme.typography.bodyLarge,
                            color = ecl.text, fontWeight = FontWeight.Medium,
                            modifier = Modifier.weight(1f),
                        )
                        Text(
                            SpendTracker.usd(group.totalCost),
                            style = MaterialTheme.typography.bodyLarge, color = ecl.text,
                        )
                        Spacer(Modifier.width(4.dp))
                        Icon(
                            Icons.Filled.KeyboardArrowDown, contentDescription = null,
                            tint = ecl.chevron,
                            modifier = Modifier.rotate(if (isCollapsed) -90f else 0f),
                        )
                    }
                    AnimatedVisibility(visible = !isCollapsed) {
                        Column(
                            Modifier.fillMaxWidth().padding(start = 16.dp, top = 8.dp),
                            verticalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            for (line in group.chatLines) {
                                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                                    Column(Modifier.weight(1f)) {
                                        Text(
                                            line.shortLabel + (if (line.hasEstimates) " ≈" else ""),
                                            style = MaterialTheme.typography.bodyMedium, color = ecl.text,
                                        )
                                        Text(
                                            "${stringResource(R.string.costs_tokens_in)} ${compact(line.usage.inputTokens + line.usage.cacheReadTokens + line.usage.cacheWriteTokens)} · " +
                                                "${stringResource(R.string.costs_tokens_out)} ${compact(line.usage.outputTokens)} · " +
                                                "${stringResource(R.string.costs_cache)} ${compact(line.usage.cacheReadTokens)}",
                                            fontSize = 11.sp, color = ecl.sub,
                                        )
                                    }
                                    Text(
                                        if (line.hasPrice) SpendTracker.usd(line.cost)
                                        else stringResource(R.string.costs_no_price),
                                        style = MaterialTheme.typography.bodyMedium,
                                        color = if (line.hasPrice) ecl.text else ecl.sub,
                                    )
                                }
                            }
                            for (service in group.serviceLines) {
                                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                                    Text(
                                        "${service.label}: ${service.detail}",
                                        style = MaterialTheme.typography.bodyMedium, color = ecl.text,
                                        modifier = Modifier.weight(1f),
                                    )
                                    Text(
                                        if (service.cost > 0) SpendTracker.usd(service.cost) else "—",
                                        style = MaterialTheme.typography.bodyMedium, color = ecl.sub,
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
        if (groups.any { it.hasEstimates }) {
            item { Text(stringResource(R.string.costs_estimated), fontSize = 11.sp, color = ecl.sub) }
        }
        item { Text(stringResource(R.string.costs_footer), fontSize = 11.sp, color = ecl.sub) }
    }
}

// ── Budget ─────────────────────────────────────────────────────────────────

@Composable
private fun budgetGroup(budget: Double, ecl: EclipsePalette) {
    SettingsGroup(title = stringResource(R.string.costs_budget_header)) {
        item {
            var draft by rememberSaveable(budget) {
                mutableStateOf(if (budget > 0) trimZeros(budget) else "")
            }
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    stringResource(R.string.costs_budget),
                    style = MaterialTheme.typography.bodyLarge, color = ecl.text,
                    modifier = Modifier.weight(1f),
                )
                OutlinedTextField(
                    value = draft,
                    onValueChange = { value ->
                        draft = value.filter { it.isDigit() || it == '.' }.take(8)
                        SpendTracker.setMonthlyBudget(draft.toDoubleOrNull() ?: 0.0)
                    },
                    modifier = Modifier.width(110.dp),
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    placeholder = { Text("0", color = ecl.sub) },
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedTextColor = ecl.text,
                        unfocusedTextColor = ecl.text,
                        focusedBorderColor = ecl.accent,
                        unfocusedBorderColor = ecl.fieldBorder,
                        focusedContainerColor = ecl.fieldBg,
                        unfocusedContainerColor = ecl.fieldBg,
                    ),
                )
            }
        }
    }
    SettingsFootnote(stringResource(R.string.costs_budget_note))
}

// ── Aggregation helpers ────────────────────────────────────────────────────

private data class ModelLine(
    val provider: String,
    val model: String,
    val usage: TokenUsage,
    val cost: Double,
    val hasPrice: Boolean,
    val hasEstimates: Boolean,
) {
    val shortLabel: String
        get() {
            val bare = model.substringAfterLast('/')
            return if (bare.length > 30) bare.take(28) + "…" else bare
        }
}

private data class ServiceLine(val label: String, val detail: String, val cost: Double)

private data class ProviderGroup(
    val provider: String,
    val label: String,
    val totalCost: Double,
    val chatLines: List<ModelLine>,
    val serviceLines: List<ServiceLine>,
) {
    val hasEstimates: Boolean get() = chatLines.any { it.hasEstimates }
}

private data class DaySlice(val day: Int, val label: String, val color: Color, val cost: Double)

private fun buildModelLines(
    records: List<SpendRecordEntity>,
    displayCost: (SpendRecordEntity) -> Double?,
): List<ModelLine> {
    val chat = records.filter { it.kind == SpendKind.CHAT.raw || it.kind == SpendKind.SUMMARY.raw }
    return chat.groupBy { it.provider to it.model }.map { (key, group) ->
        var usage = TokenUsage()
        var cost = 0.0
        var hasPrice = false
        for (record in group) {
            usage = usage.merged(record.usage)
            displayCost(record)?.let { cost += it; hasPrice = true }
        }
        ModelLine(
            provider = key.first, model = key.second, usage = usage, cost = cost,
            hasPrice = hasPrice, hasEstimates = group.any { it.isEstimate },
        )
    }.sortedByDescending { it.cost }
}

private fun buildProviderGroups(
    modelLines: List<ModelLine>,
    records: List<SpendRecordEntity>,
): List<ProviderGroup> {
    val serviceKinds = setOf(SpendKind.OCR.raw, SpendKind.STT.raw, SpendKind.SEARCH.raw, SpendKind.IMAGE.raw)
    val services = records.filter { it.kind in serviceKinds }
        .groupBy { Triple(it.provider, it.kind, it.model) }
    val providers = (modelLines.map { it.provider } + services.keys.map { it.first }).distinct()
    return providers.map { provider ->
        val chatLines = modelLines.filter { it.provider == provider }
        val serviceLines = services.filterKeys { it.first == provider }.map { (key, group) ->
            val units = group.sumOf { it.units }
            val cost = group.sumOf { it.costUSD ?: 0.0 }
            val kind = SpendKind.fromRaw(key.second)
            ServiceLine(
                label = when (kind) {
                    SpendKind.OCR -> "OCR"
                    SpendKind.STT -> "STT"
                    SpendKind.SEARCH -> "Search"
                    else -> "Images"
                },
                detail = when (kind) {
                    SpendKind.STT -> String.format(Locale.US, "%.1f min", units)
                    SpendKind.OCR -> "${units.toInt()} p."
                    SpendKind.SEARCH -> "${units.toInt()}"
                    else -> "${units.toInt()} · ${key.third.substringAfterLast('/')}"
                },
                cost = cost,
            )
        }.sortedByDescending { it.cost }
        ProviderGroup(
            provider = provider,
            label = providerLabel(provider),
            totalCost = chatLines.sumOf { it.cost } + serviceLines.sumOf { it.cost },
            chatLines = chatLines,
            serviceLines = serviceLines,
        )
    }.sortedByDescending { it.totalCost }
}

/** Distinct colors for the by-model chart dimension (brand-agnostic cycle). */
private val modelPalette = listOf(
    Color(0xFFF08A2E), Color(0xFF4285F4), Color(0xFF10A37F), Color(0xFF6467F2),
    Color(0xFFFA520F), Color(0xFF4D6BFE), Color(0xFF9C27B0), Color(0xFF00897B),
)

private fun buildDailySlices(
    records: List<SpendRecordEntity>,
    byModel: Boolean,
    displayCost: (SpendRecordEntity) -> Double?,
): List<DaySlice> {
    data class Key(val day: Int, val label: String, val provider: String)
    val buckets = mutableMapOf<Key, Double>()
    val cal = Calendar.getInstance()
    for (record in records) {
        val cost = displayCost(record) ?: record.costUSD ?: continue
        if (cost <= 0) continue
        cal.timeInMillis = record.timestamp
        val day = cal.get(Calendar.DAY_OF_MONTH)
        val label =
            if (byModel) record.model.substringAfterLast('/').ifEmpty { providerLabel(record.provider) }
            else providerLabel(record.provider)
        val key = Key(day, label, record.provider)
        buckets[key] = (buckets[key] ?: 0.0) + cost
    }
    val labels = buckets.keys.map { it.label }.distinct()
    return buckets.map { (key, cost) ->
        DaySlice(
            day = key.day,
            label = key.label,
            color = if (byModel) modelPalette[labels.indexOf(key.label) % modelPalette.size]
            else providerColor(key.provider),
            cost = cost,
        )
    }.sortedBy { it.day }
}

// ── Small helpers ──────────────────────────────────────────────────────────

private fun providerLabel(raw: String): String =
    ProviderID.fromId(raw)?.displayName ?: raw.replaceFirstChar { it.uppercase() }

private fun providerColor(raw: String): Color =
    ProviderID.fromId(raw)?.let { Color(it.brandColor) } ?: when (raw) {
        "fal" -> Color(0xFF4CAF50)
        "brave" -> Color(0xFFFB542B)
        "deepgram" -> Color(0xFF9C27B0)
        else -> Color(0xFF26A69A)
    }

private fun nextMonthStart(monthStart: Long): Long = Calendar.getInstance().apply {
    timeInMillis = monthStart
    add(Calendar.MONTH, 1)
}.timeInMillis

private fun stepMonth(monthStart: Long, delta: Int, earliest: Long?): Long {
    val next = Calendar.getInstance().apply {
        timeInMillis = monthStart
        add(Calendar.MONTH, delta)
    }.timeInMillis
    val lower = earliest?.let { SpendTracker.monthBounds(it).first } ?: monthStart
    val upper = SpendTracker.monthBounds(System.currentTimeMillis()).first
    return next.coerceIn(lower, upper)
}

private fun monthTitle(monthStart: Long): String {
    val formatter = SimpleDateFormat("LLLL yyyy", Locale.getDefault())
    return formatter.format(Date(monthStart)).replaceFirstChar { it.uppercase() }
}

/** 12345 → "12.3k", 1234567 → "1.2M". */
private fun compact(n: Int): String = when {
    n >= 1_000_000 -> String.format(Locale.US, "%.1fM", n / 1_000_000.0)
    n >= 1_000 -> String.format(Locale.US, "%.1fk", n / 1_000.0)
    else -> "$n"
}

private fun trimZeros(value: Double): String =
    if (value == value.toLong().toDouble()) value.toLong().toString() else value.toString()
