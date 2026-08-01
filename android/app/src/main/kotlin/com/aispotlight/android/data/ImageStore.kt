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

    /**
     * Imports an arbitrary (non-image) file verbatim for the agent courier:
     * copied into the files dir, no decoding, real mime from the resolver.
     * Bounded at 64 MB — matches the dashboard route's proxy body limit.
     */
    fun importFile(context: Context, uri: Uri): ChatAttachment? {
        return try {
            val resolver = context.contentResolver
            val mime = resolver.getType(uri) ?: "application/octet-stream"
            var name: String? = null
            resolver.query(uri, null, null, null, null)?.use { cursor ->
                val index = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                if (index >= 0 && cursor.moveToFirst()) name = cursor.getString(index)
            }
            val displayName = (name ?: uri.lastPathSegment ?: "file").substringAfterLast('/')
            val id = UUID.randomUUID().toString()
            // Keep the REAL filename in the stored name — the remote path the
            // agent sees is ~/cuate-uploads/<filename>.
            val relativePath = "$DIR/$id-$displayName"
            val target = File(context.filesDir, relativePath)
            target.parentFile?.mkdirs()
            var total = 0L
            resolver.openInputStream(uri)?.use { input ->
                target.outputStream().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        total += read
                        if (total > 64L * 1024 * 1024) {
                            target.delete()
                            return null
                        }
                        output.write(buffer, 0, read)
                    }
                }
            } ?: return null
            ChatAttachment(
                id = id,
                filename = displayName,
                mimeType = mime,
                filePath = relativePath,
            )
        } catch (_: Exception) {
            null
        }
    }

    /**
     * Imports an image from a content Uri (gallery, camera) VERBATIM — original
     * bytes, EXIF and all, mirroring macOS `ChatAttachment.fileBacked`: the
     * downscaled copy for chat models is produced separately at send time
     * (`LLMImage.forModel`), so OCR and the image tools keep full quality.
     * Returns the attachment row, or null when the Uri isn't a decodable image.
     */
    fun importImage(context: Context, uri: Uri, filename: String? = null): ChatAttachment? {
        return try {
        val resolver = context.contentResolver

        // Bounds-only pass validates the payload IS an image and sniffs the
        // real mime (the resolver's answer can be generic or missing).
        // NB: with inJustDecodeBounds the decode call itself ALWAYS returns
        // null (the dimensions land in the options object) — so only the
        // stream is null-checked here; decode success is judged by
        // outWidth/outHeight below. Chaining `?: return null` off the decode
        // result rejected every image ever attached.
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        val boundsStream = resolver.openInputStream(uri) ?: return null
        boundsStream.use { BitmapFactory.decodeStream(it, null, bounds) }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

        val mime = bounds.outMimeType ?: resolver.getType(uri) ?: "image/jpeg"
        val ext = when (mime) {
            "image/png" -> "png"
            "image/webp" -> "webp"
            "image/gif" -> "gif"
            "image/heic", "image/heif" -> "heic"
            else -> "jpg"
        }
        val id = UUID.randomUUID().toString()
        val relativePath = "$DIR/$id.$ext"
        val target = File(context.filesDir, relativePath)
        target.parentFile?.mkdirs()
        // Verbatim byte copy; bounded like importFile so a rogue Uri can't
        // fill the data dir.
        var total = 0L
        resolver.openInputStream(uri)?.use { input ->
            target.outputStream().use { output ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    total += read
                    if (total > 64L * 1024 * 1024) {
                        target.delete()
                        return null
                    }
                    output.write(buffer, 0, read)
                }
            }
        } ?: return null

        ChatAttachment(
            id = id,
            filename = filename ?: "image.$ext",
            mimeType = mime,
            filePath = relativePath,
        )
        } catch (e: Exception) {
            // Revoked grant, vanished file — log, fail soft (the caller
            // surfaces the error banner).
            com.aispotlight.android.core.Diagnostics.log("image", "import.failed ${e.message}")
            null
        }
    }

    fun file(context: Context, attachment: ChatAttachment): File =
        File(context.filesDir, attachment.filePath)

    /** Base64 of the payload (for API calls). Empty when the file is gone. */
    fun contentBase64(context: Context, attachment: ChatAttachment): String {
        val file = file(context, attachment)
        if (!file.exists()) return ""
        return Base64.encodeToString(file.readBytes(), Base64.NO_WRAP)
    }

    /**
     * Decoded bitmap for thumbnails (downsampled to roughly the target size),
     * EXIF orientation applied — stored originals keep the tag, and
     * BitmapFactory ignores it.
     */
    fun thumbnail(context: Context, attachment: ChatAttachment, targetPx: Int = 512): Bitmap? {
        val file = file(context, attachment)
        if (!file.exists()) return null
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= targetPx) sample *= 2
        val bitmap = BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = sample })
            ?: return null
        return com.aispotlight.android.core.bakeExifOrientation(bitmap, exifOrientation(file))
    }

    /**
     * Upright pixel dimensions of the stored payload (EXIF rotation applied) —
     * the mask editor needs its mask pixel-aligned with the image the eraser
     * model receives.
     */
    fun pixelSize(context: Context, attachment: ChatAttachment): Pair<Int, Int>? {
        val file = file(context, attachment)
        if (!file.exists()) return null
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        return when (exifOrientation(file)) {
            android.media.ExifInterface.ORIENTATION_ROTATE_90,
            android.media.ExifInterface.ORIENTATION_ROTATE_270,
            android.media.ExifInterface.ORIENTATION_TRANSPOSE,
            android.media.ExifInterface.ORIENTATION_TRANSVERSE,
            -> bounds.outHeight to bounds.outWidth
            else -> bounds.outWidth to bounds.outHeight
        }
    }

    private fun exifOrientation(file: File): Int = try {
        android.media.ExifInterface(file.path).getAttributeInt(
            android.media.ExifInterface.TAG_ORIENTATION,
            android.media.ExifInterface.ORIENTATION_NORMAL,
        )
    } catch (_: Exception) {
        android.media.ExifInterface.ORIENTATION_NORMAL
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
        val decoded = BitmapFactory.decodeFile(file.path) ?: return ""
        // Re-encoding drops the EXIF tag, so the rotation must move into pixels.
        val bitmap = com.aispotlight.android.core.bakeExifOrientation(decoded, exifOrientation(file))
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
