package com.deck.mobile.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.BottomSheetDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.deck.mobile.model.DeckApp
import java.text.Normalizer

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AppPickerSheet(
    apps: List<DeckApp>,
    loading: Boolean,
    error: String?,
    current: DeckApp?,
    savingId: String?,
    iconFor: (String) -> ImageBitmap?,
    onRequestIcon: (String) -> Unit,
    onPick: (DeckApp) -> Unit,
    onClear: () -> Unit,
    onRetry: () -> Unit,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var query by remember { mutableStateOf("") }
    val filtered = remember(apps, query) {
        val needle = query.foldAccents()
        if (needle.isBlank()) apps else apps.filter { it.name.foldAccents().contains(needle) }
    }
    val height = LocalConfiguration.current.screenHeightDp.dp * 0.88f

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = DeckPalette.Sheet,
        dragHandle = { BottomSheetDefaults.DragHandle(color = Color.White.copy(alpha = 0.35f)) },
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .height(height)
                .padding(horizontal = 16.dp),
        ) {
            Spacer(Modifier.height(8.dp))
            Text(
                text = if (current == null) "Vincular aplicativo" else "Trocar aplicativo",
                color = DeckPalette.Text,
                fontSize = 20.sp,
                fontWeight = FontWeight.SemiBold,
            )
            if (current != null) {
                Text(
                    text = "Este botão abre ${current.name}",
                    color = DeckPalette.Muted,
                    fontSize = 13.sp,
                )
                TextButton(onClick = onClear, enabled = savingId == null) {
                    Text("Remover deste botão", color = DeckPalette.Offline)
                }
            } else {
                Spacer(Modifier.height(6.dp))
            }
            OutlinedTextField(
                value = query,
                onValueChange = { query = it },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
                placeholder = { Text("Buscar") },
                leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = Color.White.copy(alpha = 0.7f),
                    unfocusedBorderColor = Color.White.copy(alpha = 0.16f),
                    focusedTextColor = Color.White,
                    unfocusedTextColor = Color.White,
                    cursorColor = Color.White,
                    focusedPlaceholderColor = DeckPalette.Muted,
                    unfocusedPlaceholderColor = DeckPalette.Muted,
                    focusedLeadingIconColor = DeckPalette.Muted,
                    unfocusedLeadingIconColor = DeckPalette.Muted,
                ),
                shape = RoundedCornerShape(14.dp),
            )
            Spacer(Modifier.height(12.dp))
            Box(Modifier.weight(1f).fillMaxWidth()) {
                when {
                    loading -> CircularProgressIndicator(
                        modifier = Modifier.align(Alignment.Center),
                        color = Color.White,
                    )
                    error != null -> Column(
                        modifier = Modifier.align(Alignment.Center).padding(24.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        Text(error, color = DeckPalette.Muted, textAlign = TextAlign.Center)
                        TextButton(onClick = onRetry) { Text("Tentar de novo", color = Color.White) }
                    }
                    filtered.isEmpty() -> Text(
                        text = if (apps.isEmpty()) "Nenhum aplicativo encontrado no notebook." else "Nada com esse nome.",
                        color = DeckPalette.Muted,
                        modifier = Modifier.align(Alignment.Center).padding(24.dp),
                        textAlign = TextAlign.Center,
                    )
                    else -> LazyVerticalGrid(
                        columns = GridCells.Adaptive(92.dp),
                        contentPadding = PaddingValues(bottom = 28.dp),
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                        verticalArrangement = Arrangement.spacedBy(12.dp),
                        modifier = Modifier.fillMaxSize(),
                    ) {
                        items(filtered, key = { it.id }) { app ->
                            AppChoice(
                                app = app,
                                bitmap = iconFor(app.id),
                                saving = savingId == app.id,
                                enabled = savingId == null,
                                onRequestIcon = onRequestIcon,
                                onPick = onPick,
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun AppChoice(
    app: DeckApp,
    bitmap: ImageBitmap?,
    saving: Boolean,
    enabled: Boolean,
    onRequestIcon: (String) -> Unit,
    onPick: (DeckApp) -> Unit,
) {
    LaunchedEffect(app.id) { onRequestIcon(app.id) }
    Column(
        modifier = Modifier
            .clip(RoundedCornerShape(16.dp))
            .clickable(enabled = enabled) { onPick(app) }
            .padding(vertical = 6.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(
            modifier = Modifier
                .size(64.dp)
                .clip(RoundedCornerShape(16.dp))
                .background(Color.Black),
            contentAlignment = Alignment.Center,
        ) {
            if (bitmap != null) {
                Image(
                    bitmap = bitmap,
                    contentDescription = app.name,
                    modifier = Modifier.fillMaxSize().padding(8.dp),
                    contentScale = ContentScale.Fit,
                )
            } else {
                Text(
                    text = app.name.take(1).uppercase(),
                    color = Color.White,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 22.sp,
                )
            }
            if (saving) {
                Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.45f)))
                CircularProgressIndicator(
                    modifier = Modifier.size(22.dp),
                    color = Color.White,
                    strokeWidth = 2.dp,
                )
            }
        }
        Spacer(Modifier.height(6.dp))
        Text(
            text = app.name,
            color = DeckPalette.Text,
            fontSize = 11.sp,
            textAlign = TextAlign.Center,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

private fun String.foldAccents(): String {
    val decomposed = Normalizer.normalize(this, Normalizer.Form.NFD)
    return decomposed.replace(Regex("\\p{Mn}+"), "").lowercase()
}
