package dev.yab.browser.ui

import android.content.res.Configuration
import android.os.Build
import android.view.RoundedCorner
import android.view.View
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.foundation.background
import dev.yab.browser.model.BrowserTabletWorkspaceFrame
import dev.yab.browser.model.TabletOmniboxRoot
import dev.yab.browser.model.TabletWorkspaceRect
import dev.yab.browser.model.WorkspaceWindowState
import kotlin.math.min

/** Drawing values only. Physical left/right are app-window coordinates, never screen offsets. */
internal data class TabletCornerCircle(val radius: Double, val x: Double, val y: Double) {
    val valid get() = radius.isFinite() && radius > 0 && x.isFinite() && y.isFinite()
    companion object {
        fun pixels(radius: Int, x: Int, y: Int, density: Float): TabletCornerCircle? =
            if (!density.isFinite() || density <= 0) null else TabletCornerCircle(radius / density.toDouble(),
                x / density.toDouble(), y / density.toDouble()).takeIf { it.valid }
    }
}
internal data class TabletCornerRadii(val topLeft: Double, val topRight: Double,
    val bottomRight: Double, val bottomLeft: Double) {
    /** Preserve proportions when small content cannot contain adjacent corner arcs. */
    fun fitted(width: Double, height: Double): TabletCornerRadii {
        require(width.isFinite() && height.isFinite() && width >= 0 && height >= 0)
        require(listOf(topLeft, topRight, bottomRight, bottomLeft).all { it.isFinite() && it >= 0 })
        fun factor(edge: Double, sum: Double) = if (sum > 0) (edge / sum).coerceAtMost(1.0) else 1.0
        val scale = minOf(minOf(factor(width, topLeft + topRight), factor(width, bottomLeft + bottomRight)),
            minOf(factor(height, topLeft + bottomLeft), factor(height, topRight + bottomRight)))
        return TabletCornerRadii(topLeft * scale, topRight * scale, bottomRight * scale, bottomLeft * scale)
    }
}

internal object TabletConcentricGeometry {
    const val siteRadius = 32.0
    fun boundsValid(r: TabletWorkspaceRect) = listOf(r.x, r.y, r.width, r.height, r.x + r.width, r.y + r.height)
        .all(Double::isFinite) && r.width > 0 && r.height > 0
    private fun radius(circle: TabletCornerCircle?, horizontal: Double, vertical: Double, minimum: Double): Double {
        if (circle?.valid != true || horizontal <= 0 || vertical <= 0) return minimum
        // Equal edge insets share the parent's center exactly: R-8, not R-hypot(8,8).
        // Unequal offsets use the smaller remaining circular radius; SwiftUI's private
        // continuous/off-axis interpolation is not reproduced or claimed here.
        return maxOf(minimum, minOf(circle.radius, horizontal, vertical))
    }
    fun resolve(child: TabletWorkspaceRect, minimum: Double, topLeft: TabletCornerCircle? = null,
        topRight: TabletCornerCircle? = null, bottomRight: TabletCornerCircle? = null,
        bottomLeft: TabletCornerCircle? = null): TabletCornerRadii {
        require(boundsValid(child) && minimum.isFinite() && minimum >= 0)
        val right = child.x + child.width; val bottom = child.y + child.height
        return TabletCornerRadii(
            radius(topLeft, (topLeft?.x ?: child.x) - child.x, (topLeft?.y ?: child.y) - child.y, minimum),
            radius(topRight, right - (topRight?.x ?: right), (topRight?.y ?: child.y) - child.y, minimum),
            radius(bottomRight, right - (bottomRight?.x ?: right), bottom - (bottomRight?.y ?: bottom), minimum),
            radius(bottomLeft, (bottomLeft?.x ?: child.x) - child.x, bottom - (bottomLeft?.y ?: bottom), minimum)
        ).fitted(child.width, child.height)
    }
    fun page(frame: BrowserTabletWorkspaceFrame, bottomLeft: TabletCornerCircle?, bottomRight: TabletCornerCircle?): TabletCornerRadii {
        val r = resolve(frame.page, frame.pageCornerRadius, bottomLeft = bottomLeft, bottomRight = bottomRight)
        return r
    }
    fun inContainer(child: TabletWorkspaceRect, container: TabletWorkspaceRect, minimum: Double): TabletCornerRadii {
        require(boundsValid(container))
        val r = min(siteRadius, min(container.width, container.height) / 2)
        return resolve(child, minimum,
            TabletCornerCircle(r, container.x + r, container.y + r),
            TabletCornerCircle(r, container.x + container.width - r, container.y + r),
            TabletCornerCircle(r, container.x + container.width - r, container.y + container.height - r),
            TabletCornerCircle(r, container.x + r, container.y + container.height - r))
    }
}

/** The same immutable shape feeds clip and the new Phone centered stroke. */
internal data class BrowserTabletConcentricShape(val radii: TabletCornerRadii) : Shape {
    override fun createOutline(size: Size, layoutDirection: LayoutDirection, density: Density): Outline {
        val fitted = radii.fitted((size.width / density.density).toDouble(), (size.height / density.density).toDouble())
        fun corner(value: Double) = CornerRadius((value * density.density).toFloat())
        return Outline.Rounded(RoundRect(0f, 0f, size.width, size.height,
            corner(fitted.topLeft), corner(fitted.topRight), corner(fitted.bottomRight), corner(fitted.bottomLeft)))
    }
}

internal fun Modifier.tabletPageOutline(shape: BrowserTabletConcentricShape, width: Float, color: Color): Modifier =
    drawWithCache {
        val outline = shape.createOutline(size, layoutDirection, this) as Outline.Rounded
        val path = Path().apply { addRoundRect(outline.roundRect) }
        onDrawWithContent {
            drawContent()
            if (width > 0) drawPath(path, color, style = Stroke(width * density))
        }
    }.clip(shape)

/** A read-only visual sample, never an action lease. Replacement keys are compared at use,
 * so a configuration/root change drops the old radii before the next layout observation. */
internal data class TabletWindowCornerSnapshot private constructor(
    private val root: View, private val token: Any, private val configuration: Configuration,
    private val density: Float, private val window: WorkspaceWindowState, private val measuredRoot: TabletOmniboxRoot,
    val bottomLeft: TabletCornerCircle?, val bottomRight: TabletCornerCircle?,
) {
    fun current(view: View, window: WorkspaceWindowState, measuredRoot: TabletOmniboxRoot, density: Float): Boolean =
        this.window == window && this.measuredRoot == measuredRoot && this.density == density &&
            view.rootView === root && view.windowToken === token && view.isAttachedToWindow && view.isShown &&
            root.isAttachedToWindow && root.windowToken === token && view.resources.configuration == configuration
    companion object {
        @androidx.annotation.RequiresApi(31)
        private fun corner(insets: android.view.WindowInsets, position: Int, density: Float): TabletCornerCircle? =
            insets.getRoundedCorner(position)?.let { c -> TabletCornerCircle.pixels(c.radius, c.center.x, c.center.y, density) }
        fun capture(view: View, window: WorkspaceWindowState, measuredRoot: TabletOmniboxRoot, density: Float): TabletWindowCornerSnapshot? {
            if (Build.VERSION.SDK_INT < 31 || !window.registered || window.geometry?.valid != true ||
                !measuredRoot.valid || !density.isFinite() || density <= 0 || !view.isAttachedToWindow || !view.isShown) return null
            val token = view.windowToken ?: return null
            val root = view.rootView
            if (!root.isAttachedToWindow || root.windowToken !== token) return null
            val config = Configuration(view.resources.configuration)
            val insets = root.rootWindowInsets ?: return null
            val result = TabletWindowCornerSnapshot(root, token, config, density, window, measuredRoot,
                corner(insets, RoundedCorner.POSITION_BOTTOM_LEFT, density), corner(insets, RoundedCorner.POSITION_BOTTOM_RIGHT, density))
            return result.takeIf { it.current(view, window, measuredRoot, density) }
        }
    }
}

/** Site plates inherit only this actual local container's placement, not its input authority. */
internal data class TabletConcentricContainer(val source: Any, val bounds: TabletWorkspaceRect)
internal val LocalTabletConcentricContainer = staticCompositionLocalOf<TabletConcentricContainer?> { null }

/** One visual binding. A late old layout observation cannot populate a new source/density. */
internal class TabletConcentricBounds {
    private var current: Binding? = null
    fun bind(source: Any?, density: Float): Binding? {
        if (source == null || !density.isFinite() || density <= 0) { current = null; return null }
        current?.takeIf { it.source === source && it.density == density }?.let { return it }
        return Binding(this, source, density).also { current = it }
    }
    internal class Binding(private val owner: TabletConcentricBounds, val source: Any, val density: Float) {
        private var observed by mutableStateOf<TabletWorkspaceRect?>(null)
        val bounds: TabletWorkspaceRect? get() = observed.takeIf { owner.current === this }
        fun positioned(next: TabletWorkspaceRect?): Boolean {
            if (owner.current !== this) return false
            observed = next?.takeIf(TabletConcentricGeometry::boundsValid)
            return true
        }
    }
}
internal fun tabletShapeBounds(coordinates: LayoutCoordinates, density: Float): TabletWorkspaceRect? {
    if (!coordinates.isAttached || !density.isFinite() || density <= 0) return null
    val p = coordinates.positionInWindow()
    return TabletWorkspaceRect(p.x / density.toDouble(), p.y / density.toDouble(),
        coordinates.size.width / density.toDouble(), coordinates.size.height / density.toDouble())
        .takeIf(TabletConcentricGeometry::boundsValid)
}
@Composable
internal fun tabletConcentricPlate(minimum: Double, color: Color, clip: Boolean = false): Modifier {
    val container = LocalTabletConcentricContainer.current
    val density = LocalDensity.current.density
    val owner = remember { TabletConcentricBounds() }
    val original = owner.bind(container?.source, density)
    val bounds = original?.bounds
    val radii = if (container != null && bounds != null) TabletConcentricGeometry.inContainer(bounds, container.bounds, minimum)
        else TabletCornerRadii(minimum, minimum, minimum, minimum)
    val shape = BrowserTabletConcentricShape(radii)
    return Modifier.onGloballyPositioned { original?.positioned(tabletShapeBounds(it, density)) }
        .then(if (clip) Modifier.clip(shape) else Modifier).background(color, shape)
}
