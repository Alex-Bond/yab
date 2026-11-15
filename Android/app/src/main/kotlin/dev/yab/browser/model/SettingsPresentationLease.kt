package dev.yab.browser.model

/** Process-local preference lifetime. Drawing an exit is never permission to run a preference. */
class SettingsPresentationLease internal constructor(internal val ownership: Long,
    internal val foreground: Long, val surfaceEpoch: Long, internal val privateBoundary: Long)

/** Observable only for preference presentation, never a global page authority. */
data class SettingsPresentationLifetime(val generation: Long = 0, val active: Boolean = true, val privateBoundary: Long = 0)
