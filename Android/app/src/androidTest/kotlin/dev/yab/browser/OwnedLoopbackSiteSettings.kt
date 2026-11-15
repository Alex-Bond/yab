package dev.yab.browser

import android.os.ParcelFileDescriptor
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.engine.SitePreferences
import dev.yab.browser.engine.SiteSettingsStore
import java.io.File
import org.json.JSONObject

/** Explicit initial conditions for fictional loopback pages. Public host settings
 * intentionally survive between spaces/processes, while a new fixture assumes
 * 100% mobile layout. Never clear a personal host, app profile or physical device. */
internal object OwnedLoopbackSiteSettings {
    fun reset() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        val qemu = instrumentation.uiAutomation.executeShellCommand("getprop ro.kernel.qemu").use {
            ParcelFileDescriptor.AutoCloseInputStream(it).bufferedReader().use { reader -> reader.readText().trim() }
        }
        check(qemu == "1")
        val context = instrumentation.targetContext
        val store = SiteSettingsStore(File(context.filesDir, "site-settings.json"))
        val previous = store.site("127.0.0.1", false)
        store.clear("127.0.0.1", false)
        check(store.site("127.0.0.1", false) == SitePreferences())
        val folder = File(context.getExternalFilesDir(null), "instrumentation/loopback-initial-conditions").apply { mkdirs() }
        File(folder, "${System.nanoTime()}.json").writeText(JSONObject().put("host", "127.0.0.1")
            .put("beforeZoom", previous.zoom).put("beforeDesktop", previous.desktop)
            .put("initialZoom", 1.0).put("initialDesktop", false).put("ownedEmulator", true)
            .put("otherHostsPreserved", true).toString(2))
    }
}
