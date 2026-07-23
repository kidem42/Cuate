package com.aispotlight.android.data

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import java.io.ByteArrayOutputStream

/**
 * Alpha handling for image operations — порт маковского «фикса воскресшего
 * фона» (ImageInputPreparer, Alpha handling).
 *
 * Модели удаления фона (Bria RMBG, BiRefNet) возвращают PNG, где в RGB лежит
 * НЕТРОНУТЫЙ оригинал, а вырезание живёт только в альфа-канале. Просмотрщики
 * альфу уважают — картинка выглядит вырезанной; fal-модели (апскейл, eraser)
 * альфу игнорируют и обрабатывают RGB — «удалённый» фон воскресал в
 * результате. Плюс утечка: из сохранённого файла фон достаётся редактором.
 */
object ImageAlpha {

    private fun decode(bytes: ByteArray): Bitmap? =
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size)

    private fun pngBytes(bitmap: Bitmap): ByteArray {
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
        return out.toByteArray()
    }

    /**
     * Flattens a transparent image onto WHITE (то, что видит пользователь в
     * чате) and extracts the alpha mask. Returns null for images without
     * actual transparency — the caller keeps the original bytes.
     */
    fun flattenIfTransparent(bytes: ByteArray): Pair<ByteArray, Bitmap>? {
        val bitmap = decode(bytes) ?: return null
        if (!bitmap.hasAlpha()) return null
        val pixels = IntArray(bitmap.width * bitmap.height)
        bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
        if (pixels.none { (it ushr 24) < 255 }) return null

        // Маска — ARGB_8888 с альфой в альфа-байте (extractAlpha даёт ALPHA_8,
        // но getPixels на ALPHA_8 на части версий Android возвращает нули).
        val maskPixels = IntArray(pixels.size) { pixels[it] and -0x1000000 }
        val mask = Bitmap.createBitmap(bitmap.width, bitmap.height, Bitmap.Config.ARGB_8888)
        mask.setPixels(maskPixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)

        val flat = Bitmap.createBitmap(bitmap.width, bitmap.height, Bitmap.Config.ARGB_8888)
        Canvas(flat).apply {
            drawColor(Color.WHITE)
            drawBitmap(bitmap, 0f, 0f, null)
        }
        return pngBytes(flat) to mask
    }

    /**
     * Re-encodes an image so pixels under transparency hold no leftover RGB.
     * Декод в premultiplied-битмап сам умножает RGB на альфу (α=0 → чёрный),
     * PNG-энкодер пишет уже чистые значения. Returns null when the image has
     * no transparency — nothing to sanitize.
     */
    fun sanitizedTransparency(bytes: ByteArray): ByteArray? {
        val bitmap = decode(bytes) ?: return null
        if (!bitmap.hasAlpha()) return null
        val pixels = IntArray(bitmap.width * bitmap.height)
        bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
        if (pixels.none { (it ushr 24) < 255 }) return null
        return pngBytes(bitmap)
    }

    /**
     * Scales the remembered alpha mask to the result's size and writes it into
     * the alpha channel — апскейл возвращает непрозрачный RGB, так что
     * прозрачность вырезки восстанавливается локально (бесплатно).
     */
    fun applyAlphaMask(mask: Bitmap, resultBytes: ByteArray): ByteArray? {
        val result = decode(resultBytes) ?: return null
        val w = result.width
        val h = result.height
        val scaledMask = Bitmap.createScaledBitmap(mask, w, h, true)

        val rgb = IntArray(w * h)
        result.getPixels(rgb, 0, w, 0, 0, w, h)
        val alpha = IntArray(w * h)
        scaledMask.getPixels(alpha, 0, w, 0, 0, w, h)

        for (i in rgb.indices) {
            rgb[i] = (alpha[i] and -0x1000000) or (rgb[i] and 0xFFFFFF)
        }
        val combined = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        combined.setPixels(rgb, 0, w, 0, 0, w, h)
        return pngBytes(combined)
    }
}
