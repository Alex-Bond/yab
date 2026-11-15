package dev.yab.agent

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** The conversation's existing actions, with Phone's words and right-hand Mac glyphs. */
@Composable internal fun ChatMenuItem(title: String, icon: ImageVector, enabled: Boolean = true, onClick: () -> Unit) {
    DropdownMenuItem(text = { Text(title, fontSize = 17.sp) }, onClick = onClick, enabled = enabled,
        modifier = Modifier.widthIn(min = 236.dp).height(44.dp), contentPadding = PaddingValues(horizontal = 16.dp),
        trailingIcon = { Icon(icon, null, Modifier.size(20.dp)) })
}
