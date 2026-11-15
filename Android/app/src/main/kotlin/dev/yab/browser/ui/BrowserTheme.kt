package dev.yab.browser.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.sp
import androidx.compose.material3.Typography
import dev.yab.browser.model.BrowserAppearance

object BrowserMetrics {
    const val ChromeHeight = 48
    const val ChromeSide = 26
    const val ChromeGap = 7
    const val SheetInset = 8
    const val BarInset = 12
    const val Touch = 48
    const val ExpandedWidth = 600
    const val SidebarWidth = 320
}

@Composable
fun BrowserTheme(appearance: BrowserAppearance, content: @Composable () -> Unit) {
    val dark = appearance == BrowserAppearance.DARK || appearance == BrowserAppearance.SYSTEM && isSystemInDarkTheme()
    val colors = browserColors(dark)
    MaterialTheme(colorScheme = colors, typography = browserTypography()) {
        // Compose's own default ink is black. Screens that stand on no Surface read this one.
        CompositionLocalProvider(LocalContentColor provides colors.onBackground, content = content)
    }
}

/** Every role Yab draws with, so nothing falls back to Material's purple baseline. */
internal fun browserColors(dark: Boolean) = if (dark) darkColorScheme(
    primary = Color(0xFFF2F2F5), onPrimary = Color(0xFF1C1C1E),
    secondary = Color(0xFFF2F2F5), onSecondary = Color(0xFF1C1C1E),
    secondaryContainer = Color(0xFF3A3A3C), onSecondaryContainer = Color(0xFFF2F2F5),
    tertiary = Color(0xFFF2F2F5), onTertiary = Color(0xFF1C1C1E),
    surface = Color(0xFF1C1C1E), background = Color(0xFF1C1C1E),
    surfaceVariant = Color(0xFF2C2C2E), surfaceTint = Color.Transparent,
    surfaceContainerLowest = Color(0xFF1C1C1E), surfaceContainerLow = Color(0xFF1C1C1E),
    surfaceContainer = Color(0xFF2C2C2E), surfaceContainerHigh = Color(0xFF2C2C2E), surfaceContainerHighest = Color(0xFF3A3A3C),
    // Ink.rowSubtitle: small text must stay readable over a space's wash, dark ones too.
    onBackground = Color(0xFFF2F2F5), onSurface = Color(0xFFF2F2F5), onSurfaceVariant = Color(0xFFC7C7D1),
    outline = Color(0xFF545458), outlineVariant = Color(0xFF3A3A3C),
) else lightColorScheme(
    primary = Color(0xFF111111), onPrimary = Color.White,
    secondary = Color(0xFF111111), onSecondary = Color.White,
    secondaryContainer = Color(0xFFE5E5EA), onSecondaryContainer = Color(0xFF111111),
    tertiary = Color(0xFF111111), onTertiary = Color.White,
    surface = Color(0xFFF4F4F6), background = Color(0xFFF2F2F7),
    surfaceVariant = Color(0xFFE5E5EA), surfaceTint = Color.Transparent,
    surfaceContainerLowest = Color.White, surfaceContainerLow = Color(0xFFF4F4F6),
    surfaceContainer = Color(0xFFE5E5EA), surfaceContainerHigh = Color.White, surfaceContainerHighest = Color.White,
    onBackground = Color(0xFF111111), onSurface = Color(0xFF111111), onSurfaceVariant = Color(0xFF5A5A62),
    outline = Color(0xFFC6C6C8), outlineVariant = Color(0xFFE5E5EA),
)

/** Native 17-point text with Phone's zero tracking, rather than Material's extra half point. */
internal fun browserTypography(): Typography = Typography().let { t -> t.copy(
    displayLarge = t.displayLarge.copy(letterSpacing = 0.sp), displayMedium = t.displayMedium.copy(letterSpacing = 0.sp), displaySmall = t.displaySmall.copy(letterSpacing = 0.sp),
    headlineLarge = t.headlineLarge.copy(letterSpacing = 0.sp), headlineMedium = t.headlineMedium.copy(letterSpacing = 0.sp), headlineSmall = t.headlineSmall.copy(letterSpacing = 0.sp),
    titleLarge = t.titleLarge.copy(letterSpacing = 0.sp), titleMedium = t.titleMedium.copy(letterSpacing = 0.sp), titleSmall = t.titleSmall.copy(letterSpacing = 0.sp),
    bodyLarge = t.bodyLarge.copy(fontSize = 17.sp, lineHeight = 22.sp, letterSpacing = 0.sp), bodyMedium = t.bodyMedium.copy(letterSpacing = 0.sp), bodySmall = t.bodySmall.copy(letterSpacing = 0.sp),
    labelLarge = t.labelLarge.copy(letterSpacing = 0.sp), labelMedium = t.labelMedium.copy(letterSpacing = 0.sp), labelSmall = t.labelSmall.copy(letterSpacing = 0.sp)) }
