package dev.yab.browser

import dev.yab.browser.model.*
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class FieldPrivateOwnershipTest {
    private class Engine : BrowserEngine {
        var onActivate: (() -> Unit)? = null
        override fun activate(tab: BrowserTab, profile: WebsiteProfile) { onActivate?.invoke() }
        override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) = Unit
        override fun goBack(tabId: String) = Unit
        override fun goForward(tabId: String) = Unit
        override fun reload(tabId: String) = Unit
        override fun stop(tabId: String) = Unit
        override fun close(tabId: String) = Unit
        override suspend fun clearWebsiteData(profileIds: Set<String>) = Unit
    }
    private fun repository() = object : BrowserRepository {
        override suspend fun load(): BrowserSnapshot? = null
        override suspend fun save(snapshot: BrowserSnapshot) = Unit
    }
    @Test fun eyesDoNotAuthenticateAndPrivacyABACannotReviveAnAttempt() = runTest {
        val browser = BrowserController(repository(), Engine(), backgroundScope); runCurrent()
        browser.openField(privately = true)
        assertTrue(browser.state.value.privateLocked)
        assertTrue(browser.state.value.fieldIsPrivate)
        val first = requireNotNull(browser.captureFieldPrivateUnlock())
        browser.fieldPrivacy(false); browser.fieldPrivacy(true)
        assertFalse(browser.completeFieldPrivateUnlock(first, true))
        assertTrue(browser.state.value.privateLocked)
        val still = requireNotNull(browser.captureFieldPrivateUnlock())
        browser.fieldPrivacy(true) // Even a same-value event revokes the pending action.
        assertFalse(browser.completeFieldPrivateUnlock(still, true))
        assertTrue(browser.state.value.privateLocked)
    }
    @Test fun twoAttemptsSupersedeAndEveryResultIsConsumedBeforeUnlock() = runTest {
        val browser = BrowserController(repository(), Engine(), backgroundScope); runCurrent()
        browser.openField(privately = true)
        val first = requireNotNull(browser.captureFieldPrivateUnlock())
        val second = requireNotNull(browser.captureFieldPrivateUnlock())
        assertFalse(browser.completeFieldPrivateUnlock(first, true))
        assertTrue(browser.completeFieldPrivateUnlock(second, true))
        assertFalse(browser.state.value.privateLocked)
        browser.lockPrivate()
        assertFalse(browser.completeFieldPrivateUnlock(second, true))
        val rejected = requireNotNull(browser.captureFieldPrivateUnlock())
        assertTrue(browser.completeFieldPrivateUnlock(rejected, false))
        assertFalse(browser.completeFieldPrivateUnlock(rejected, true))
        assertTrue(browser.state.value.privateLocked)
    }
    @Test fun backgroundAndReplacementFieldAndIdentityEachRevokeTheAttempt() = runTest {
        val browser = BrowserController(repository(), Engine(), backgroundScope); runCurrent()
        browser.openField(privately = true)
        val background = requireNotNull(browser.captureFieldPrivateUnlock())
        browser.backgrounded(); browser.foregrounded()
        assertFalse(browser.completeFieldPrivateUnlock(background, true))
        val replaced = requireNotNull(browser.captureFieldPrivateUnlock())
        browser.dismissSurface(); browser.openField(privately = true)
        assertFalse(browser.completeFieldPrivateUnlock(replaced, true))
        val identity = requireNotNull(browser.captureFieldPrivateUnlock())
        browser.invalidateLocalOwnership(); browser.openField(privately = true)
        assertFalse(browser.completeFieldPrivateUnlock(identity, true))
        assertTrue(browser.state.value.privateLocked)
    }
    @Test fun lockSettingABACannotReuseAStaleSuccess() = runTest {
        val browser = BrowserController(repository(), Engine(), backgroundScope); runCurrent()
        browser.openField(privately = true)
        val attempt = requireNotNull(browser.captureFieldPrivateUnlock())
        browser.updateSettings(browser.state.value.settings.copy(lockPrivate = false))
        browser.updateSettings(browser.state.value.settings.copy(lockPrivate = true))
        assertFalse(browser.completeFieldPrivateUnlock(attempt, true))
        assertTrue(browser.state.value.privateLocked)
    }

    @Test fun blockedPageAuthenticationIsSingleUseAndCannotSurviveBackgroundOrAccountReplacement() = runTest {
        val engine = Engine()
        val browser = BrowserController(repository(), engine, backgroundScope); runCurrent()
        browser.openUrl("https://private-cover.test/", privately = true)
        val first = requireNotNull(browser.capturePrivateUnlock())
        val next = requireNotNull(browser.capturePrivateUnlock())
        assertFalse(browser.completePrivateUnlock(first, true))
        assertTrue(browser.completePrivateUnlock(next, false))
        assertFalse(browser.completePrivateUnlock(next, true))
        val paused = requireNotNull(browser.capturePrivateUnlock())
        browser.backgrounded(); browser.foregrounded()
        assertFalse(browser.completePrivateUnlock(paused, true))
        val account = requireNotNull(browser.capturePrivateUnlock())
        browser.invalidateLocalOwnership()
        assertFalse(browser.completePrivateUnlock(account, true))
        val current = requireNotNull(browser.capturePrivateUnlock())
        engine.onActivate = {
            assertFalse("Native activation received a still-live auth attempt", browser.privateUnlockCurrent(current))
            assertFalse(browser.completePrivateUnlock(current, true))
        }
        assertTrue(browser.completePrivateUnlock(current, true))
        browser.lockPrivate()
        assertFalse(browser.completePrivateUnlock(current, true))
        assertTrue(browser.state.value.privateContentBlocked)
    }

    @Test fun blockedPageSourceAndRemoteSettingsABACannotReviveTheOldLease() = runTest {
        val browser = BrowserController(repository(), Engine(), backgroundScope); runCurrent()
        browser.openUrl("https://private-cover.test/first", privately = true)
        val first = requireNotNull(browser.state.value.tab)
        browser.openUrl("https://private-cover.test/second", privately = true)
        val second = requireNotNull(browser.state.value.tab)
        browser.selectTab(first.id)
        val switched = requireNotNull(browser.capturePrivateUnlock())
        browser.selectTab(second.id); browser.selectTab(first.id)
        assertFalse(browser.completePrivateUnlock(switched, true))
        val navigated = requireNotNull(browser.capturePrivateUnlock())
        browser.pageChanged(first.id, EnginePageState(url = "https://private-cover.test/changed", progress = 1f))
        browser.pageChanged(first.id, EnginePageState(url = first.url, progress = 1f))
        assertFalse(browser.completePrivateUnlock(navigated, true))
        val settings = requireNotNull(browser.capturePrivateUnlock())
        val public = requireNotNull(browser.publicSnapshot())
        browser.applySyncedSnapshot(public.copy(settings = public.settings.copy(lockPrivate = false)))
        browser.applySyncedSnapshot(public.copy(settings = public.settings.copy(lockPrivate = true)))
        assertFalse(browser.completePrivateUnlock(settings, true))
        assertTrue(browser.state.value.privateLocked)
    }

    @Test fun newTabSyncedProfileABACannotReviveAFieldAttemptWithTheSameValues() = runTest {
        val browser = BrowserController(repository(), Engine(), backgroundScope); runCurrent()
        browser.openField(privately = true)
        val source = browser.state.value
        val attempt = requireNotNull(browser.captureFieldPrivateUnlock())
        val public = requireNotNull(browser.publicSnapshot())
        val changed = public.copy(spaces = public.spaces.map { if (it.id == source.selectedSpaceId) it.copy(ownSignIns = !it.ownSignIns) else it })
        browser.applySyncedSnapshot(changed)
        assertEquals(BrowserSurface.FIELD, browser.state.value.surface)
        assertEquals(source.surfaceEpoch, browser.state.value.surfaceEpoch)
        assertNotEquals(source.space!!.websiteProfile, browser.state.value.space!!.websiteProfile)
        assertFalse(browser.fieldPrivateUnlockCurrent(attempt))
        browser.applySyncedSnapshot(public)
        assertEquals(source.space!!.websiteProfile, browser.state.value.space!!.websiteProfile)
        assertFalse(browser.completeFieldPrivateUnlock(attempt, true))
        assertTrue(browser.state.value.privateLocked)
    }
}
