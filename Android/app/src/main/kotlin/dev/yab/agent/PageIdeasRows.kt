package dev.yab.agent

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** The caller supplies controller.visible(owner), so a changed source cannot flash old suggestions. */
@Composable
fun PageIdeasRows(
    state: PageIdeasState,
    onPick: (String) -> Unit,
    modifier: Modifier = Modifier,
    leading: (@Composable () -> Unit)? = null,
) {
    if (state.owner == null || state.owner.isPrivate || state.loading || state.lines.isEmpty()) return
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        state.lines.take(3).forEach { idea ->
            TextButton(onClick = { onPick(idea) }, modifier = Modifier.fillMaxWidth().heightIn(min = 44.dp).testTag("chat.idea")) {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    leading?.invoke()
                    Text(idea, color = MaterialTheme.colorScheme.onSurface, fontSize = 16.sp,
                        modifier = Modifier.weight(1f).padding(vertical = 2.dp))
                }
            }
        }
    }
}
