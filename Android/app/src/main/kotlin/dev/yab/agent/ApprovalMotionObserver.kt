package dev.yab.agent

import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.geometry.Rect

/** Optional observation of actual draw callbacks. Never carries request facts, identifiers or payment data. */
internal enum class ApprovalDrawSurface { TRAY, CAPSULE, WINDOW, PICTURE }
internal data class ApprovalDrawFrame(val uptimeNanos: Long, val phase: ApprovalTravel, val boundsPx: Rect,
    val density: Float, val rise: Double, val fold: Double, val opacity: Double, val receipt: Boolean,
    val surface: ApprovalDrawSurface = ApprovalDrawSurface.TRAY, val result: ApprovalResultPhase? = null,
    val detailProgress: Double = 0.0)
internal val LocalApprovalMotionObserver = staticCompositionLocalOf<((ApprovalDrawFrame) -> Unit)?> { null }
