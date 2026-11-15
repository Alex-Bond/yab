package dev.yab.browser.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.yab.browser.model.BrowserController
import dev.yab.browser.model.FieldAnchor
import dev.yab.browser.model.TabletPageEntryLease

/** Main's original PAGE source, not a factory for a new native/account authority on click.
 * All methods are synchronous UI-thread operations. Failed currentness is permanent. */
class BrowserTabletPageAddressEntry internal constructor(
    private val controller: BrowserController,
    private val original: TabletPageEntryLease,
    private val originalEnvironmentCurrent: () -> Boolean,
) {
    private var retired = false
    fun retire() { retired = true }
    fun current(): Boolean {
        if (retired) return false
        if (!controller.tabletPageEntryCurrent(original) || !originalEnvironmentCurrent()) {
            retired = true
            return false
        }
        return true
    }
    fun open(anchor: FieldAnchor): Boolean {
        if (!anchor.valid() || !current()) return false
        return controller.openTabletAddress(original, anchor).also { if (it) retired = true }
    }
}

/** A rendered control can retire without changing Main's still-original capability.
 * No mutable callback field ever supplies a replacement entry to a saved semantics action. */
internal class BrowserTabletPageAddressControl(private val entry: BrowserTabletPageAddressEntry,
    private val originalSceneCurrent: () -> Boolean) {
    private var retired = false
    fun retire() { retired = true }
    fun current(): Boolean {
        if (retired) return false
        if (!originalSceneCurrent()) { retired = true; return false }
        return entry.current()
    }
    fun open(anchor: FieldAnchor): Boolean = anchor.valid() && current() && entry.open(anchor)
}

/** Only the real address action from the tablet toolbar. Other toolbar commands are separate.
 * Both the measured anchor and its root are Compose-root logical coordinates. */
@Composable
internal fun BrowserTabletPageAddress(control: BrowserTabletPageAddressControl, address: String?,
    root: LayoutCoordinates, modifier: Modifier = Modifier, embedded: Boolean = false) {
    val density = LocalDensity.current.density
    var placed by remember(control, root, density) { mutableStateOf<LayoutCoordinates?>(null) }
    var measured by remember(control, root, density) { mutableStateOf<FieldAnchor?>(null) }
    var measuredRoot by remember(control, root, density) { mutableStateOf<FieldAnchor?>(null) }
    fun frame(coordinates: LayoutCoordinates): FieldAnchor? {
        if (!coordinates.isAttached || !density.isFinite() || density <= 0f) return null
        val rect = coordinates.boundsInRoot()
        return FieldAnchor(rect.left / density.toDouble(), rect.top / density.toDouble(),
            rect.width / density.toDouble(), rect.height / density.toDouble()).takeIf { it.valid() }
    }
    val open = open@ {
        if (!control.current()) return@open
        val coordinates = placed ?: return@open
        val anchor = frame(coordinates) ?: return@open
        val rootFrame = frame(root) ?: return@open
        if (anchor != measured || rootFrame != measuredRoot || anchor.x < rootFrame.x || anchor.y < rootFrame.y ||
            anchor.x + anchor.width > rootFrame.x + rootFrame.width ||
            anchor.y + anchor.height > rootFrame.y + rootFrame.height) return@open
        control.open(anchor)
        Unit
    }
    Box(modifier.fillMaxWidth().height(if (embedded) 44.dp else 56.dp), contentAlignment = Alignment.Center) {
        key(control, root, density) {
            val capsule = if (embedded) Modifier.fillMaxWidth().height(44.dp) else
                Modifier.widthIn(max = 540.dp).fillMaxWidth().padding(horizontal = 12.dp)
                    .height(44.dp).background(MaterialTheme.colorScheme.onSurface.copy(alpha = .055f), CircleShape)
            Box(capsule
                .onGloballyPositioned { coordinates ->
                    placed = coordinates; measured = frame(coordinates); measuredRoot = frame(root)
                }
                .clickable(enabled = control.current(), role = Role.Button, onClick = open)
                .semantics {
                    contentDescription = "Search or enter address"
                    stateDescription = address.orEmpty()
                }.testTag("browser.tablet.address").padding(horizontal = 16.dp),
                contentAlignment = Alignment.Center) {
                Text(address ?: "Search or enter address", fontSize = 16.sp, maxLines = 1,
                    overflow = TextOverflow.MiddleEllipsis, color = MaterialTheme.colorScheme.onSurface)
            }
        }
    }
}
