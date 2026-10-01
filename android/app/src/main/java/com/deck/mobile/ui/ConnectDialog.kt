package com.deck.mobile.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import com.deck.mobile.data.DiscoveredMac
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.launch

@Composable
fun ConnectDialog(
    initialAddress: String,
    initialToken: String,
    discovered: List<DiscoveredMac>,
    onDismiss: () -> Unit,
    onConnect: suspend (address: String, token: String) -> String?,
) {
    var address by remember { mutableStateOf(initialAddress) }
    var token by remember { mutableStateOf(initialToken) }
    var error by remember { mutableStateOf<String?>(null) }
    var loading by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val fieldColors = OutlinedTextFieldDefaults.colors(
        focusedBorderColor = Color.White,
        unfocusedBorderColor = Color.White.copy(alpha = 0.22f),
        focusedTextColor = Color.White,
        unfocusedTextColor = Color.White,
        cursorColor = Color.White,
        focusedLabelColor = Color.White.copy(alpha = 0.75f),
        unfocusedLabelColor = Color.White.copy(alpha = 0.5f),
        focusedContainerColor = DeckPalette.Field,
        unfocusedContainerColor = DeckPalette.Field,
    )

    LaunchedEffect(discovered) {
        if (address.isBlank() && discovered.size == 1) {
            address = discovered.first().address()
        }
    }

    fun submit() {
        if (loading) return
        scope.launch {
            loading = true
            error = null
            val message = onConnect(address, token)
            loading = false
            if (message == null) onDismiss() else error = message
        }
    }

    Dialog(
        onDismissRequest = { if (!loading) onDismiss() },
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Surface(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp),
            shape = RoundedCornerShape(28.dp),
            color = Color(0xFF1A1A1C),
        ) {
            Column(Modifier.padding(22.dp)) {
                Text(
                    text = "Conectar ao notebook",
                    color = DeckPalette.Text,
                    fontSize = 20.sp,
                    fontWeight = FontWeight.SemiBold,
                )
                Spacer(Modifier.height(8.dp))
                Text(
                    text = "Abra o app Deck no Mac, na mesma rede Wi-Fi. Escolha o computador e digite o código que aparece na tela dele.",
                    color = DeckPalette.Muted,
                    fontSize = 14.sp,
                    lineHeight = 19.sp,
                )
                if (discovered.isNotEmpty()) {
                    Spacer(Modifier.height(16.dp))
                    Text(
                        text = "Na rede",
                        color = DeckPalette.Text,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Spacer(Modifier.height(8.dp))
                    discovered.forEach { mac ->
                        val selected = address == mac.address()
                        Button(
                            onClick = { address = mac.address() },
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(bottom = 8.dp)
                                .height(48.dp),
                            shape = RoundedCornerShape(14.dp),
                            colors = ButtonDefaults.buttonColors(
                                containerColor = if (selected) Color.White else Color.White.copy(alpha = 0.08f),
                                contentColor = if (selected) Color.Black else Color.White,
                            ),
                        ) {
                            Text(mac.name, fontWeight = FontWeight.Medium)
                        }
                    }
                }
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(
                    value = address,
                    onValueChange = { address = it },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                    label = { Text("Endereço") },
                    placeholder = { Text("192.168.0.10:8765") },
                    keyboardOptions = KeyboardOptions(
                        keyboardType = KeyboardType.Uri,
                        imeAction = ImeAction.Next,
                    ),
                    colors = fieldColors,
                    shape = RoundedCornerShape(14.dp),
                )
                Spacer(Modifier.height(10.dp))
                OutlinedTextField(
                    value = token,
                    onValueChange = { token = it.uppercase().filter { char -> char.isLetterOrDigit() }.take(8) },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                    label = { Text("Código") },
                    keyboardOptions = KeyboardOptions(
                        capitalization = KeyboardCapitalization.Characters,
                        keyboardType = KeyboardType.Ascii,
                        imeAction = ImeAction.Done,
                    ),
                    keyboardActions = KeyboardActions(onDone = { submit() }),
                    colors = fieldColors,
                    shape = RoundedCornerShape(14.dp),
                )
                if (error != null) {
                    Spacer(Modifier.height(10.dp))
                    Text(text = error.orEmpty(), color = DeckPalette.Offline, fontSize = 13.sp)
                }
                Spacer(Modifier.height(18.dp))
                Button(
                    onClick = { submit() },
                    enabled = !loading,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(50.dp),
                    shape = RoundedCornerShape(16.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = Color.White,
                        contentColor = Color.Black,
                        disabledContainerColor = Color.White.copy(alpha = 0.4f),
                        disabledContentColor = Color.Black.copy(alpha = 0.6f),
                    ),
                ) {
                    if (loading) {
                        CircularProgressIndicator(
                            modifier = Modifier.height(22.dp),
                            color = Color.Black,
                            strokeWidth = 2.dp,
                        )
                    } else {
                        Text("Conectar", fontWeight = FontWeight.SemiBold)
                    }
                }
                TextButton(
                    onClick = onDismiss,
                    enabled = !loading,
                    modifier = Modifier.align(Alignment.CenterHorizontally),
                ) {
                    Text("Agora não", color = DeckPalette.Muted)
                }
            }
        }
    }
}

private fun DiscoveredMac.address(): String {
    return if (port == 8765) host else "$host:$port"
}
