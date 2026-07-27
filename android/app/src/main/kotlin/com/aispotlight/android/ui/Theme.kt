package com.aispotlight.android.ui

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import com.aispotlight.android.settings.AppSettings

private val DarkColors = darkColorScheme(
    primary = Color(0xFF7FB4FF),
    secondary = Color(0xFF9AB8E8),
    background = Color(0xFF0E1526),
    surface = Color(0xFF141D33),
    surfaceVariant = Color(0xFF1B2A4A),
)

private val LightColors = lightColorScheme(
    primary = Color(0xFF2A5DB0),
    secondary = Color(0xFF4A6FA5),
    background = Color(0xFFF6F8FC),
    surface = Color.White,
    surfaceVariant = Color(0xFFE8EEF8),
)

@Composable
fun CuateTheme(content: @Composable () -> Unit) {
    val context = LocalContext.current
    val settings = AppSettings.shared(context)
    val appearance by settings.appearanceMode.collectAsState()
    val themeId by settings.themeId.collectAsState()

    val dark = when (appearance) {
        AppSettings.AppearanceMode.LIGHT -> false
        AppSettings.AppearanceMode.DARK -> true
        AppSettings.AppearanceMode.SYSTEM -> isSystemInDarkTheme()
    }
    val theme = ChatThemeID.fromId(themeId)
    val palette = remember(theme, dark) { ChatThemes.palette(theme, dark) }

    val colorScheme = if (palette.isDynamic) {
        when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S ->
                if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
            dark -> DarkColors
            else -> LightColors
        }
    } else {
        // Decorative palette → Material roles, so Markdown/settings inherit it.
        val background = palette.backgroundColors[1]
        val userSolid = palette.userFill.first().compositeOver(background)
        val assistantSolid = palette.assistantFill.compositeOver(background)
        val base = if (dark) darkColorScheme() else lightColorScheme()
        base.copy(
            primary = palette.accent,
            secondary = palette.accent,
            background = background,
            surface = assistantSolid,
            surfaceVariant = assistantSolid,
            onSurfaceVariant = palette.secondaryText.copy(alpha = 1f),
            primaryContainer = userSolid,
            onPrimaryContainer = palette.userText,
            onBackground = palette.primaryText,
            onSurface = palette.primaryText,
            outline = palette.inputStroke,
            // Container roles too — dropdown menus, dialogs and sheets read
            // surfaceContainer*; without these they'd fall back to the neutral
            // M3 baseline and float as gray cards over the themed UI.
            surfaceContainerLowest = background,
            surfaceContainerLow = assistantSolid,
            surfaceContainer = assistantSolid,
            surfaceContainerHigh = assistantSolid,
            surfaceContainerHighest = assistantSolid,
        )
    }

    val typography = if (palette.monospace) {
        // Terminal theme: everything monospaced (the mac theme's fontDesign).
        val mono = TextStyle(fontFamily = FontFamily.Monospace)
        Typography().run {
            copy(
                bodyLarge = bodyLarge.merge(mono), bodyMedium = bodyMedium.merge(mono),
                bodySmall = bodySmall.merge(mono), titleLarge = titleLarge.merge(mono),
                titleMedium = titleMedium.merge(mono), titleSmall = titleSmall.merge(mono),
                labelLarge = labelLarge.merge(mono), labelMedium = labelMedium.merge(mono),
                labelSmall = labelSmall.merge(mono), headlineSmall = headlineSmall.merge(mono),
            )
        }
    } else {
        Typography()
    }

    // Chat links open in a Custom Tab painted with the theme background and
    // pinned to the app's light/dark appearance. Provided here (not per call
    // site) so every LinkAnnotation.Url inherits it. The setting falls back
    // to the platform handler (external browser).
    val platformUriHandler = LocalUriHandler.current
    val openLinksInApp by settings.openLinksInApp.collectAsState()
    val toolbarColor = colorScheme.background.toArgb()
    val uriHandler = if (openLinksInApp) {
        remember(context, toolbarColor, dark, platformUriHandler) {
            CustomTabsUriHandler(context, toolbarColor, dark, platformUriHandler)
        }
    } else {
        platformUriHandler
    }

    CompositionLocalProvider(
        LocalChatPalette provides palette,
        LocalUriHandler provides uriHandler,
    ) {
        MaterialTheme(colorScheme = colorScheme, typography = typography, content = content)
    }
}
