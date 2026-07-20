package com.aispotlight.android.data

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.util.Base64
import java.io.File
import java.util.UUID

/**
 * File-backed image storage under the app's files directory — the Android
 * analog of `ChatAttachment.fileBacked` on macOS: image bytes stay OUT of the
 * database; rows hold a relative path.
 */
object ImageStore {
    private const val DIR = "images"
    /** Longest image side sent to vision APIs — bounds token cost and upload size. */
    private const val MAX_DIMENSION = 2048

    /**
     * Reads an image from a content Uri (gallery, camera), downscales it to at
     * most 2048px on the long side, re-encodes as JPEG and persists it as a
     * file. Returns the attachment row, or null when the Uri can't be decoded.
     */
    fun importImage(context: Context, uri: Uri, filename: String? = null): ChatAttachment? {
        return try {
        val resolver = context.contentResolver

        // Bounds-only pass to pick a power-of-two downsample factor.
        // NB: with inJustDecodeBounds the decode call itself ALWAYS returns
        // null (the dimensions land in the options object) — so only the
        // stream is null-checked here; decode success is judged by
        // outWidth/outHeight below. Chaining `?: return null` off the decode
        // result rejected every image ever attached.
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        val boundsStream = resolver.openInputStream(uri) ?: return null
        boundsStream.use { BitmapFactory.decodeStream(it, null, bounds) }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= MAX_DIMENSION) sample *= 2

        val options = BitmapFactory.Options().apply { inSampleSize = sample }
        val bitmap = resolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it, null, options)
        } ?: return null

        val scaled = scaleDown(bitmap)
        val id = UUID.randomUUID().toString()
        val relativePath = "$DIR/$id.jpg"
        val file = File(context.filesDir, relativePath)
        file.parentFile?.mkdirs()
        file.outputStream().use { out ->
            scaled.compress(Bitmap.CompressFormat.JPEG, 85, out)
        }
        if (scaled !== bitmap) bitmap.recycle()

        ChatAttachment(
            id = id,
            filename = filename ?: "image.jpg",
            mimeType = "image/jpeg",
            filePath = relativePath,
        )
        } catch (e: Exception) {
            // Revoked grant, vanished file, OOM on a huge image — log, fail
            // soft (the caller surfaces the error banner).
            com.aispotlight.android.core.Diagnostics.log("image", "import.failed ${e.message}")
            null
        }
    }

    private fun scaleDown(bitmap: Bitmap): Bitmap {
        val longest = maxOf(bitmap.width, bitmap.height)
        if (longest <= MAX_DIMENSION) return bitmap
        val scale = MAX_DIMENSION.toFloat() / longest
        return Bitmap.createScaledBitmap(
            bitmap,
            (bitmap.width * scale).toInt().coerceAtLeast(1),
            (bitmap.height * scale).toInt().coerceAtLeast(1),
            true,
        )
    }

    fun file(context: Context, attachment: ChatAttachment): File =
        File(context.filesDir, attachment.filePath)

    /** Base64 of the payload (for API calls). Empty when the file is gone. */
    fun contentBase64(context: Context, attachment: ChatAttachment): String {
        val file = file(context, attachment)
        if (!file.exists()) return ""
        return Base64.encodeToString(file.readBytes(), Base64.NO_WRAP)
    }

    /** Decoded bitmap for thumbnails (downsampled to roughly the target size). */
    fun thumbnail(context: Context, attachment: ChatAttachment, targetPx: Int = 512): Bitmap? {
        val file = file(context, attachment)
        if (!file.exists()) return null
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= targetPx) sample *= 2
        return BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = sample })
    }

    fun delete(context: Context, filePath: String) {
        File(context.filesDir, filePath).delete()
    }

    /** Persists raw image bytes (an image-tool result) as a file-backed attachment. */
    fun importBytes(context: Context, bytes: ByteArray, mimeType: String, filename: String): ChatAttachment {
        val id = UUID.randomUUID().toString()
        val ext = when (mimeType) {
            "image/png" -> "png"
            "image/webp" -> "webp"
            else -> "jpg"
        }
        val relativePath = "$DIR/$id.$ext"
        val file = File(context.filesDir, relativePath)
        file.parentFile?.mkdirs()
        file.writeBytes(bytes)
        return ChatAttachment(id = id, filename = filename, mimeType = mimeType, filePath = relativePath)
    }

    /** Base64 of the payload re-encoded as PNG (Recraft upscale requires PNG input). */
    fun pngBase64(context: Context, attachment: ChatAttachment): String {
        if (attachment.mimeType == "image/png") return contentBase64(context, attachment)
        val file = file(context, attachment)
        if (!file.exists()) return ""
        val bitmap = BitmapFactory.decodeFile(file.path) ?: return ""
        val out = java.io.ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
        return Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
    }

    /** Exports an attachment into the system gallery (Pictures) via MediaStore. */
    fun exportToGallery(context: Context, attachment: ChatAttachment): Boolean {
        val file = file(context, attachment)
        if (!file.exists()) return false
        return try {
            val values = android.content.ContentValues().apply {
                put(android.provider.MediaStore.Images.Media.DISPLAY_NAME, attachment.filename)
                put(android.provider.MediaStore.Images.Media.MIME_TYPE, attachment.mimeType)
                put(android.provider.MediaStore.Images.Media.RELATIVE_PATH, android.os.Environment.DIRECTORY_PICTURES)
            }
            val uri = context.contentResolver.insert(
                android.provider.MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values
            ) ?: return false
            context.contentResolver.openOutputStream(uri)?.use { it.write(file.readBytes()) }
            true
        } catch (_: Exception) {
            false
        }
    }
}
