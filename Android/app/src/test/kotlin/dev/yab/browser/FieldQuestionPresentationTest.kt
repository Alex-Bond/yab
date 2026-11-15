package dev.yab.browser

import dev.yab.browser.ui.browserFieldQuestion
import org.junit.Assert.*
import org.junit.Test

class FieldQuestionPresentationTest {
    @Test fun phoneQuestionRowsUseTheExistingAskAction() {
        assertTrue(browserFieldQuestion("what does anna want?"))
        assertTrue(browserFieldQuestion("Where is the station"))
        assertTrue(browserFieldQuestion("the next sprint?"))
        assertFalse(browserFieldQuestion("lisbon weather october"))
        assertFalse(browserFieldQuestion("https://example.com/what?is=next"))
        assertFalse(browserFieldQuestion("what?"))
    }
}
