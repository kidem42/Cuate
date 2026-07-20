package com.aispotlight.android.data

import android.content.Context
import android.content.SharedPreferences
import androidx.room.Dao
import androidx.room.Entity
import androidx.room.Index
import androidx.room.Insert
import androidx.room.PrimaryKey
import androidx.room.Query
import com.aispotlight.android.R
import com.aispotlight.android.core.Diagnostics
import com.aispotlight.android.core.TokenUsage
import com.aispotlight.android.providers.PricingCatalog
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import java.util.Calendar
import java.util.Locale
import java.util.UUID

/**
 * Append-only cost ledger — the Android port of the macOS `SpendLedger`.
 * Lives in the main Room database (own table; explicit 2→3 migration so
 * existing chats survive the schema bump). Deleting a conversation never
 * touches spend history.
 */

/** What a spend record paid for (mirrors the macOS `SpendKind`). */
enum class SpendKind(val raw: String) {
    CHAT("chat"),       // a model turn (incl. agentic tool loop)
    SUMMARY("summary"), // context-compression summarization call
    OCR("ocr"),         // Mistral OCR (per page)
    STT("stt"),         // speech-to-text (per minute)
    SEARCH("search"),   // Brave web search (per query)
    IMAGE("image");     // ImageAddon cloud operation (fal.ai)

    companion object {
        fun fromRaw(raw: String): SpendKind = entries.firstOrNull { it.raw == raw } ?: CHAT
    }
}

@Entity(tableName = "spend_records", indices = [Index("timestamp")])
data class SpendRecordEntity(
    @PrimaryKey val id: String,
    val timestamp: Long,
    /** SpendKind.raw */
    val kind: String,
    val provider: String,
    val model: String,
    val inputTokens: Int,
    val outputTokens: Int,
    val cacheReadTokens: Int,
    val cacheWriteTokens: Int,
    val reasoningTokens: Int,
    /** Non-token quantity: OCR pages, STT minutes, search queries, images. */
    val units: Double,
    /** null = tokens recorded but no price known for the model at write time. */
    val costUSD: Double?,
    /** true when the stream ended without provider usage and tokens are estimated. */
    val isEstimate: Boolean,
) {
    val usage: TokenUsage
        get() = TokenUsage(inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, reasoningTokens)
}

@Dao
interface SpendDao {
    @Insert
    suspend fun insert(record: SpendRecordEntity)

    @Query("SELECT * FROM spend_records WHERE timestamp >= :from AND timestamp < :to ORDER BY timestamp")
    suspend fun recordsBetween(from: Long, to: Long): List<SpendRecordEntity>

    @Query("SELECT MIN(timestamp) FROM spend_records")
    suspend fun earliestTimestamp(): Long?

    @Query("SELECT COALESCE(SUM(costUSD), 0) FROM spend_records WHERE timestamp >= :from AND timestamp < :to")
    suspend fun costBetween(from: Long, to: Long): Double
}

/**
 * Recording façade + live counters for the Costs screen (port of the macOS
 * `SpendStore`). Fire-and-forget [record] appends to the ledger, keeps the
 * session/month counters fresh, kicks the weekly price refresh, and returns
 * a budget-warning message when a threshold was crossed (80% / 100%, once
 * per month each — soft limit, never blocks).
 */
object SpendTracker {
    private lateinit var appContext: Context
    private lateinit var prefs: SharedPreferences
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val _sessionUSD = MutableStateFlow(0.0)
    val sessionUSD: StateFlow<Double> = _sessionUSD
    private val _monthUSD = MutableStateFlow(0.0)
    val monthUSD: StateFlow<Double> = _monthUSD
    private val _todayUSD = MutableStateFlow(0.0)
    val todayUSD: StateFlow<Double> = _todayUSD

    private val _monthlyBudgetUSD = MutableStateFlow(0.0)
    val monthlyBudgetUSD: StateFlow<Double> = _monthlyBudgetUSD

    private fun dao(): SpendDao = AppDatabase.get(appContext).spendDao()

    /** Called once from App.onCreate. */
    fun init(context: Context) {
        appContext = context.applicationContext
        prefs = appContext.getSharedPreferences("spend", Context.MODE_PRIVATE)
        _monthlyBudgetUSD.value = prefs.getFloat("monthlyBudgetUSD", 0f).toDouble()
        refreshTotals()
    }

    fun setMonthlyBudget(value: Double) {
        _monthlyBudgetUSD.value = value.coerceAtLeast(0.0)
        prefs.edit().putFloat("monthlyBudgetUSD", _monthlyBudgetUSD.value.toFloat()).apply()
    }

    /** Reloads the month/today counters from the ledger (call on screen open). */
    fun refreshTotals() {
        scope.launch {
            val (monthStart, monthEnd) = monthBounds(System.currentTimeMillis())
            _monthUSD.value = dao().costBetween(monthStart, monthEnd)
            _todayUSD.value = dao().costBetween(dayStart(System.currentTimeMillis()), monthEnd)
        }
    }

    /**
     * Appends one record. Safe from any thread; the insert is async, the
     * counter/budget bookkeeping is immediate. Returns the localized budget
     * warning to surface in the chat, or null.
     */
    fun record(
        kind: SpendKind,
        provider: String,
        model: String,
        usage: TokenUsage = TokenUsage(),
        units: Double = 0.0,
        costUSD: Double?,
        isEstimate: Boolean = false,
    ): String? {
        val entity = SpendRecordEntity(
            id = UUID.randomUUID().toString(),
            timestamp = System.currentTimeMillis(),
            kind = kind.raw,
            provider = provider,
            model = model,
            inputTokens = usage.inputTokens,
            outputTokens = usage.outputTokens,
            cacheReadTokens = usage.cacheReadTokens,
            cacheWriteTokens = usage.cacheWriteTokens,
            reasoningTokens = usage.reasoningTokens,
            units = units,
            costUSD = costUSD,
            isEstimate = isEstimate,
        )
        scope.launch { dao().insert(entity) }
        PricingCatalog.refreshIfStale()
        Diagnostics.log(
            "spend",
            "append kind=${kind.raw} provider=$provider model=$model " +
                "cost=${costUSD?.let { String.format(Locale.US, "%.6f", it) } ?: "nil"} est=$isEstimate"
        )

        val cost = costUSD ?: 0.0
        _sessionUSD.value += cost
        _todayUSD.value += cost
        val before = _monthUSD.value
        _monthUSD.value = before + cost
        return budgetWarning(before, _monthUSD.value)
    }

    /** One warning per threshold per month: 80% and 100% of the budget. */
    private fun budgetWarning(before: Double, after: Double): String? {
        val budget = _monthlyBudgetUSD.value
        if (budget <= 0) return null
        val monthKey = monthKey(System.currentTimeMillis())
        for ((fraction, suffix, res) in listOf(
            Triple(1.0, "100", R.string.costs_budget_hit),
            Triple(0.8, "80", R.string.costs_budget_near),
        )) {
            val threshold = budget * fraction
            if (after < threshold || before >= threshold) continue
            val flag = "warned$suffix.$monthKey"
            if (prefs.getBoolean(flag, false)) return null
            prefs.edit().putBoolean(flag, true).apply()
            return appContext.getString(res, usd(after), usd(budget))
        }
        return null
    }

    // MARK: Helpers

    fun usd(value: Double): String =
        if (value < 0.01 && value > 0) String.format(Locale.US, "$%.4f", value)
        else String.format(Locale.US, "$%.2f", value)

    fun monthBounds(at: Long): Pair<Long, Long> {
        val cal = Calendar.getInstance().apply {
            timeInMillis = at
            set(Calendar.DAY_OF_MONTH, 1)
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }
        val start = cal.timeInMillis
        cal.add(Calendar.MONTH, 1)
        return start to cal.timeInMillis
    }

    private fun dayStart(at: Long): Long = Calendar.getInstance().apply {
        timeInMillis = at
        set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
        set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
    }.timeInMillis

    private fun monthKey(at: Long): String {
        val cal = Calendar.getInstance().apply { timeInMillis = at }
        return "${cal.get(Calendar.YEAR)}-${cal.get(Calendar.MONTH) + 1}"
    }
}
