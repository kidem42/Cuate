package com.aispotlight.android.providers

import android.text.Html
import com.aispotlight.android.core.HttpClient
import com.aispotlight.android.core.ProviderException
import com.aispotlight.android.core.ToolSpec
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Request
import okhttp3.Response
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * `web_fetch` — the companion tool to `web_search`: the model asks for a URL,
 * we download the page and hand back its readable text. Runs client-side
 * (free, no key, works with every provider). Port of the macOS
 * WebFetchService — keep the specs and limits in sync.
 */
object WebFetchService {
    /** The tool definition advertised to the model. */
    val toolSpec = ToolSpec(
        name = "web_fetch",
        description = "Fetch a web page by URL and return its readable text. Use it to read a promising web_search result in full, or when the user provides a URL. Works for HTML and plain-text pages; not for downloading binary files.",
        parameters = JSONObject()
            .put("type", "object")
            .put("properties", JSONObject().put("url", JSONObject()
                .put("type", "string")
                .put("description", "Full http(s) URL of the page to read.")))
            .put("required", JSONArray().put("url"))
    )

    /**
     * Text budget returned to the model — a full article fits, giant pages get
     * truncated with an explicit note so the model knows it saw a part.
     */
    private const val MAX_CHARS = 24_000

    /** Download cap: pages above this are not real articles. */
    private const val MAX_BYTES = 5L * 1024 * 1024

    suspend fun fetch(urlString: String): String {
        // HttpUrl only parses http(s) — ftp/file/data schemes fail here.
        val url = urlString.toHttpUrlOrNull()
            ?: throw ProviderException.http(0, "web_fetch: invalid or non-http(s) URL")
        // SSRF-гигиена: модель не должна уметь читать локальную сеть.
        if (isPrivateHost(url.host.lowercase())) {
            throw ProviderException.http(0, "web_fetch: local and private addresses are not allowed")
        }

        val request = Request.Builder()
            .url(url)
            // Default okhttp UA gets bot-blocked on many sites — look like a browser.
            .header(
                "User-Agent",
                "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36"
            )
            .header("Accept", "text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.8")
            .build()

        val (mime, body) = perform(request)
        val text = when {
            mime.contains("html") || mime.isEmpty() -> extractReadableText(body)
            mime.startsWith("text/") || mime.contains("json") || mime.contains("xml") -> body
            else -> throw ProviderException.http(0, "web_fetch: unsupported content type $mime")
        }

        val cleaned = text
            .replace(Regex("\n{3,}"), "\n\n")
            .trim()
        if (cleaned.isEmpty()) {
            throw ProviderException.http(0, "web_fetch: the page produced no readable text (may require JavaScript)")
        }

        return buildString {
            append("Content of $url:\n\n")
            if (cleaned.length > MAX_CHARS) {
                append(cleaned.take(MAX_CHARS))
                append("\n\n[Truncated: page continues beyond $MAX_CHARS characters]")
            } else {
                append(cleaned)
            }
        }
    }

    /** Raw GET with status/size checks; returns (mime, decoded body). */
    private suspend fun perform(request: Request): Pair<String, String> =
        suspendCancellableCoroutine { cont ->
            val call = HttpClient.client.newCall(request)
            cont.invokeOnCancellation { call.cancel() }
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) {
                    if (cont.isActive) cont.resumeWithException(e)
                }

                override fun onResponse(call: Call, response: Response) {
                    response.use {
                        if (!it.isSuccessful) {
                            if (cont.isActive) cont.resumeWithException(
                                ProviderException.http(it.code, "web_fetch: page returned HTTP ${it.code}")
                            )
                            return
                        }
                        val bytes = it.body?.bytes() ?: ByteArray(0)
                        if (bytes.size > MAX_BYTES) {
                            if (cont.isActive) cont.resumeWithException(
                                ProviderException.http(0, "web_fetch: page is too large (${bytes.size / 1024} KB)")
                            )
                            return
                        }
                        val mime = (it.header("Content-Type") ?: "").substringBefore(";").trim().lowercase()
                        // Respect the declared charset; fall back to UTF-8.
                        val charset = it.body?.contentType()?.charset() ?: Charsets.UTF_8
                        if (cont.isActive) cont.resume(mime to String(bytes, charset))
                    }
                }
            })
        }

    // MARK: - HTML → text

    /**
     * Html.fromHtml handles tags/entities; <script>/<style> первыми — им в
     * тексте не место. На пустой результат — грубый срез тегов.
     */
    private fun extractReadableText(html: String): String {
        val stripped = html.replace(
            Regex("<(script|style|noscript|svg|iframe)\\b.*?</\\1>", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL)),
            " "
        )
        val parsed = runCatching {
            @Suppress("DEPRECATION")
            Html.fromHtml(stripped, Html.FROM_HTML_MODE_LEGACY).toString()
        }.getOrNull()
        if (!parsed.isNullOrBlank()) return parsed
        // Fallback: block tags → newlines, остальные теги — прочь.
        return stripped
            .replace(Regex("<(br|/p|/div|/h[1-6]|/li|/tr)[^>]*>", RegexOption.IGNORE_CASE), "\n")
            .replace(Regex("<[^>]+>"), " ")
    }

    /**
     * localhost, RFC1918, link-local, .local/.internal и хосты без точки
     * (интранет-имена) — всё мимо.
     */
    private fun isPrivateHost(host: String): Boolean {
        if (host == "localhost" || host == "::1" || host.endsWith(".local") || host.endsWith(".internal")) return true
        if (!host.contains(".")) return true
        if (host.startsWith("127.") || host.startsWith("10.") || host.startsWith("192.168.")
            || host.startsWith("169.254.") || host.startsWith("0.")
        ) return true
        // 172.16.0.0/12
        if (host.startsWith("172.")) {
            val octet = host.removePrefix("172.").substringBefore(".")
            octet.toIntOrNull()?.let { if (it in 16..31) return true }
        }
        // IPv6 unique-local / link-local literals.
        if (host.startsWith("fd") || host.startsWith("fe80")) return true
        return false
    }
}
