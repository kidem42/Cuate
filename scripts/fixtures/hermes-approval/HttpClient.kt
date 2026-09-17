package com.aispotlight.android.core

import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.json.JSONObject

data class TokenUsage(val inputTokens: Int = 0, val outputTokens: Int = 0,
    val cacheReadTokens: Int = 0, val cacheWriteTokens: Int = 0, val reasoningTokens: Int = 0)

/** An application interceptor stops every request before DNS/socket access. */
object HttpClient {
    var status = 200
    var payload = "{}"
    var fail = false
    var calls = 0
    var lastBody = JSONObject()
    var oneShot = false
    val client = OkHttpClient.Builder().addInterceptor { chain ->
        calls++
        chain.request().body?.let {
            oneShot = it.isOneShot()
            val buffer = okio.Buffer()
            it.writeTo(buffer)
            lastBody = JSONObject(buffer.readUtf8())
        }
        if (fail) throw java.io.IOException("connection lost")
        Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1)
            .message("fixture").code(status).body(payload.toResponseBody()).build()
    }.build()
    suspend fun json(request: okhttp3.Request): String = error("Unexpected generic client path")
    suspend fun bytes(request: okhttp3.Request): ByteArray = error("Unexpected binary client path")
}
