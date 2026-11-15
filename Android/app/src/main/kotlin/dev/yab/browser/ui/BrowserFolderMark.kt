package dev.yab.browser.ui

import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameMillis
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.Dp
import dev.yab.browser.model.BrowserFolder
import dev.yab.browser.model.BrowserSpace
import dev.yab.browser.model.BrowserSpaceLook
import kotlinx.coroutines.delay
import kotlin.math.*

/** The desktop's ordinary folder: shared 24-point geometry, with no agent eyes. */
@Composable
internal fun BrowserFolderMark(open: Boolean, base: Long, dark: Boolean, side: Dp, weight: Dp? = null) {
    val shades = remember(base, dark) { folderShades(base, dark) }
    val reduced = LocalBrowserAccessibility.current.reduceMotion
    var pose by remember { mutableStateOf(if (open) BrowserFolderPose.Open else BrowserFolderPose.Shut) }
    // On the Mac's clock, from wherever the last move got to.
    LaunchedEffect(open, reduced) {
        val goal = if (open) BrowserFolderPose.Open else BrowserFolderPose.Shut
        if (pose == goal) return@LaunchedEffect
        if (reduced) { pose = goal; return@LaunchedEffect }
        val from = pose
        val length = if (open) 300f else 240f
        val start = withFrameMillis { it }
        do {
            val progress = (withFrameMillis { it } - start) / length
            pose = browserFolderFold(from, open, progress)
        } while (progress < 1f)
    }
    Canvas(Modifier.requiredSize(side)) {
        val k = size.width / 24f
        val width = weight?.toPx() ?: (2 * k)
        val back = folderBack.map { folderProject(it, false, pose) }
        val front = folderFront.map { folderProject(it, true, pose) }
        fun path(points: List<Offset>, closed: Boolean = false) = Path().apply {
            points.firstOrNull()?.let { moveTo(it.x * k, it.y * k) }
            points.drop(1).forEach { lineTo(it.x * k, it.y * k) }
            if (closed) close()
        }
        val stroke = Stroke(width, cap = StrokeCap.Round, join = StrokeJoin.Round)
        drawPath(path(back, true), shades.back)
        drawPath(path(back, true), shades.line, style = stroke)
        drawPath(path(front, true), shades.body)
        drawPath(path(front.drop(17) + front.first()), shades.line, style = stroke)
        drawPath(path(front.take(18)), shades.line, style = Stroke((1.5f + .5f * pose.flap) * width / 2, cap = StrokeCap.Round, join = StrokeJoin.Round))
    }
}

/** A folder in a row, as in the Mac's column: the outline as wide as a site's icon, its line 2/24 of that. */
@Composable
internal fun BrowserSpaceFolderMark(folder: BrowserFolder, space: BrowserSpace, dark: Boolean, slot: Dp) {
    Box(Modifier.size(slot), contentAlignment = Alignment.Center) {
        BrowserFolderMark(folder.open, browserFolderColor(folder.color) ?: space.folderGround(dark), dark, slot * 24f / 18f, slot * 2f / 24f)
    }
}

/** The color a folder's shades are worked out on: the one the Mac's column wears for this space. */
internal fun BrowserSpace.folderGround(dark: Boolean): Long = BrowserSpaceLook.from(look, color).displayColors(dark).first()

/** The colors a folder can be given (FolderTint on the Mac). Black is No Color: it wears its space's shades. */
internal fun browserFolderColor(stored: String?): Long? = when (stored) {
    "teal" -> 0xFF11AF91
    "blue" -> 0xFF119AD0
    "purple" -> 0xFF7566AF
    "yellow" -> 0xFFEAB51B
    "pink" -> 0xFFDE7698
    "red" -> 0xFFCC5162
    "orange" -> 0xFFE47B4D
    else -> null
}

/** Which way a folder of `open` just went while its rows move, for the Mac's clock; null otherwise. */
@Composable
internal fun browserFolderMove(space: String, open: Set<String>): Boolean? {
    var known by remember(space) { mutableStateOf(open) }
    var move by remember(space) { mutableStateOf<Boolean?>(null) }
    if (open != known) { move = open.size > known.size; known = open }
    LaunchedEffect(known) {
        if (move != null) { delay(300); move = null }
    }
    return move
}

/** How far a folder is on its way open: how far turned, and how far its front is let down. */
internal data class BrowserFolderPose(val flap: Float, val turn: Float) {
    companion object {
        val Shut = BrowserFolderPose(0f, 0f)
        val Open = BrowserFolderPose(1f, 1f)
    }
}

private val folderArrive = CubicBezierEasing(.2f, .8f, .2f, 1f)
private val folderEase = CubicBezierEasing(0f, 0f, .58f, 1f)
private val folderBoth = CubicBezierEasing(.42f, 0f, .58f, 1f)

/** FaceView.fold on the Mac: opening it turns, then its front lets down; shutting, the front comes up, then it turns back. */
internal fun browserFolderFold(from: BrowserFolderPose, opening: Boolean, progress: Float): BrowserFolderPose {
    val p = progress.coerceIn(0f, 1f)
    fun part(start: Float, length: Float) = ((p - start) / length).coerceIn(0f, 1f)
    if (opening) {
        val turn = folderArrive.transform(part(0f, .5f))
        val flap = folderArrive.transform(part(.3f, .7f))
        return BrowserFolderPose(from.flap + (1 - from.flap) * flap, from.turn + (1 - from.turn) * turn)
    }
    val flap = folderEase.transform(part(0f, .55f))
    val turn = folderBoth.transform(part(.45f, .55f))
    return BrowserFolderPose(from.flap * (1 - flap), from.turn * (1 - turn))
}

private fun folderArc(cx: Float, cy: Float, r: Float, from: Double, to: Double) = (0..8).map {
    val a = (from + (to - from) * it / 8) * PI / 180
    Offset(cx + r * cos(a).toFloat(), cy + r * sin(a).toFloat())
}
private val folderBack = listOf(Offset(3f,17.7f), Offset(3f,6.5f)) + folderArc(5f,6.5f,2f,180.0,270.0) +
    listOf(Offset(9.3f,4.5f), Offset(11.2f,6.5f)) + folderArc(19f,8.5f,2f,270.0,360.0) +
    folderArc(18.2f,17.7f,2.8f,0.0,90.0) + folderArc(5.8f,17.7f,2.8f,90.0,180.0)
private val folderFront = folderArc(4.6f,10.6f,1.6f,180.0,270.0) + folderArc(19.4f,10.6f,1.6f,270.0,360.0) +
    folderArc(18.2f,17.7f,2.8f,0.0,90.0) + folderArc(5.8f,17.7f,2.8f,90.0,180.0)
private fun folderProject(point: Offset, front: Boolean, pose: BrowserFolderPose): Offset {
    val theta = 47.0 * pose.flap * PI / 180; val phi = 23.0 * pose.turn * PI / 180; val rho = -8.0 * pose.turn * PI / 180
    var y = point.y.toDouble(); var z = 0.0
    if (front) { val d = 20.5 - y; y = 20.5 - d * cos(theta); z = d * sin(theta) }
    val x2 = 12 + (point.x - 12) * cos(phi) + z * sin(phi)
    val z2 = -(point.x - 12) * sin(phi) + z * cos(phi)
    val scale = 116 / (116 - z2); val dx = (x2 - 12) * scale; val dy = 13 + (y - 13) * scale - 20.5
    return Offset((12 + dx*cos(rho) - dy*sin(rho)).toFloat(), (20.5 + dx*sin(rho) + dy*cos(rho)).toFloat())
}
private data class FolderShades(val line: Color, val body: Color, val back: Color)
private fun folderShades(base: Long, dark: Boolean): FolderShades {
    fun linear(shift: Int): Double { val x = ((base shr shift) and 255) / 255.0; return if (x <= .04045) x/12.92 else ((x+.055)/1.055).pow(2.4) }
    val r=linear(16); val g=linear(8); val b=linear(0)
    val l=Math.cbrt(.4122214708*r+.5363325363*g+.0514459929*b)
    val m=Math.cbrt(.2119034982*r+.6806995451*g+.1073969566*b)
    val s=Math.cbrt(.0883024619*r+.2817188376*g+.6299787005*b)
    val light=.2104542553*l+.7936177850*m-.0040720468*s
    val a=1.9779984951*l-2.4285922050*m+.4505937099*s; val z=.0259040371*l+.7827717662*m-.8086757660*s
    val chroma=hypot(a,z); val hue=atan2(z,a)
    fun ink(L: Double, more: Double): Color {
        val c=min(.13,chroma*more); val A=c*cos(hue); val B=c*sin(hue)
        val x=(L+.3963377774*A+.2158037573*B).pow(3); val y=(L-.1055613458*A-.0638541728*B).pow(3); val Z=(L-.0894841775*A-1.2914855480*B).pow(3)
        fun gamma(value: Double): Float { val v=value.coerceIn(0.0,1.0); return (if(v<=.0031308)12.92*v else 1.055*v.pow(1/2.4)-.055).toFloat() }
        return Color(gamma(4.0767416621*x-3.3077115913*y+.2309699292*Z),gamma(-1.2684380046*x+2.6097574011*y-.3413193965*Z),gamma(-.0041960863*x-.7034186147*y+1.7076147010*Z))
    }
    return if(dark) FolderShades(ink(.86,.7),ink(min(.66,light+.18),1.0),ink(min(.55,light+.05),1.2))
        else FolderShades(ink(.34,1.1),ink(min(.99,light+(1-light)*.7),.5),ink(light-.09,1.3))
}
