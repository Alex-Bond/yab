package dev.yab.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.ComposeTestRule

/** Follow real first-run controls; never set welcomed or substitute activity content. */
internal fun ComposeTestRule.completeStandaloneFirstRun() {
    val choices = listOf(
        hasTestTag("welcome.withoutMac"), hasTestTag("welcome.noMac"),
        hasTestTag("welcome.linksNotNow"), hasTestTag("welcome.finish"),
        hasContentDescription("Swipe up for your Mac’s tabs"), hasText("Start Browsing"),
    )
    fun exists(matcher: SemanticsMatcher) = onAllNodes(matcher).fetchSemanticsNodes().isNotEmpty()
    fun finished() = exists(hasTestTag("browser.field.input")) && !exists(hasTestTag("welcome"))
    repeat(8) {
        waitUntil(30_000) { finished() || choices.any(::exists) }
        if (finished()) return
        onNode(choices.first(::exists)).performClick()
        waitForIdle()
    }
    error("The actual standalone first-run journey did not reach its address field")
}
