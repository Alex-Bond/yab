package dev.yab.browser

import dev.yab.browser.engine.SiteDecision
import dev.yab.browser.engine.SitePermission
import dev.yab.browser.engine.SitePreferences
import dev.yab.browser.engine.SiteSettingsStore
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class SiteSettingsStoreTest {
    @Test fun zoomStepsClampAndNormalizeExactlyLikePhone() {
        assertEquals(listOf(0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.4, 1.5, 1.75, 2.0, 2.5, 3.0), SiteSettingsStore.zoomSteps)
        assertEquals(1.75, SiteSettingsStore.step(1.5, 1)!!, 0.0)
        assertEquals(1.5, SiteSettingsStore.step(1.75, -1)!!, 0.0)
        assertNull(SiteSettingsStore.step(3.0, 1)); assertNull(SiteSettingsStore.step(0.5, -1))
        assertEquals("example.com", SiteSettingsStore.key("WWW.Example.COM"))
        assertEquals("news.example.com", SiteSettingsStore.key("news.example.com"))
        val settings = SiteSettingsStore()
        settings.setZoom("example.com", false, 100.0)
        assertEquals(3.0, settings.site("www.example.com", false).zoom, 0.0)
        settings.setZoom("example.com", false, Double.NaN)
        assertEquals(3.0, settings.site("example.com", false).zoom, 0.0)
        settings.setZoom("example.com", false, 0.1)
        assertEquals(0.5, settings.site("example.com", false).zoom, 0.0)
        assertEquals(175, SiteSettingsStore.percent(1.75))
    }

    @Test fun publicSettingsSurviveRecreationAndPrivateNeverReadsOrWritesThem() {
        val directory = Files.createTempDirectory("yab-sites").toFile()
        val file = directory.resolve("settings.json")
        try {
            val settings = SiteSettingsStore(file)
            settings.setZoom("www.example.com", false, 1.75)
            settings.setDesktop("example.com", false, true)
            settings.setDecision("example.com", false, SitePermission.CAMERA, SiteDecision.ALLOWED)
            val publicBytes = file.readText()
            assertEquals(SitePreferences(), settings.site("example.com", true))
            settings.setZoom("example.com", true, 0.5)
            settings.setDesktop("private-secret.invalid", true, true)
            settings.setDecision("private-secret.invalid", true, SitePermission.MICROPHONE, SiteDecision.OFF)
            assertEquals(publicBytes, file.readText())
            assertFalse(file.readText().contains("private-secret"))
            val restored = SiteSettingsStore(file)
            assertEquals(1.75, restored.site("example.com", false).zoom, 0.0)
            assertTrue(restored.site("example.com", false).desktop)
            assertEquals(SiteDecision.ALLOWED, restored.site("example.com", false).permissions[SitePermission.CAMERA])
            assertEquals(SitePreferences(), restored.site("example.com", true))
            settings.forgetPrivate()
            assertEquals(SitePreferences(), settings.site("private-secret.invalid", true))
            assertEquals(publicBytes, file.readText())
        } finally { directory.listFiles()?.forEach { it.delete() }; directory.delete() }
    }

    @Test fun firstMediaRequestRemainsAskAndAnyExplicitDenialWinsCombinedRequests() {
        val settings = SiteSettingsStore()
        val both = setOf(SitePermission.CAMERA, SitePermission.MICROPHONE)
        assertEquals(SiteDecision.ASK, settings.asked("example.com", false, both))
        assertEquals(both.associateWith { SiteDecision.ASK }, settings.site("example.com", false).permissions)
        settings.setDecision("example.com", false, SitePermission.CAMERA, SiteDecision.ALLOWED)
        assertEquals(SiteDecision.ASK, settings.asked("example.com", false, both))
        settings.setDecision("example.com", false, SitePermission.MICROPHONE, SiteDecision.ALLOWED)
        assertEquals(SiteDecision.ALLOWED, settings.asked("example.com", false, both))
        settings.setDecision("example.com", false, SitePermission.CAMERA, SiteDecision.OFF)
        assertEquals(SiteDecision.OFF, settings.asked("example.com", false, both))
        assertEquals(SiteDecision.ASK, settings.asked("example.com", true, both))
        settings.forget("example.com", false, SitePermission.CAMERA)
        assertNull(settings.site("example.com", false).permissions[SitePermission.CAMERA])
        assertEquals(SiteDecision.ASK, settings.asked("example.com", false, both))
    }

    @Test fun serialWriterReceivesOnlyPublicSnapshotsAndCorruptSavedGrantsFailToAsk() {
        val directory = Files.createTempDirectory("yab-sites-queue").toFile()
        val file = directory.resolve("settings.json")
        val queue = mutableListOf<() -> Unit>()
        try {
            val settings = SiteSettingsStore(file, write = queue::add)
            settings.setDesktop("first.test", false, true)
            settings.setZoom("second.test", false, 2.0)
            settings.setDecision("private-secret.invalid", true, SitePermission.CAMERA, SiteDecision.ALLOWED)
            assertEquals(2, queue.size)
            assertFalse(file.exists())
            queue.forEach { it() }
            val restored = SiteSettingsStore(file)
            assertTrue(restored.site("first.test", false).desktop)
            assertEquals(2.0, restored.site("second.test", false).zoom, 0.0)
            assertFalse(file.readText().contains("private-secret"))
            file.writeText("{\"schema\":1,\"sites\":{\"example.com\":{\"zoom\":9,\"permissions\":{\"CAMERA\":\"ALLOWED\"}}}}")
            val corrupt = SiteSettingsStore(file)
            assertNotNull(corrupt.state.value.error)
            assertEquals(SiteDecision.ASK, corrupt.asked("example.com", false, setOf(SitePermission.CAMERA)))
        } finally { directory.listFiles()?.forEach { it.delete() }; directory.delete() }
    }
}
