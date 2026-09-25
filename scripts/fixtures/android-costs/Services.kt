package com.aispotlight.android.providers
import com.aispotlight.android.core.*
import java.io.File
import org.json.JSONObject
object PricingCatalog {
 var price: ModelPricing? = ModelPricing(0.001, 0.002, 0.0001, 0.00125)
 fun pricing(provider: ProviderID, model: String) = price
 fun refreshIfStale() {}
}
object BraveSearchService {
 val isAvailable = true
 val toolSpec = ToolSpec("web_search", "search", JSONObject())
 var calls = 0
 suspend fun search(query: String): String { calls++; return "grounding" }
}
object WebFetchService {
 val toolSpec = ToolSpec("web_fetch", "fetch", JSONObject())
 suspend fun fetch(url: String) = "page"
}
object MistralOCRService {
 val isAvailable = false
 suspend fun extractText(base64: String, mimeType: String) = "ocr"
}
object OpenAIFilesService {
 data class Uploaded(val id: String, val expiresAtMillis: Long?)
 suspend fun upload(file: File, filename: String, mime: String, expiry: Long, key: String) = Uploaded("file", null)
}
