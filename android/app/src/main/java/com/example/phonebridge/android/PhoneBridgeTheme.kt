package com.example.phonebridge.android

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

private val BridgeBlue = Color(0xFF0088FF)

private val BridgeLightColors = lightColorScheme(
    primary = BridgeBlue,
    onPrimary = Color.White,
    secondary = Color(0xFF6558D3),
    background = Color(0xFFF2F2F7),
    onBackground = Color(0xFF171923),
    surface = Color(0xFFFFFFFF),
    onSurface = Color(0xFF171923),
    surfaceVariant = Color(0xFFE8EAF2),
    onSurfaceVariant = Color(0xFF4D5665),
    outline = Color(0xFF8792A6),
    error = Color(0xFFD94A4A),
)

private val BridgeDarkColors = darkColorScheme(
    primary = Color(0xFF58AFFF),
    onPrimary = Color(0xFF062544),
    secondary = Color(0xFFB7AAFF),
    background = Color(0xFF101116),
    onBackground = Color(0xFFF5F5F8),
    surface = Color(0xFF202127),
    onSurface = Color(0xFFF5F5F8),
    surfaceVariant = Color(0xFF2A2C35),
    onSurfaceVariant = Color(0xFFC8CBD4),
    outline = Color(0xFF737888),
    error = Color(0xFFFF8C83),
)

@Composable
fun PhoneBridgeTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = if (isSystemInDarkTheme()) BridgeDarkColors else BridgeLightColors,
        content = content,
    )
}

@Composable
fun PhoneBridgeBackdrop(modifier: Modifier = Modifier, content: @Composable BoxScope.() -> Unit) {
    val dark = isSystemInDarkTheme()
    val background = MaterialTheme.colorScheme.background
    Box(modifier.fillMaxSize().background(background)) {
        Canvas(Modifier.fillMaxSize()) {
            val blueAlpha = if (dark) 0.24f else 0.17f
            val violetAlpha = if (dark) 0.17f else 0.14f
            drawRect(Brush.radialGradient(listOf(Color(0xFF4D91FF).copy(alpha = blueAlpha), Color.Transparent), Offset(size.width * 0.88f, size.height * 0.04f), size.width * 0.78f))
            drawRect(Brush.radialGradient(listOf(Color(0xFF9B83FF).copy(alpha = violetAlpha), Color.Transparent), Offset(size.width * 0.03f, size.height * 0.48f), size.width * 0.82f))
        }
        content()
    }
}

@Composable
fun PhoneBridgeGlassPanel(
    modifier: Modifier = Modifier,
    content: @Composable BoxScope.() -> Unit,
) {
    val dark = isSystemInDarkTheme()
    val scheme = MaterialTheme.colorScheme
    val shape = RoundedCornerShape(28.dp)
    Box(
        modifier = modifier
            .clip(shape)
            .background(scheme.surface.copy(alpha = if (dark) 0.78f else 0.78f))
            .border(1.dp, scheme.onSurface.copy(alpha = if (dark) 0.08f else 0.07f), shape),
        content = content,
    )
}

@Composable
fun PhoneBridgeSurface(
    modifier: Modifier = Modifier,
    content: @Composable BoxScope.() -> Unit,
) {
    val dark = isSystemInDarkTheme()
    val scheme = MaterialTheme.colorScheme
    val shape = RoundedCornerShape(22.dp)
    Box(
        modifier = modifier
            .clip(shape)
            .background(scheme.surface.copy(alpha = 0.78f))
            .border(1.dp, scheme.onSurface.copy(alpha = if (dark) 0.08f else 0.07f), shape),
        content = content,
    )
}
