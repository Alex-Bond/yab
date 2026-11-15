package dev.yab.browser.ui

import android.view.View
import android.view.ViewGroup
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import dev.yab.browser.engine.NativeLinkPreview
import org.mozilla.geckoview.GeckoView

/** One accessible commit action; the preview document cannot be interacted with. */
@Composable
fun LinkPreviewCard(preview: NativeLinkPreview, commit: () -> Unit, released: () -> Unit) {
    val page by preview.page.collectAsState()
    val onCommit by rememberUpdatedState(commit)
    val onReleased by rememberUpdatedState(released)
    DisposableEffect(preview) { onDispose { onReleased() } }
    Box(Modifier.fillMaxWidth().padding(bottom = 12.dp).clip(RoundedCornerShape(16.dp))) {
      Column {
        AndroidView(modifier = Modifier.fillMaxWidth().heightIn(min = 160.dp, max = 240.dp).height(220.dp), factory = { context ->
            GeckoView(context).apply {
                setAutofillEnabled(false)
                importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
                descendantFocusability = ViewGroup.FOCUS_BLOCK_DESCENDANTS
                isFocusable = false; isFocusableInTouchMode = false
                setOnTouchListener { _, _ -> true }
                setSession(preview.session)
                preview.session.setFocused(false)
            }
        }, update = { it.session?.setFocused(false) }, onReset = null, onRelease = { view -> view.releaseSession() })
        if (page.loading) LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
        Text(if (page.failed) "Preview unavailable" else page.title.ifEmpty { preview.url },
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp), maxLines = 2,
            style = MaterialTheme.typography.bodyMedium)
      }
      // The overlay, rather than the native document, owns every tap and long press.
      Box(Modifier.matchParentSize().testTag("link.preview").clickable { onCommit() }.clearAndSetSemantics {
          contentDescription = "Open preview, ${page.title.ifEmpty { preview.url }}"
          onClick { onCommit(); true }
      })
    }
}
