package com.aispotlight.android.ui

import android.content.ActivityNotFoundException
import android.content.Context
import android.net.Uri
import androidx.annotation.ColorInt
import androidx.browser.customtabs.CustomTabColorSchemeParams
import androidx.browser.customtabs.CustomTabsIntent
import androidx.compose.ui.platform.UriHandler

/**
 * Opens http(s) links in a Chrome Custom Tab instead of bouncing the user
 * out to a separate browser app. The tab is themed to match the active chat
 * palette: toolbar and navigation bar take the theme background, and the
 * tab follows the app's appearance setting (not the system one) for its
 * light/dark scheme.
 *
 * Provided app-wide as [androidx.compose.ui.platform.LocalUriHandler] from
 * `CuateTheme`, so every `LinkAnnotation.Url` in markdown goes through
 * here without per-call-site wiring. Non-web schemes (mailto:, tel:, …) and
 * devices without any browser fall back to the platform handler.
 */
class CustomTabsUriHandler(
    private val context: Context,
    @ColorInt private val toolbarColor: Int,
    private val dark: Boolean,
    private val fallback: UriHandler,
) : UriHandler {

    override fun openUri(uri: String) {
        val parsed = Uri.parse(uri)
        if (parsed.scheme != "http" && parsed.scheme != "https") {
            fallback.openUri(uri)
            return
        }
        val colors = CustomTabColorSchemeParams.Builder()
            .setToolbarColor(toolbarColor)
            .setNavigationBarColor(toolbarColor)
            .build()
        val intent = CustomTabsIntent.Builder()
            .setColorScheme(
                if (dark) CustomTabsIntent.COLOR_SCHEME_DARK
                else CustomTabsIntent.COLOR_SCHEME_LIGHT
            )
            .setDefaultColorSchemeParams(colors)
            .setShowTitle(true)
            .build()
        try {
            intent.launchUrl(context, parsed)
        } catch (_: ActivityNotFoundException) {
            fallback.openUri(uri)
        }
    }
}
