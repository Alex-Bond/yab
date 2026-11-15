package dev.yab.browser

import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import dev.yab.browser.ui.reconcileFieldEditorValue
import org.junit.Assert.*
import org.junit.Test

class BrowserFieldEditorEchoTest {
    @Test fun anOlderScheduledModelEchoCannotEraseNewerImeEdits() {
        val newest = TextFieldValue("beta1probe123", TextRange(12), TextRange(5, 12))
        assertSame(newest, reconcileFieldEditorValue(newest, "beta1robe", "beta1probe123", true))
    }
    @Test fun aRetiredInputCannotOverwriteTheRetainedDraft() {
        val newest = TextFieldValue("new owner draft", TextRange(3, 8))
        assertSame(newest, reconcileFieldEditorValue(newest, "old draft", "old draft", false))
    }
    @Test fun aCurrentModelEchoPreservesNativeSelectionAndComposition() {
        val newest = TextFieldValue("beta1probe", TextRange(2, 5), TextRange(2, 5))
        assertSame(newest, reconcileFieldEditorValue(newest, "beta1probe", "beta1probe", true))
    }
    @Test fun anAcceptedExternalClearStillUpdatesTheEditor() {
        assertEquals(TextFieldValue("", TextRange(0)),
            reconcileFieldEditorValue(TextFieldValue("old address", TextRange(0, 11)), "", "", true))
    }
}
