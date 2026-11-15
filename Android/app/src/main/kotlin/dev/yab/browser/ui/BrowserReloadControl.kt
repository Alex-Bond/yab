package dev.yab.browser.ui

import android.animation.ValueAnimator
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsPropertyKey
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import dev.yab.android.R

internal val ChromeReloadPoseKey = SemanticsPropertyKey<List<Float>>("ChromeReloadPose")
/** App-local fixture seam; null retains the person's actual animator preference. */
internal val LocalReloadAnimationsEnabled = staticCompositionLocalOf<Boolean?> { null }

/** The action/AT follows actual loading immediately; only its drawn glyph waits. */
@Composable
internal fun BrowserReloadControl(loading: Boolean, enabled: Boolean, onClick: () -> Unit,
    modifier: Modifier = Modifier, animationsEnabled: Boolean = LocalReloadAnimationsEnabled.current ?: ValueAnimator.areAnimatorsEnabled()) {
    val model = remember { ReloadPresentation() }
    val interactions = remember { MutableInteractionSource() }
    val pressed by interactions.collectIsPressedAsState()
    val reduced = LocalBrowserAccessibility.current.reduceMotion
    var pose by remember { mutableStateOf(model.pose) }
    val currentClick by rememberUpdatedState(onClick)
    LaunchedEffect(loading, pressed, enabled, reduced, animationsEnabled) {
        withFrameNanos { pose = model.update(it, loading, pressed && enabled, reduced, animationsEnabled) }
        while (model.moving) withFrameNanos { pose = model.advance(it) }
    }
    Box(modifier.size(44.dp).testTag("browser.chrome.reload").semantics {
        contentDescription = if (loading) "Stop loading" else "Reload"
        stateDescription = if (loading) "loading" else "ready"
        this[ChromeReloadPoseKey] = listOf(pose.stop, pose.rotation, pose.opacity)
    }.clickable(enabled = enabled, interactionSource = interactions, indication = null,
        role = Role.Button, onClick = { currentClick() }), contentAlignment = Alignment.Center) {
        Box(Modifier.size(22.dp).graphicsLayer { rotationZ = pose.rotation; alpha = pose.opacity },
            contentAlignment = Alignment.Center) {
            Icon(painterResource(R.drawable.chrome_reload), null, Modifier.size(22.dp).graphicsLayer {
                alpha = 1 - pose.stop; scaleX = 1 - .2f * pose.stop; scaleY = scaleX
            })
            Icon(painterResource(R.drawable.chrome_stop), null, Modifier.size(14.dp).graphicsLayer {
                alpha = pose.stop; scaleX = .8f + .2f * pose.stop; scaleY = scaleX
            })
        }
    }
}
