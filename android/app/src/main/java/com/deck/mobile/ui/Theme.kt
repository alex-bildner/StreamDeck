package com.deck.mobile.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

object DeckPalette {
    val Void = Color(0xFF050506)
    val ChassisTop = Color(0xFF2A2A2C)
    val ChassisBottom = Color(0xFF141416)
    val Well = Color(0xFF080809)
    val Key = Color(0xFF101012)
    val Text = Color(0xFFF4F4F5)
    val Muted = Color(0xFF9B9BA3)
    val Online = Color(0xFF3DDC84)
    val Offline = Color(0xFFFF5C5C)
    val Sheet = Color(0xFF161618)
    val Field = Color(0xFF222226)
}

private val Colors = darkColorScheme(
    background = DeckPalette.Void,
    surface = DeckPalette.Sheet,
    primary = DeckPalette.Text,
    onPrimary = Color.Black,
    onSurface = DeckPalette.Text,
    onBackground = DeckPalette.Text,
)

@Composable
fun DeckTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = Colors, content = content)
}
