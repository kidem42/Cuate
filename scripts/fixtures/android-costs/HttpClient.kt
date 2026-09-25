package com.aispotlight.android.core
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import kotlinx.coroutines.flow.flow
object HttpClient {
    val bodies = mutableListOf<JSONObject>()
    val frames = ArrayDeque<List<String>>()
    var fail: Exception? = null
    var beforeRequest: (() -> Unit)? = null
    var beforeFrames: (suspend () -> Unit)? = null
    fun jsonBody(json: JSONObject) = json.toString().toRequestBody()
    suspend fun json(request: Request): String = error("Unexpected catalog call")
    fun sseStream(request: Request) = flow {
        val buffer = okio.Buffer(); request.body!!.writeTo(buffer)
        bodies.add(JSONObject(buffer.readUtf8()))
        beforeRequest?.invoke()
        beforeFrames?.invoke()
        for (frame in frames.removeFirst()) emit(frame)
        fail?.let { throw it }
    }
}
object Diagnostics { fun log(category: String, event: String) {} }
