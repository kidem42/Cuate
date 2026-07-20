package com.aispotlight.android.ui

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Handler
import android.os.Looper
import android.util.LruCache
import android.view.View
import android.webkit.JavascriptInterface
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import com.aispotlight.android.core.Diagnostics
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import kotlin.coroutines.resume
import kotlin.math.ceil
import kotlin.math.min

/**
 * Diagram theme handed to mermaid's `base` theme so diagrams match the app:
 * the chat theme's accent for node fills/borders, neutral high-contrast
 * grays for text/lines, solid light/dark card background. Port of
 * `MermaidTheme` (MermaidRenderer.swift); the categorical palette is the
 * same validated set (CVD ΔE + contrast against these surfaces) — the ORDER
 * is the colorblind-safety mechanism, do not reshuffle.
 */
data class MermaidTheme(
    val variables: Map<String, String>,
    val backgroundHex: String,
    val key: String,
) {
    val backgroundColor: Color
        get() = Color(android.graphics.Color.parseColor(backgroundHex))

    companion object {
        private val categoricalLight = listOf(
            "#2A78D6", "#008300", "#E87BA4", "#EDA100",
            "#1BAF7A", "#EB6834", "#4A3AA7", "#E34948",
        )
        private val categoricalDark = listOf(
            "#3987E5", "#008300", "#D55181", "#C98500",
            "#199E70", "#D95926", "#9085E9", "#E66767",
        )

        fun make(accent: Color, dark: Boolean): MermaidTheme {
            val accentHex = accent.toHex()
            val bg = if (dark) "#26262B" else "#FFFFFF"
            val text = if (dark) "#F0F0F3" else "#1D1D1F"
            val line = if (dark) "#94949C" else "#6E6E73"
            val variables = mutableMapOf(
                "background" to bg,
                "primaryColor" to blendHex(accentHex, bg, 0.16),
                "primaryBorderColor" to blendHex(accentHex, bg, 0.60),
                "primaryTextColor" to text,
                "secondaryColor" to blendHex(accentHex, bg, 0.09),
                "tertiaryColor" to blendHex(text, bg, 0.05),
                "lineColor" to line,
                "textColor" to text,
                "titleColor" to text,
                "edgeLabelBackground" to bg,
                "clusterBkg" to blendHex(text, bg, 0.035),
                "clusterBorder" to blendHex(text, bg, 0.22),
                "noteBkgColor" to blendHex(accentHex, bg, 0.10),
                "noteTextColor" to text,
                "errorBkgColor" to bg,
                "errorTextColor" to text,
                "fontSize" to "14px",
                // Pie chrome: full-strength fills, background-colored strokes
                // as the 2px surface gap between slices, no heavy outer ring.
                "pieOpacity" to "1",
                "pieStrokeColor" to bg,
                "pieStrokeWidth" to "2px",
                "pieOuterStrokeWidth" to "2px",
                "pieOuterStrokeColor" to bg,
                "pieTitleTextColor" to text,
                "pieSectionTextColor" to if (dark) "#FFFFFF" else "#1D1D1F",
                "pieLegendTextColor" to text,
            )
            val series = if (dark) categoricalDark else categoricalLight
            series.forEachIndexed { index, color ->
                variables["pie${index + 1}"] = color
                variables["cScale$index"] = color
            }
            return MermaidTheme(
                variables = variables,
                backgroundHex = bg,
                key = "$accentHex|${if (dark) "d" else "l"}",
            )
        }

        private fun Color.toHex(): String {
            val argb = toArgb()
            return String.format("#%06X", argb and 0xFFFFFF)
        }

        /** `top` over `base` at `alpha`, both "#RRGGBB" → "#RRGGBB". */
        private fun blendHex(top: String, base: String, alpha: Double): String {
            val t = android.graphics.Color.parseColor(top)
            val b = android.graphics.Color.parseColor(base)
            fun mix(tc: Int, bc: Int) = (tc * alpha + bc * (1 - alpha)).toInt().coerceIn(0, 255)
            return String.format(
                "#%02X%02X%02X",
                mix(android.graphics.Color.red(t), android.graphics.Color.red(b)),
                mix(android.graphics.Color.green(t), android.graphics.Color.green(b)),
                mix(android.graphics.Color.blue(t), android.graphics.Color.blue(b)),
            )
        }
    }
}

/**
 * Offscreen mermaid engine: one hidden WebView loaded once with the bundled
 * assets/mermaid.min.js (no network). A diagram is validated (`mermaid.parse`),
 * rendered to SVG, measured, laid out at device density and drawn into a
 * Bitmap — so the inline image is exactly as crisp as the screen. Renders are
 * serialized (single DOM) and cached; syntax errors come back typed so the UI
 * falls back to the source code block instead of mermaid's error bomb.
 * Port of MermaidRenderer.swift.
 */
object MermaidRenderer {

    sealed class RenderResult {
        data class Success(
            val bitmap: Bitmap,
            val svg: String,
            /** Logical (CSS-px) size — Compose displays the bitmap at this dp size. */
            val widthDp: Float,
            val heightDp: Float,
        ) : RenderResult()

        data class Failure(val message: String) : RenderResult()
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var webView: WebView? = null
    private var engineReady = false
    private var engineFailed = false
    private val mutex = Mutex()
    private var mermaidJs: String? = null

    /** Bitmaps dominate the footprint — bound the cache by pixel bytes (~24 MB). */
    private val cache = object : LruCache<String, RenderResult>(24 * 1024 * 1024) {
        override fun sizeOf(key: String, value: RenderResult): Int =
            if (value is RenderResult.Success) value.bitmap.byteCount else 1024
    }

    private const val MAX_BITMAP_PX = 4200

    private class Bridge {
        var continuation: CancellableContinuation<String>? = null

        @JavascriptInterface
        fun onResult(json: String) {
            val cont = continuation
            continuation = null
            cont?.let { c -> Handler(Looper.getMainLooper()).post { if (c.isActive) c.resume(json) } }
        }
    }

    private val bridge = Bridge()

    suspend fun render(context: Context, code: String, theme: MermaidTheme): RenderResult {
        val key = "${theme.key}|$code"
        cache.get(key)?.let { return it }
        // Serialize: the engine has a single DOM shared by all renders.
        return mutex.withLock {
            cache.get(key)?.let { return@withLock it }
            val result = withTimeoutOrNull(12_000) { performRender(context, code, theme) }
                ?: RenderResult.Failure("render timed out")
            cache.put(key, result)
            result
        }
    }

    // MARK: Engine

    fun mermaidJs(context: Context): String =
        mermaidJs ?: runCatching {
            context.assets.open("mermaid.min.js").bufferedReader().readText()
        }.getOrElse {
            Diagnostics.log("mermaid", "asset.missing mermaid.min.js")
            ""
        }.also { mermaidJs = it }

    @SuppressLint("SetJavaScriptEnabled")
    private suspend fun ensureEngine(context: Context): WebView? {
        webView?.let { if (engineReady) return it }
        if (engineFailed) return null
        val js = mermaidJs(context.applicationContext)
        if (js.isEmpty()) {
            engineFailed = true
            return null
        }
        val view = webView ?: WebView(context.applicationContext).also { webView = it }
        if (!engineReady) {
            val loaded = suspendCancellableCoroutine { cont ->
                view.settings.javaScriptEnabled = true
                view.addJavascriptInterface(bridge, "Bridge")
                view.webViewClient = object : WebViewClient() {
                    override fun onPageFinished(v: WebView?, url: String?) {
                        if (cont.isActive) cont.resume(true)
                    }
                }
                view.loadDataWithBaseURL(null, engineHtml(js), "text/html", "utf-8", null)
            }
            // Confirm the library actually initialized before declaring ready.
            val type = suspendCancellableCoroutine { cont ->
                view.evaluateJavascript("typeof mermaid") { value ->
                    if (cont.isActive) cont.resume(value ?: "")
                }
            }
            engineReady = loaded && (type.contains("object") || type.contains("function"))
            if (!engineReady) {
                engineFailed = true
                Diagnostics.log("mermaid", "engine.boot failed: mermaid global missing")
                return null
            }
        }
        return view
    }

    private suspend fun performRender(context: Context, code: String, theme: MermaidTheme): RenderResult {
        val view = ensureEngine(context) ?: return RenderResult.Failure("mermaid engine unavailable")
        val vars = JSONObject(theme.variables as Map<*, *>).toString()
        val codeJson = JSONObject.quote(code)
        val raw = suspendCancellableCoroutine { cont ->
            bridge.continuation = cont
            view.evaluateJavascript(
                "window.renderDiagram($codeJson, $vars).then(function(r){Bridge.onResult(r);});",
                null,
            )
        }
        val reply = runCatching { JSONObject(raw) }.getOrNull()
            ?: return RenderResult.Failure("malformed engine reply")
        if (!reply.optBoolean("ok")) {
            val detail = reply.optString("error", "empty diagram")
            Diagnostics.log("mermaid", "render.syntax ${detail.take(200)}")
            return RenderResult.Failure(detail)
        }
        val svg = reply.optString("svg")
        val width = reply.optDouble("w", 0.0).toFloat()
        val height = reply.optDouble("h", 0.0).toFloat()
        if (svg.isEmpty() || width <= 0 || height <= 0) return RenderResult.Failure("empty diagram")

        // WebView lays CSS px out at device density; capping the bitmap side
        // keeps huge diagrams from allocating runaway surfaces.
        val density = context.resources.displayMetrics.density
        val scale = min(density, MAX_BITMAP_PX / maxOf(width, height))
        val widthPx = ceil(width * scale).toInt()
        val heightPx = ceil(height * scale).toInt()
        view.measure(
            View.MeasureSpec.makeMeasureSpec(widthPx, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(heightPx, View.MeasureSpec.EXACTLY),
        )
        view.layout(0, 0, widthPx, heightPx)
        delay(80) // let the WebView composite the freshly injected SVG

        val bitmap = Bitmap.createBitmap(widthPx, heightPx, Bitmap.Config.ARGB_8888)
        view.draw(Canvas(bitmap))
        Diagnostics.log("mermaid", "render.ok ${width.toInt()}x${height.toInt()} @${scale}x")
        return RenderResult.Success(bitmap, svg, width, height)
    }

    // MARK: HTML

    private fun engineHtml(js: String): String = """
        <!doctype html><html><head><meta charset="utf-8">
        <style>html, body { margin: 0; padding: 0; } #c { display: inline-block; }</style>
        <script>$js</script>
        </head><body><div id="c"></div>
        <script>
        let seq = 0;
        window.renderDiagram = async function(code, vars) {
            try {
                mermaid.initialize(Object.assign(JSON.parse(window.__baseConfig), { themeVariables: vars }));
                document.body.style.background = vars.background || '#FFFFFF';
                await mermaid.parse(code);
                const { svg } = await mermaid.render('m' + (++seq), code);
                const holder = document.getElementById('c');
                holder.innerHTML = svg;
                const el = holder.querySelector('svg');
                el.style.maxWidth = 'none';
                if (el.viewBox && el.viewBox.baseVal && el.viewBox.baseVal.width > 0) {
                    el.setAttribute('width', el.viewBox.baseVal.width + 'px');
                    el.setAttribute('height', el.viewBox.baseVal.height + 'px');
                }
                const rect = el.getBoundingClientRect();
                return JSON.stringify({ ok: true, svg: svg, w: rect.width, h: rect.height });
            } catch (e) {
                return JSON.stringify({ ok: false, error: String((e && e.message) || e) });
            }
        };
        window.__baseConfig = JSON.stringify({
            startOnLoad: false,
            securityLevel: 'strict',
            theme: 'base',
            fontFamily: "system-ui, 'Roboto', sans-serif",
            flowchart: { curve: 'basis' }
        });
        </script></body></html>
    """.trimIndent()

    /**
     * Full standalone page for the viewer: live SVG rendered with the same
     * config as the inline bitmap; pinch zoom comes from WebView settings.
     */
    fun previewHtml(context: Context, code: String, theme: MermaidTheme): String {
        val js = mermaidJs(context)
        // "</" escaped so a literal "</script>" in diagram source can't break out.
        val codeJson = JSONObject.quote(code).replace("</", "<\\/")
        val vars = JSONObject(theme.variables as Map<*, *>).toString()
        val textColor = theme.variables["textColor"] ?: "#1D1D1F"
        return """
            <!doctype html><html><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
                html, body { margin: 0; padding: 0; background: ${theme.backgroundHex}; }
                body { display: flex; justify-content: center; padding: 16px; box-sizing: border-box; }
                #c svg { max-width: 100%; height: auto; }
                #err { font: 14px system-ui, sans-serif; color: #B45309; white-space: pre-wrap; }
                #err pre { font: 12px monospace; color: $textColor; }
            </style>
            <script>$js</script>
            </head><body><div id="c"></div>
            <script>
            (async function() {
                const code = $codeJson;
                try {
                    mermaid.initialize({
                        startOnLoad: false,
                        securityLevel: 'strict',
                        theme: 'base',
                        themeVariables: $vars,
                        fontFamily: "system-ui, 'Roboto', sans-serif",
                        flowchart: { curve: 'basis' }
                    });
                    await mermaid.parse(code);
                    const { svg } = await mermaid.render('preview', code);
                    document.getElementById('c').innerHTML = svg;
                } catch (e) {
                    const err = document.createElement('div');
                    err.id = 'err';
                    err.appendChild(document.createTextNode(String((e && e.message) || e) + '\n\n'));
                    const pre = document.createElement('pre');
                    pre.textContent = code;
                    err.appendChild(pre);
                    document.body.replaceChildren(err);
                }
            })();
            </script></body></html>
        """.trimIndent()
    }

    /** Frontmatter "title: X" or directive "title X" (gantt/pie) → viewer title. */
    fun extractTitle(code: String): String? {
        for (line in code.lineSequence().take(20)) {
            val trimmed = line.trim()
            when {
                trimmed.startsWith("title:") ->
                    trimmed.removePrefix("title:").trim().takeIf { it.isNotEmpty() }?.let { return it }
                trimmed.startsWith("title ") ->
                    trimmed.removePrefix("title ").trim().takeIf { it.isNotEmpty() }?.let { return it }
            }
        }
        return null
    }
}
