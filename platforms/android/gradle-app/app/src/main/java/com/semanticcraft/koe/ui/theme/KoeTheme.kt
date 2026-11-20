package com.semanticcraft.koe.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

object KoeFontSizes {
    val xs = 12.sp
    val sm = 14.sp
    val md = 16.sp
    val lg = 22.sp
}

object KoeShapes {
    val control = RoundedCornerShape(10.dp)
    val card = RoundedCornerShape(16.dp)
    val largeCard = RoundedCornerShape(24.dp)
    val sheetTop = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp)
    val pill = RoundedCornerShape(percent = 50)
}

@Immutable
data class KoePalette(
    val surface0: Color,
    val surface1: Color,
    val bgPanel: Color,
    val bgSubtle: Color,
    val border: Color,
    val accent: Color,
    val onAccent: Color,
    val accentSoft: Color,
    val textPrimary: Color,
    val textSecondary: Color,
    val textMuted: Color,
    val success: Color,
    val warning: Color,
    val danger: Color,
)

private val LightKoePalette = KoePalette(
    surface0 = Color(0xFFFFFFFF),
    surface1 = Color(0xFFFFFFFF),
    bgPanel = Color(0xFFF7F7F8),
    bgSubtle = Color(0xFFF1F1F3),
    border = Color(0xFFE3E3E7),
    accent = Color(0xFF242426),
    onAccent = Color(0xFFFFFFFF),
    accentSoft = Color(0xFFECECEF),
    textPrimary = Color(0xFF202022),
    textSecondary = Color(0xFF54545B),
    textMuted = Color(0xFF686870),
    success = Color(0xFF287447),
    warning = Color(0xFF8A5A12),
    danger = Color(0xFFB43D43),
)

private val DarkKoePalette = KoePalette(
    surface0 = Color(0xFF0E0E10),
    surface1 = Color(0xFF18181B),
    bgPanel = Color(0xFF141416),
    bgSubtle = Color(0xFF202024),
    border = Color(0xFF2C2C32),
    accent = Color(0xFFF4F4F6),
    onAccent = Color(0xFF0E0E10),
    accentSoft = Color(0xFF27272C),
    textPrimary = Color(0xFFF4F4F6),
    textSecondary = Color(0xFFB4B4BC),
    textMuted = Color(0xFF94949E),
    success = Color(0xFF4ADE80),
    warning = Color(0xFFFBBF24),
    danger = Color(0xFFF87171),
)

private val KoeLightColorScheme = lightColorScheme(
    primary = LightKoePalette.accent,
    onPrimary = LightKoePalette.onAccent,
    primaryContainer = LightKoePalette.accentSoft,
    onPrimaryContainer = LightKoePalette.textPrimary,
    secondary = LightKoePalette.textSecondary,
    onSecondary = LightKoePalette.surface0,
    secondaryContainer = LightKoePalette.accentSoft,
    onSecondaryContainer = LightKoePalette.textPrimary,
    background = LightKoePalette.bgPanel,
    onBackground = LightKoePalette.textPrimary,
    surface = LightKoePalette.surface0,
    onSurface = LightKoePalette.textPrimary,
    surfaceVariant = LightKoePalette.bgSubtle,
    onSurfaceVariant = LightKoePalette.textSecondary,
    outline = LightKoePalette.border,
    outlineVariant = LightKoePalette.border,
    error = LightKoePalette.danger,
    onError = LightKoePalette.surface0,
)

private val KoeDarkColorScheme = darkColorScheme(
    primary = DarkKoePalette.accent,
    onPrimary = DarkKoePalette.onAccent,
    primaryContainer = DarkKoePalette.accentSoft,
    onPrimaryContainer = DarkKoePalette.textPrimary,
    secondary = DarkKoePalette.textSecondary,
    onSecondary = DarkKoePalette.surface0,
    secondaryContainer = DarkKoePalette.accentSoft,
    onSecondaryContainer = DarkKoePalette.textPrimary,
    background = DarkKoePalette.bgPanel,
    onBackground = DarkKoePalette.textPrimary,
    surface = DarkKoePalette.surface0,
    onSurface = DarkKoePalette.textPrimary,
    surfaceVariant = DarkKoePalette.bgSubtle,
    onSurfaceVariant = DarkKoePalette.textSecondary,
    outline = DarkKoePalette.border,
    outlineVariant = DarkKoePalette.border,
    error = DarkKoePalette.danger,
    onError = DarkKoePalette.surface0,
)

private val KoeTypography = Typography(
    headlineSmall = TextStyle(fontSize = KoeFontSizes.lg, fontWeight = FontWeight.SemiBold, lineHeight = 28.sp),
    titleLarge = TextStyle(fontSize = KoeFontSizes.lg, fontWeight = FontWeight.SemiBold, lineHeight = 28.sp),
    titleMedium = TextStyle(fontSize = KoeFontSizes.md, fontWeight = FontWeight.SemiBold, lineHeight = 22.sp),
    titleSmall = TextStyle(fontSize = KoeFontSizes.sm, fontWeight = FontWeight.SemiBold, lineHeight = 20.sp),
    bodyLarge = TextStyle(fontSize = KoeFontSizes.md, fontWeight = FontWeight.Normal, lineHeight = 22.sp),
    bodyMedium = TextStyle(fontSize = KoeFontSizes.sm, fontWeight = FontWeight.Normal, lineHeight = 20.sp),
    bodySmall = TextStyle(fontSize = KoeFontSizes.xs, fontWeight = FontWeight.Normal, lineHeight = 16.sp),
    labelLarge = TextStyle(fontSize = KoeFontSizes.sm, fontWeight = FontWeight.Medium, lineHeight = 18.sp),
    labelMedium = TextStyle(fontSize = KoeFontSizes.xs, fontWeight = FontWeight.Medium, lineHeight = 16.sp),
    labelSmall = TextStyle(fontSize = KoeFontSizes.xs, fontWeight = FontWeight.Medium, lineHeight = 16.sp),
)

private val KoeMaterialShapes = Shapes(
    small = KoeShapes.control,
    medium = KoeShapes.card,
    large = KoeShapes.largeCard,
)

private val LocalKoeColors = staticCompositionLocalOf { LightKoePalette }

object KoeTheme {
    val colors: KoePalette
        @Composable
        @ReadOnlyComposable
        get() = LocalKoeColors.current
}

@Composable
fun KoeTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    val palette = if (darkTheme) DarkKoePalette else LightKoePalette
    val colorScheme = if (darkTheme) KoeDarkColorScheme else KoeLightColorScheme

    CompositionLocalProvider(LocalKoeColors provides palette) {
        MaterialTheme(
            colorScheme = colorScheme,
            typography = KoeTypography,
            shapes = KoeMaterialShapes,
            content = content,
        )
    }
}
