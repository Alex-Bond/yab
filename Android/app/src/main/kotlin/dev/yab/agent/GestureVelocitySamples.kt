package dev.yab.agent

import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.PointerInputChange
import androidx.compose.ui.input.pointer.util.VelocityTracker

/** Android batches fast moves between frames. Keep their original times and positions,
 * in the same stationary window frame as the current sample. */
@OptIn(ExperimentalComposeUiApi::class)
internal fun VelocityTracker.addWindowChange(change: PointerInputChange, origin: Offset = Offset.Zero) {
    for (sample in change.historical) addPosition(sample.uptimeMillis, sample.position + origin)
    addPosition(change.uptimeMillis, change.position + origin)
}
