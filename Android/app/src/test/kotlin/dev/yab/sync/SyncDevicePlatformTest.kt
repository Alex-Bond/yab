package dev.yab.sync

import org.junit.Assert.*
import org.junit.Test

class SyncDevicePlatformTest {
    @Test fun explicitPlatformWinsOverLegacyModelAndUnknownPeersNeverBecomeMacs() {
        assertTrue(SyncDevicePlatform.isMac("macos", "Unfamiliar hardware"))
        for (platform in listOf("android", "ios", "unknown", "future-platform", "MACOS", " ")) {
            assertFalse(platform, SyncDevicePlatform.isMac(platform, "MacBookPro"))
        }
        for (platform in listOf(null, "")) {
            assertTrue(SyncDevicePlatform.isMac(platform, "MacBookPro"))
            assertTrue(SyncDevicePlatform.isMac(platform, "iMac21"))
            for (model in listOf("iPhone", "iPad", "Pixel", "Future computer")) assertFalse(SyncDevicePlatform.isMac(platform, model))
        }
    }
}
