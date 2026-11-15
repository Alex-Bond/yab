package dev.yab.agent

/** One retained elapsed frame for concurrent window, picture, page and scroll motion. */
internal class ApprovalDetailClock(private val window: ApprovalDetailPresentation, private val picture: ApprovalDetailPresentation,
    private val pages: ApprovalWindowPages) {
    private var previous: Long? = null
    val running get() = window.frame.value.running || picture.frame.value.running || pages.frame.value.running
    fun idle() { if (!running) previous = null }
    fun frame(now: Long) {
        if (!running) { previous = null; return }
        val last = previous
        previous = now
        if (last != null) {
            val elapsed = (now - last).coerceAtLeast(0) / 1_000_000_000.0
            window.advance(elapsed); picture.advance(elapsed); pages.advance(elapsed)
        }
        if (!running) previous = null
    }
}
