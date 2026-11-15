package dev.yab.browser

import dev.yab.browser.model.*
import dev.yab.browser.ui.SettingsPresentation
import dev.yab.browser.ui.BrowserSettingsHostState
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class SettingsSpaceEditingTest {
    private class Repository(var snapshot: BrowserSnapshot) : BrowserRepository {
        override suspend fun load() = snapshot
        override suspend fun save(snapshot: BrowserSnapshot) { this.snapshot = snapshot }
    }
    private class Engine : BrowserEngine {
        var navigated = 0; var reloaded = 0; var closed = 0
        override fun activate(tab: BrowserTab, profile: WebsiteProfile) {}
        override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) { navigated++ }
        override fun goBack(tabId: String) {}
        override fun goForward(tabId: String) {}
        override fun reload(tabId: String) { reloaded++ }
        override fun stop(tabId: String) {}
        override fun close(tabId: String) { closed++ }
        override suspend fun clearWebsiteData(profileIds: Set<String>) {}
    }
    private fun snapshot() = BrowserSnapshot(spaces = listOf(
        BrowserSpace("first", "Personal"), BrowserSpace("edit", "Work", emoji = "star.fill",
            tabs = listOf(BrowserTab("tab", "https://space.invalid/", createdAt = 1)), currentTabId = "tab")), selectedSpaceId = "edit")
    private fun paint() = buildJsonObject {
        put("swatch", "custom"); put("color", "#112233"); put("grain", false); put("grainAmount", .1)
        put("future", buildJsonObject { put("enabled", true) })
    }

    @Test fun addSpaceSelectsItAndNamesItInsideSettingsWithOneFreshNavigationRequest() = runTest {
        val engine = Engine(); val c = BrowserController(Repository(snapshot()), engine, backgroundScope)
        runCurrent(); c.show(BrowserSurface.SETTINGS)
        val lease = c.captureSettingsPresentation()!!
        val made = c.createSettingsSpace(lease)!!
        assertEquals(BrowserSurface.SETTINGS, c.state.value.surface)
        assertEquals(made, c.state.value.selectedSpaceId)
        assertEquals("Untitled", c.state.value.space!!.name); assertEquals("🌐", c.state.value.space!!.emoji)
        assertEquals(BrowserSpaceLook.DEFAULT_COLOR, c.state.value.space!!.color)
        val request = c.settingsSpaceNavigation.value!!
        val fresh = c.captureSettingsPresentation()!!
        assertEquals(made, request.id); assertTrue(c.settingsSpaceNavigationCurrent(request, fresh))
        assertTrue(c.consumeSettingsSpaceNavigation(request, fresh)); assertFalse(c.consumeSettingsSpaceNavigation(request, fresh))
        assertEquals(0, engine.navigated); assertEquals(0, engine.reloaded); assertEquals(0, engine.closed)
        assertEquals("", SettingsSpaceDraft(c.state.value.space!!).copy(name = "").name)
    }

    @Test fun addFromLockedPrivateRequiresANewOwnerAndNeverCopiesThePrivatePage() = runTest {
        val c = BrowserController(Repository(snapshot()), Engine(), backgroundScope); runCurrent()
        c.openUrl("https://private-space.invalid/secret", privately = true)
        val privateTab = c.state.value.tab!!
        c.show(BrowserSurface.SETTINGS); val old = c.captureSettingsPresentation()!!
        assertTrue(c.state.value.privateContentBlocked)
        val made = c.createSettingsSpace(old)!!
        assertFalse(c.settingsActionsCurrent(old))
        val next = c.captureSettingsPresentation()!!; val request = c.settingsSpaceNavigation.value!!
        assertFalse(c.settingsSpaceNavigationCurrent(request, old)); assertTrue(c.settingsSpaceNavigationCurrent(request, next))
        assertEquals(made, c.state.value.space!!.id); assertFalse(c.state.value.space!!.isPrivate)
        assertTrue(c.state.value.space!!.tabs.isEmpty())
        assertTrue(c.state.value.spaces.filter(BrowserSpace::isPrivate).flatMap { it.tabs }.contains(privateTab))
        assertFalse(c.publicSnapshot().toString().contains("private-space.invalid"))
    }

    @Test fun dirtyNameAndEmojiMergeLatestFieldsWithoutReloadingTheExistingNativeTab() = runTest {
        val original = snapshot().let { it.copy(spaces = it.spaces.map { s -> if (s.id == "edit") s.copy(look = paint()) else s }) }
        val engine = Engine(); val c = BrowserController(Repository(original), engine, backgroundScope); runCurrent()
        c.show(BrowserSurface.SETTINGS); val owner = c.captureSettingsPresentation()!!
        val edit = c.captureSettingsSpaceEdit(owner, "edit") { true }!!
        val opened = c.state.value.space!!
        val draft = SettingsSpaceDraft(opened).rename("  New name  ").pick("🎨")
        val remotePaint = JsonObject(paint() + ("remote" to JsonPrimitive("arrived")))
        c.applySyncedSnapshot(original.copy(spaces = original.spaces.map { s -> if (s.id == "edit") s.copy(look = remotePaint) else s }))
        val calls = Triple(engine.navigated, engine.reloaded, engine.closed)
        assertTrue(c.commitSettingsSpace(edit, draft))
        val saved = c.state.value.space!!
        assertEquals("New name", saved.name); assertEquals("🎨", saved.emoji); assertEquals(remotePaint, saved.look)
        assertEquals(opened.tabs, saved.tabs); assertEquals(opened.websiteProfile, saved.websiteProfile)
        assertEquals(calls, Triple(engine.navigated, engine.reloaded, engine.closed)); assertEquals(BrowserSurface.SETTINGS, c.state.value.surface)
    }

    @Test fun aColorDraftChangesOnlyItsDirtyLookFieldsAgainstTheLatestRemotePalette() = runTest {
        val initial = snapshot().let { it.copy(spaces = it.spaces.map { s -> if (s.id == "edit") s.copy(look = paint()) else s }) }
        val c = BrowserController(Repository(initial), Engine(), backgroundScope); runCurrent(); c.show(BrowserSurface.SETTINGS)
        val lease = c.captureSettingsSpaceEdit(c.captureSettingsPresentation()!!, "edit") { true }!!
        val opened = c.state.value.space!!
        val draft = SettingsSpaceDraft(opened).paint(BrowserSpaceLook.from(opened.look).grain(.75))
        val arrived = JsonObject(paint() + mapOf("color" to JsonPrimitive("#ABCDEF"), "future" to JsonPrimitive("new")))
        c.applySyncedSnapshot(initial.copy(spaces = initial.spaces.map { s -> if (s.id == "edit") s.copy(name = "Remote", emoji = "🌱", look = arrived) else s }))
        assertTrue(c.commitSettingsSpace(lease, draft))
        val saved = c.state.value.space!!
        val stored = checkNotNull(saved.look)
        assertEquals("Remote", saved.name); assertEquals("🌱", saved.emoji)
        assertEquals(JsonPrimitive("#ABCDEF"), stored["color"]); assertEquals(JsonPrimitive("new"), stored["future"])
        assertEquals(.75, stored["grainAmount"]!!.jsonPrimitive.double, 0.0)
    }

    @Test fun anActualEditRepairsLegacyPaintIdentityWithoutDroppingItsUnknownFields() = runTest {
        val legacy = buildJsonObject { put("wash", "#ABCDEF"); put("future", JsonArray(listOf(JsonPrimitive(7)))) }
        val initial = snapshot().let { it.copy(spaces = it.spaces.map { s -> if (s.id == "edit") s.copy(look = legacy) else s }) }
        val c = BrowserController(Repository(initial), Engine(), backgroundScope); runCurrent(); c.show(BrowserSurface.SETTINGS)
        val edit = c.captureSettingsSpaceEdit(c.captureSettingsPresentation()!!, "edit") { true }!!
        val draft = SettingsSpaceDraft(c.state.value.space!!)
        assertTrue(c.commitSettingsSpace(edit, draft.paint(draft.look.grain(.55))))
        val saved = checkNotNull(c.state.value.space!!.look)
        assertEquals(legacy["future"], saved["future"]); assertEquals(legacy["wash"], saved["wash"])
        assertEquals(JsonPrimitive("custom"), saved["swatch"]); assertEquals(.55, saved["grainAmount"]!!.jsonPrimitive.double, 0.0)
    }

    @Test fun removedAndReaddedSpaceAndBackgroundCannotReviveAnEditorOrItsCommit() = runTest {
        val initial = snapshot(); val c = BrowserController(Repository(initial), Engine(), backgroundScope)
        runCurrent(); c.show(BrowserSurface.SETTINGS)
        val old = c.captureSettingsSpaceEdit(c.captureSettingsPresentation()!!, "edit") { true }!!
        val draft = SettingsSpaceDraft(c.state.value.space!!).rename("Should never save")
        c.applySyncedSnapshot(initial.copy(spaces = initial.spaces.take(1), selectedSpaceId = "first"))
        c.applySyncedSnapshot(initial)
        assertFalse(c.settingsSpaceEditCurrent(old)); assertFalse(c.commitSettingsSpace(old, draft))
        val current = c.captureSettingsSpaceEdit(c.captureSettingsPresentation()!!, "edit") { true }!!
        c.backgrounded(); c.foregrounded()
        assertFalse(c.commitSettingsSpace(current, draft))
        val fresh = c.captureSettingsSpaceEdit(c.captureSettingsPresentation()!!, "edit") { true }!!
        assertTrue(c.commitSettingsSpace(fresh, draft)); assertEquals("Should never save", c.state.value.spaces.first { it.id == "edit" }.name)
        c.invalidateLocalOwnership(); assertFalse(c.commitSettingsSpace(fresh, draft))
    }

    @Test fun routeLeaveCommitsBeforePopAndAReentrantNavigationCannotPopTheNewRoute() {
        val model = SettingsPresentation(); model.show(0, false, true); model.advance(600_000_000)
        assertTrue(model.pushAll(listOf(SettingsDestination.Space("edit"), SettingsDestination.Editor("edit", SettingsSpaceStep.NAME, true)), 600_000_000))
        model.advance(1_100_000_000)
        val leaving = model.frame.value.routes.last { it.interactive }
        assertEquals(SettingsDestination.Editor("edit", SettingsSpaceStep.NAME, true), leaving.destination)
        var calls = 0
        model.beforeRouteLeave = { id -> calls++; assertEquals(leaving.id, id); assertTrue(model.routeCurrent(id)); model.push("About", 1_100_000_000) }
        assertFalse(model.back(1_100_000_000)); assertEquals(1, calls)
        assertEquals("About", model.frame.value.title); assertFalse(model.frame.value.routes.first { it.id == leaving.id }.retired)
        model.revoke(); assertEquals(1, calls)
    }

    @Test fun nullableLookKeepsExactLegacySpaceBytesUntilAnActualPaintIsPresent() {
        val json = Json { encodeDefaults = true }
        val legacy = """{"id":"s","name":"Space","emoji":"","color":1,"ownSignIns":false,"isPrivate":false,"tabs":[],"currentTabId":null,"folders":[]}"""
        val decoded = json.decodeFromString(BrowserSpace.serializer(), legacy)
        assertNull(decoded.look); assertEquals(legacy, json.encodeToString(BrowserSpace.serializer(), decoded))
        val saved = decoded.copy(look = paint())
        val encoded = json.encodeToString(BrowserSpace.serializer(), saved)
        assertEquals(paint(), json.parseToJsonElement(encoded).jsonObject["look"])
        assertEquals(saved, json.decodeFromString(BrowserSpace.serializer(), encoded))
    }

    @Test fun createdSpaceDeliveryConsumesAndPushesInOneTurnAndNeverRecapturesAStaleOwner() = runTest {
        val c = BrowserController(Repository(snapshot()), Engine(), backgroundScope); runCurrent(); c.show(BrowserSurface.SETTINGS)
        val lease = c.captureSettingsPresentation()!!
        val id = c.createSettingsSpace(lease)!!; val request = c.settingsSpaceNavigation.value!!
        val host = BrowserSettingsHostState(lease, "Settings").apply { now = 700_000_000; presentation.showSettled(now, false, true) }
        assertTrue(host.deliverCreatedSpace(c, request, lease))
        assertNull(c.settingsSpaceNavigation.value)
        assertEquals(listOf(SettingsDestination.Space(id), SettingsDestination.Editor(id, SettingsSpaceStep.NAME, true)),
            host.presentation.frame.value.routes.takeLast(2).map { it.destination })
        assertFalse(host.deliverCreatedSpace(c, request, lease)); assertEquals(3, host.presentation.frame.value.routes.size)
        val secondId = c.createSettingsSpace(lease)!!; val second = c.settingsSpaceNavigation.value!!
        c.backgrounded(); c.foregrounded()
        assertFalse(host.deliverCreatedSpace(c, second, lease))
        assertSame(second, c.settingsSpaceNavigation.value)
        val fresh = c.captureSettingsPresentation()!!
        val freshHost = BrowserSettingsHostState(fresh, "Settings")
        assertFalse(freshHost.deliverCreatedSpace(c, second, fresh))
        assertFalse(freshHost.presentation.frame.value.routes.any { it.destination == SettingsDestination.Space(secondId) })
    }
}
