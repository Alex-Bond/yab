package dev.yab.browser.ui

/** Phone PinGrid: balanced rows of at most five, collapsed after three rows. */
internal data class BrowserSpacePinGrid(val shown: Int, val columns: Int, val more: Int) {
    companion object {
        fun of(count: Int, expanded: Boolean): BrowserSpacePinGrid {
            require(count >= 0)
            val shown = if (expanded) count else minOf(15, count)
            if (shown == 0) return BrowserSpacePinGrid(0, 0, 0)
            val rows = (shown + 4) / 5
            return BrowserSpacePinGrid(shown, (shown + rows - 1) / rows, if (count > shown) count - shown + 1 else 0)
        }
    }
}
