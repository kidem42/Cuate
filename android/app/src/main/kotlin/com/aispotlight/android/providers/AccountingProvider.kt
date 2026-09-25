package com.aispotlight.android.providers

import com.aispotlight.android.core.*
import com.aispotlight.android.data.SpendTracker
import com.aispotlight.android.settings.AppSettings
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.withContext

/** One immutable receipt per HTTP attempt, including retries and cancellations. */
class AccountingProvider(private val base: LLMProvider) : LLMProvider by base {
    override fun streamChat(messages: List<LLMMessage>, model: String, systemPrompt: String?,
                            options: ChatRequestOptions, apiKey: String) = flow {
        var usage: TokenUsage? = null
        var finalUsage = false
        var outcome: Boolean? = null
        var completion = "failed"
        var pricing = PricingCatalog.pricing(providerID, model)
        if (providerID == ProviderID.OPENROUTER) {
            val info = AppSettings.current.openRouterCatalog.value[model]
            val input = info?.promptPricePerToken
            val output = info?.completionPricePerToken
            if (input != null && output != null) pricing = ModelPricing(input, output, input, input)
        }
        val tracked = options.copy(
            reportUsage = { value, final ->
                usage = value
                finalUsage = final
                options.reportUsage?.invoke(value, final)
            },
            reportOutcome = { value -> outcome = value; options.reportOutcome?.invoke(value) },
        )
        try {
            base.streamChat(messages, model, systemPrompt, tracked, apiKey).collect { emit(it) }
            completion = if (outcome == true) "completed" else "incomplete"
        } catch (cancelled: CancellationException) {
            completion = "cancelled"
            throw cancelled
        } catch (error: Exception) {
            completion = if (outcome == false) "incomplete" else "failed"
            throw error
        } finally {
            val exact = usage?.exactCostUSD?.takeIf { it.isFinite() && it >= 0 }
            val cost = exact ?: if (providerID == ProviderID.OPENROUTER && options.serverTools.isNotEmpty()) null
                else usage?.let { pricing?.cost(it) }
            withContext(NonCancellable) {
                SpendTracker.recordAwait(
                    kind = options.spendKind, provider = providerID.id, model = model,
                    usage = usage ?: TokenUsage(), costUSD = cost,
                    operationID = options.operationID,
                    usageState = if (usage == null) "missing" else if (finalUsage) "complete" else "partial",
                    costBasis = if (exact != null) "provider" else if (cost != null) "catalog" else "unknown",
                    completionState = completion,
                )?.let { options.reportBudgetWarning?.invoke(it) }
            }
        }
    }
}
