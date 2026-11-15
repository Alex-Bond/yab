package dev.yab.browser

import android.os.SystemClock
import android.provider.Settings
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.engine.AndroidTabClock
import dev.yab.browser.model.FileTabActivityRepository
import dev.yab.browser.model.TabActivity
import java.io.File
import java.util.UUID
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class TabActivityDeviceTest {
    @Test(timeout = 20_000)
    fun realElapsedRealtimeAndBootCounterRecoverFromLocalJournal(): Unit = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val clock = AndroidTabClock(context)
        val before = SystemClock.elapsedRealtime()
        val sample = clock.now()
        assertTrue(sample.elapsed in before..SystemClock.elapsedRealtime())
        assertTrue(kotlin.math.abs(System.currentTimeMillis() - sample.wall) < 2_000)
        val actualBoot = Settings.Global.getInt(context.contentResolver, Settings.Global.BOOT_COUNT)
        assertEquals(actualBoot, sample.boot)
        assertTrue(actualBoot >= 0)
        val file = File(context.cacheDir, "clock-proof-${UUID.randomUUID()}.json")
        try {
            FileTabActivityRepository(file).save(mapOf("owned-tab" to TabActivity("owned-space", "owned-profile", "https://example.org", sample)))
            delay(25)
            val recovered = FileTabActivityRepository(file).load().getValue("owned-tab").clock
            val after = AndroidTabClock(context).now()
            val age = after.since(recovered)
            assertNotNull("Actual same-boot sample was rejected", age)
            assertTrue(age!! >= 25 && age < 10_000)
            assertNull(after.copy(boot = actualBoot + 1).since(recovered))
        } finally { file.delete(); File(file.parentFile, "${file.name}.pending").delete() }
    }
}
