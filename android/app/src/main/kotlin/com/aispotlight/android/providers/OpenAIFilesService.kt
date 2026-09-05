package com.aispotlight.android.providers

import com.aispotlight.android.core.Diagnostics
import com.aispotlight.android.core.ProviderException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.asRequestBody
import org.json.JSONObject
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * OpenAI Files API (`/v1/files`) for document attachments: upload once with
 * `purpose=user_data`, reference by `file_id` in Responses requests, delete
 * when the chat lets the attachment go. Port of the Mac service.
 */
object OpenAIFilesService {
    data class Uploaded(val id: String, val expiresAtMillis: Long?)

    private const val FILES_URL = "https://api.openai.com/v1/files"

    /** Own client: a 50 MB upload on a mobile uplink outlives the shared timeouts. */
    private val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(600, TimeUnit.SECONDS)
        .writeTimeout(600, TimeUnit.SECONDS)
        .callTimeout(1200, TimeUnit.SECONDS)
        .build()

    /**
     * Uploads a document. [expiresInSeconds] asks the server to delete the
     * file itself; when the API rejects the value the upload is retried
     * without it and the app-side deletion remains the only guard.
     */
    suspend fun upload(
        file: File,
        filename: String,
        mimeType: String,
        expiresInSeconds: Long?,
        apiKey: String,
    ): Uploaded = try {
        send(file, filename, mimeType, expiresInSeconds, apiKey)
    } catch (e: ProviderException) {
        val message = e.message ?: ""
        if (expiresInSeconds != null && message.contains("HTTP 400") && message.lowercase().contains("expires")) {
            Diagnostics.log("files", "upload expires_after rejected (${message.take(120)}) — retrying without expiry")
            send(file, filename, mimeType, null, apiKey)
        } else {
            throw e
        }
    }

    /** Deletes a file; a 404 counts as done. */
    suspend fun delete(fileId: String, apiKey: String) = withContext(Dispatchers.IO) {
        val request = Request.Builder()
            .url("$FILES_URL/$fileId")
            .header("Authorization", "Bearer $apiKey")
            .delete()
            .build()
        client.newCall(request).execute().use { response ->
            if (response.code == 404) return@use
            if (!response.isSuccessful) {
                throw ProviderException.http(response.code, errorMessage(response.body?.string()))
            }
        }
    }

    private suspend fun send(
        file: File,
        filename: String,
        mimeType: String,
        expiresInSeconds: Long?,
        apiKey: String,
    ): Uploaded = withContext(Dispatchers.IO) {
        val safeName = filename.replace("\"", "'").replace("\r", " ").replace("\n", " ")
        val body = MultipartBody.Builder()
            .setType(MultipartBody.FORM)
            .addFormDataPart("purpose", "user_data")
            .apply {
                if (expiresInSeconds != null) {
                    addFormDataPart("expires_after[anchor]", "created_at")
                    addFormDataPart("expires_after[seconds]", expiresInSeconds.toString())
                }
            }
            .addFormDataPart("file", safeName, file.asRequestBody(mimeType.toMediaType()))
            .build()
        val request = Request.Builder()
            .url(FILES_URL)
            .header("Authorization", "Bearer $apiKey")
            .post(body)
            .build()
        client.newCall(request).execute().use { response ->
            val text = response.body?.string() ?: ""
            if (!response.isSuccessful) throw ProviderException.http(response.code, errorMessage(text))
            val json = try { JSONObject(text) } catch (_: Exception) { throw ProviderException.decoding("file upload response") }
            val id = json.optString("id")
            if (id.isEmpty()) throw ProviderException.decoding("no `id` in file upload response")
            val expires = json.optLong("expires_at", 0L)
            Uploaded(id, if (expires > 0) expires * 1000 else null)
        }
    }

    private fun errorMessage(body: String?): String {
        if (body.isNullOrEmpty()) return "Request failed."
        return try {
            JSONObject(body).optJSONObject("error")?.optString("message")?.takeIf { it.isNotEmpty() } ?: body.take(300)
        } catch (_: Exception) {
            body.take(300)
        }
    }
}
