package dev.yab.browser.ui

import dev.yab.browser.engine.HistorySwipeConsumer
import dev.yab.browser.model.*
import kotlin.math.abs

/** Functional fallback: no preview navigation, fabricated page, or early history mutation. */
internal class BrowserHistorySwipeHostState(private val controller: BrowserController, private val allowed: () -> Boolean = { true }) : HistorySwipeConsumer {
    private var lease: HistorySwipeLease? = null
    private var width = 0f
    override fun current(): Boolean {
        if (!allowed()) { cancel(); return false }
        lease?.let { if (controller.historySwipeCurrent(it)) return true else { cancel(); return false } }
        return controller.state.value.let {
            it.settings.swipeAnywhere && it.surface == BrowserSurface.PAGE && !it.privateContentBlocked && !it.loading && !it.page.loading &&
                it.find == null && it.tab?.isBlank == false
        }
    }
    override fun begin(direction: HistorySwipeDirection, width: Float): Boolean {
        if (!current() || !width.isFinite() || width <= 0 || lease != null) return false
        lease = controller.captureHistorySwipe(direction) ?: return false
        this.width = width
        return true
    }
    override fun move(distance: Float) {
        if (!distance.isFinite() || lease?.let(controller::historySwipeCurrent) != true) cancel()
    }
    override fun end(distance: Float, velocity: Float, cancelled: Boolean) {
        val captured = lease ?: return
        lease = null
        val sign = if (captured.direction == HistorySwipeDirection.BACK) 1 else -1
        // .5/500 are the current Phone opener rule. History uses this bounded
        // functional release policy until actual UIKit tracking/let-go is measured.
        val commit = !cancelled && distance.isFinite() && velocity.isFinite() && distance * sign > 0 &&
            (abs(distance) >= width * .5f || velocity * sign >= 500f)
        if (commit) controller.commitHistorySwipe(captured) else controller.cancelHistorySwipe(captured)
    }
    fun cancel() { lease?.let(controller::cancelHistorySwipe); lease = null }
}
