package dev.yab.browser

import dev.yab.browser.model.*
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class SettingsPresentationLeaseTest {
    private class Engine : BrowserEngine {
        override fun activate(tab: BrowserTab, profile: WebsiteProfile) {}
        override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) {}
        override fun goBack(tabId: String) {}
        override fun goForward(tabId: String) {}
        override fun reload(tabId: String) {}
        override fun stop(tabId: String) {}
        override fun close(tabId: String) {}
        override suspend fun clearWebsiteData(profileIds: Set<String>) {}
    }
    private class Repository : BrowserRepository {
        override suspend fun load(): BrowserSnapshot? = null
        override suspend fun save(snapshot: BrowserSnapshot) {}
    }
    @Test fun retainedPageExitHasDrawingOwnershipButNeverPreferenceAuthority() = runTest {
        val c = BrowserController(Repository(), Engine(), backgroundScope); runCurrent()
        assertNull(c.captureSettingsPresentation())
        c.show(BrowserSurface.SETTINGS); val old = c.captureSettingsPresentation()!!
        assertTrue(c.settingsActionsCurrent(old)); assertTrue(c.dismissSettings(old))
        assertTrue(c.settingsPresentationCurrent(old)); assertFalse(c.settingsActionsCurrent(old))
        assertFalse(c.dismissSettings(old))
        c.show(BrowserSurface.SETTINGS); val next = c.captureSettingsPresentation()!!
        assertTrue(c.sameSettingsOwner(old, next))
        assertFalse(c.settingsPresentationCurrent(old)); assertFalse(c.settingsActionsCurrent(old))
        assertTrue(c.settingsActionsCurrent(next))
    }
    @Test fun backgroundAndAccountABARevokeOpaqueOwnershipEvenIfSettingsAndValuesStayTheSame() = runTest {
        val c = BrowserController(Repository(), Engine(), backgroundScope); runCurrent()
        c.show(BrowserSurface.SETTINGS); val original = c.captureSettingsPresentation()!!
        val epoch = c.state.value.surfaceEpoch
        c.backgrounded()
        assertEquals(epoch, c.state.value.surfaceEpoch)
        assertFalse(c.settingsPresentationOwned(original)); assertFalse(c.settingsActionsCurrent(original))
        assertNull(c.captureSettingsPresentation())
        assertTrue(c.settingsPresentationRetainable(original))
        c.foregrounded()
        val afterBackground = c.captureSettingsPresentation()!!
        assertTrue(c.sameSettingsSource(original, afterBackground))
        assertFalse(c.settingsActionsCurrent(original)); assertTrue(c.settingsActionsCurrent(afterBackground))
        assertFalse(c.sameSettingsOwner(original, afterBackground))
        c.invalidateLocalOwnership()
        val afterAccount = c.captureSettingsPresentation()!!
        assertFalse(c.sameSettingsOwner(afterBackground, afterAccount))
        assertFalse(c.settingsPresentationOwned(afterBackground)); assertTrue(c.settingsActionsCurrent(afterAccount))
    }
    @Test fun sameTurnPrivateBlockABARevokesTheOldLeaseBeforeEitherFrameIsPublished() = runTest {
        val c = BrowserController(Repository(), Engine(), backgroundScope); runCurrent()
        c.openUrl("https://settings-private.invalid/", privately = true); c.unlockPrivate(true)
        c.show(BrowserSurface.SETTINGS); val old = c.captureSettingsPresentation()!!
        c.lockPrivate(); assertFalse(c.settingsActionsCurrent(old))
        val locked = c.captureSettingsPresentation()!!
        assertTrue(c.settingsActionsCurrent(locked)); assertTrue(c.state.value.privateContentBlocked)
        c.unlockPrivate(true)
        assertFalse(c.settingsPresentationOwned(locked)); assertFalse(c.sameSettingsSource(old, locked))
        val fresh = c.captureSettingsPresentation()!!
        assertFalse(c.settingsPresentationOwned(old)); assertFalse(c.settingsActionsCurrent(old))
        assertTrue(c.settingsActionsCurrent(fresh))
    }
    @Test fun retainedPropertyCallbacksMergeCurrentPreferencesAndAStaleLeaseNeverEvaluatesItsTransformer() = runTest {
        val c = BrowserController(Repository(), Engine(), backgroundScope); runCurrent()
        c.show(BrowserSurface.SETTINGS); val lease = c.captureSettingsPresentation()!!
        val first = { c.updateSettings(lease) { it.copy(swipeAnywhere = false) } }
        val second = { c.updateSettings(lease) { it.copy(darkenWebsites = true) } }
        assertTrue(first()); assertTrue(second())
        assertFalse(c.state.value.settings.swipeAnywhere); assertTrue(c.state.value.settings.darkenWebsites)
        c.dismissSettings(lease)
        var evaluated = 0
        assertFalse(c.updateSettings(lease) { evaluated++; it.copy(swipeAnywhere = true) })
        assertEquals(0, evaluated)
        c.show(BrowserSurface.SETTINGS)
        assertFalse(c.updateSettings(lease) { evaluated++; it.copy(darkenWebsites = false) })
        assertEquals(0, evaluated)
        assertFalse(c.state.value.settings.swipeAnywhere); assertTrue(c.state.value.settings.darkenWebsites)
        val fresh = c.captureSettingsPresentation()!!
        assertTrue(c.updateSettings(fresh) { it.copy(swipeAnywhere = true) })
        assertTrue(c.state.value.settings.swipeAnywhere); assertTrue(c.state.value.settings.darkenWebsites)
    }

    @Test fun replacingOverlayCannotBorrowExitDrawingAndOrdinaryPreferenceChangesKeepTheLease() = runTest {
        val c = BrowserController(Repository(), Engine(), backgroundScope); runCurrent()
        c.openAbout(); val lease = c.captureSettingsPresentation()!!
        c.updateSettings(c.state.value.settings.copy(swipeAnywhere = false))
        assertTrue(c.settingsActionsCurrent(lease))
        c.show(BrowserSurface.HISTORY)
        assertFalse(c.settingsPresentationCurrent(lease)); assertFalse(c.dismissSettings(lease))
    }
}
