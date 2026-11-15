package dev.yab.browser.engine

import android.content.Context
import android.os.SystemClock
import android.provider.Settings
import dev.yab.browser.model.TabActivityClock

/** BOOT_COUNT is read-only here. Devices that deny the read cannot authorize recovered ages. */
class AndroidTabClock(context: Context) {
    private val resolver = context.applicationContext.contentResolver
    fun now(): TabActivityClock = TabActivityClock(System.currentTimeMillis(), SystemClock.elapsedRealtime(),
        runCatching { Settings.Global.getInt(resolver, Settings.Global.BOOT_COUNT).takeIf { it >= 0 } }.getOrNull(), TabActivityClock.processIdentity)
}
