package dev.yab.android

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

@Composable
fun WelcomeScreen(onBrowse: () -> Unit, onJoin: () -> Unit, onScan: () -> Unit) {
    Surface(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize().systemBarsPadding().padding(28.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
            Text("Yab", style = MaterialTheme.typography.displayLarge)
            Text("Your browser, with you.", Modifier.padding(top = 16.dp), style = MaterialTheme.typography.headlineSmall)
            Text("Start browsing here. Connect Yab on your Mac to bring your spaces and chats with you.", Modifier.padding(vertical = 24.dp), style = MaterialTheme.typography.bodyLarge)
            Button(onClick = onBrowse, modifier = Modifier.fillMaxWidth()) { Text("Start Browsing") }
            OutlinedButton(onClick = onJoin, modifier = Modifier.fillMaxWidth().padding(top = 8.dp)) { Text("Join Your Mac") }
            TextButton(onClick = onScan) { Text("Scan a Mac's QR Code") }
        }
    }
}
