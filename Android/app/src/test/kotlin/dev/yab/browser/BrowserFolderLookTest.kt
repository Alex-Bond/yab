package dev.yab.browser

import dev.yab.browser.model.*
import dev.yab.browser.ui.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/** A folder looks as it does on the Mac: its shades on the color the Mac wears, its own color kept, its fold on the Mac's clock. */
class BrowserFolderLookTest {
    private fun raw(value: String) = Json.parseToJsonElement(value).jsonObject

    @Test fun aSwatchKeepsTheMacsPair() {
        val space = BrowserSpace("s", "S", "", 0xFF000000, look = raw("""{"swatch":"sky","color":"#000000"}"""))
        assertEquals(0xFF8DB6E6, space.folderGround(false))
        assertEquals(0xFF1D304B, space.folderGround(true))
    }

    @Test fun aColorOfItsOwnIsDeepenedInTheDark() {
        val picked = 0xFFD1F1FF
        val space = BrowserSpace("s", "S", "", picked)
        assertEquals(picked, space.folderGround(false))
        assertEquals(SpaceLookColor.deepened(picked), space.folderGround(true))
    }

    @Test fun onlyTheMacsColorsCount() {
        assertEquals(0xFF11AF91, browserFolderColor("teal"))
        assertNull(browserFolderColor("black"))
        assertNull(browserFolderColor(null))
    }

    @Test fun aFolderKeepsItsColorInTheStore() {
        val folder = BrowserFolder("f", "F", color = "teal")
        assertEquals("teal", Json.decodeFromString<BrowserFolder>(Json.encodeToString(folder)).color)
        assertNull(Json.decodeFromString<BrowserFolder>("""{"id":"f","name":"F"}""").color)
    }

    @Test fun openingTurnsBeforeTheFrontLetsDown() {
        assertEquals(BrowserFolderPose.Shut, browserFolderFold(BrowserFolderPose.Shut, true, 0f))
        assertEquals(BrowserFolderPose.Open, browserFolderFold(BrowserFolderPose.Shut, true, 1f))
        val early = browserFolderFold(BrowserFolderPose.Shut, true, .2f)
        assertTrue(early.turn > 0f)
        assertEquals(0f, early.flap)
    }

    @Test fun shuttingLiftsTheFrontBeforeItTurnsBack() {
        val early = browserFolderFold(BrowserFolderPose.Open, false, .3f)
        assertTrue(early.flap < 1f)
        assertEquals(1f, early.turn)
        assertEquals(BrowserFolderPose.Shut, browserFolderFold(BrowserFolderPose.Open, false, 1f))
    }

    @Test fun aReversalRunsFromWhereItGotTo() {
        val midway = BrowserFolderPose(.4f, .8f)
        assertEquals(midway, browserFolderFold(midway, false, 0f))
        assertEquals(BrowserFolderPose.Open, browserFolderFold(midway, true, 1f))
    }
}
