// Public compiler probe only. This is not the private Yab UI or a ChromeActivity host.
package org.chromium.chrome.browser.yab.probe

import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable

@Composable
fun YabChromeUiProbe(onBack: () -> Unit) {
    MaterialTheme {
        Button(onClick = onBack) { Text("Back") }
    }
}
