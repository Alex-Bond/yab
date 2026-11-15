package dev.yab.browser

import dev.yab.browser.model.*
import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class TabActivityTest {
    @Test fun sameBootRecoveryUsesBothClocksWhileRebootCorrectionAndUnknownFailClosed(): Unit = runBlocking {
        val folder = Files.createTempDirectory("yab-tab-age").toFile()
        try {
            val file = folder.resolve("activity.json")
            val before = TabActivityClock(1_000_000, 10_000, 41)
            FileTabActivityRepository(file).save(mapOf("tab" to TabActivity("space", "profile", "https://example.org", before)))
            val recovered = FileTabActivityRepository(file).load().getValue("tab").clock
            val delay = BrowserController.TWELVE_HOURS
            assertEquals(delay, TabActivityClock(before.wall + delay, before.elapsed + delay, 41).since(recovered))
            assertNull(TabActivityClock(before.wall + delay, before.elapsed + 1, 41).since(recovered))
            assertNull(TabActivityClock(before.wall - 1, before.elapsed + delay, 41).since(recovered))
            assertNull(TabActivityClock(before.wall + delay, before.elapsed + delay, 42).since(recovered))
            assertNull(TabActivityClock(before.wall + delay, 1, 41).since(recovered))
            assertNull(TabActivityClock(before.wall + delay, before.elapsed + delay, null).since(recovered))
            val localOnly = before.copy(boot = null, process = "process-one")
            assertEquals(delay, localOnly.copy(wall = before.wall + delay, elapsed = before.elapsed + delay).since(localOnly))
            assertNull(localOnly.copy(wall = before.wall + delay, elapsed = before.elapsed + delay, process = "recreated-process").since(localOnly))
            file.writeText("{corrupt}")
            assertTrue(FileTabActivityRepository(file).load().isEmpty())
        } finally { folder.listFiles()?.forEach { it.delete() }; folder.delete() }
    }
}
