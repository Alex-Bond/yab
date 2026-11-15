package dev.yab.sync

/** Same precedence as current SyncKit SyncDevicePlatform.read. Explicit unknown never executes Mac work. */
internal object SyncDevicePlatform {
    fun isMac(platform: String?, model: String): Boolean = when {
        !platform.isNullOrEmpty() -> platform == "macos"
        else -> model.startsWith("Mac") || model.startsWith("iMac")
    }
}
