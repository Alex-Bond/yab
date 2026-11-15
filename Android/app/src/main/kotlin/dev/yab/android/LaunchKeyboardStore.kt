package dev.yab.android

import android.content.Context
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/** Bounded local UI memory. No browser/Private record, account adoption or network action. */
internal class LaunchKeyboardStore(context: Context) {
    private val preferences = context.getSharedPreferences("launch-keyboard", Context.MODE_PRIVATE)
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    fun read(): LaunchKeyboardMemory {
        val value = preferences.getString("front", null)?.takeIf { it.length <= 12_288 } ?: return LaunchKeyboardMemory()
        return runCatching { json.decodeFromString<LaunchKeyboardMemory>(value) }.getOrNull()
            ?.takeIf { it.valid() } ?: LaunchKeyboardMemory()
    }
    fun save(value: LaunchKeyboardMemory) {
        if (value.valid()) preferences.edit().putString("front", json.encodeToString(value)).apply()
    }
}

/** Public optional test API, present and registered only in an instrumented process. */
internal object LaunchKeyboardTestEnvironment {
    fun registered(): Boolean = runCatching {
        Class.forName("androidx.test.platform.app.InstrumentationRegistry")
            .getMethod("getInstrumentation").invoke(null) is android.app.Instrumentation
    }.getOrDefault(false)
    const val EXTRA = "dev.yab.launchKeyboard"
}
