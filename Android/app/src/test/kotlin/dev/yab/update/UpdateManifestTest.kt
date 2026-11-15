package dev.yab.update

import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.*
import org.junit.Test

class UpdateManifestTest {
    private val site = UpdateChannel.PRODUCTION
    private val hash = "ae2cb33aeb2ec01f407b2c637c31ce3f98134dbd3d58e09d251951c3fa357ff1"
    private fun json(code: String = "3", name: String = "\"0.1.0-alpha.3\"", url: String = "\"https://yetanotherbrowser.com/android.apk\"",
        sha: String = "\"$hash\"", minSdk: String = "29") =
        """{"versionCode":$code,"versionName":$name,"url":$url,"sha256":$sha,"minSdk":$minSdk}"""

    @Test fun readsThePublishedShape() {
        assertEquals(UpdateOffer(3, "0.1.0-alpha.3", "https://yetanotherbrowser.com/android.apk", hash, 29), UpdateManifest.parse(json(), site))
    }

    @Test fun readsTheFileTheSiteServes() {
        val text = java.io.File(UpdateManifestTest::class.java.classLoader!!.getResource("update/latest.json")!!.toURI()).readText()
        assertEquals(2, UpdateManifest.parse(text, site)?.versionCode)
    }

    @Test fun newKeysDoNotStopAnOldApp() {
        assertNotNull(UpdateManifest.parse(json().dropLast(1) + ""","notes":"later"}""", site))
    }

    @Test fun refusesEverythingElse() {
        listOf("", "null", "[]", "{}", "not json", json() + "x", json().replace("}", ""),
            json(code = "\"3\""), json(code = "3.0"), json(code = "0"), json(code = "-1"), json(code = "99999999999"), json(code = "true"),
            json(name = "3"), json(name = "\"\""), json(name = "\"a b\""), json(name = "\"${"1".repeat(65)}\""),
            json(sha = "\"${hash.uppercase()}\""), json(sha = "\"${hash.drop(1)}\""), json(sha = "\"${hash.dropLast(1)}g\""),
            json(minSdk = "\"29\""), json(minSdk = "0"), json(minSdk = "1001"),
            """{"versionCode":3,"versionName":"1","url":"https://yetanotherbrowser.com/a.apk","sha256":"$hash"}""",
        ).forEach { assertNull(it, UpdateManifest.parse(it, site)) }
        assertNull(UpdateManifest.parse(" ".repeat(UpdateManifest.MAX_BYTES.toInt() + 1) + json(), site))
    }

    @Test fun theApkStandsOnTheSiteOverHttps() {
        listOf("http://yetanotherbrowser.com/android.apk", "https://evil.example/android.apk", "https://yetanotherbrowser.com.evil.example/a.apk",
            "https://x@yetanotherbrowser.com/a.apk", "https://yetanotherbrowser.com:8443/a.apk",
            "https://8hauzhgbhxiipn9a.public.blob.vercel-storage.com/a.apk", "file:///sdcard/a.apk", "android.apk",
        ).forEach { assertNull(it, UpdateManifest.parse(json(url = "\"$it\""), site)) }
    }

    @Test fun aRedirectMayOnlyReachBlobStorageOverHttps() {
        assertTrue(site.allowsRedirect("https://8hauzhgbhxiipn9a.public.blob.vercel-storage.com/a.apk".toHttpUrl()))
        assertTrue(site.allowsRedirect("https://yetanotherbrowser.com/b.apk".toHttpUrl()))
        assertFalse(site.allowsRedirect("http://8hauzhgbhxiipn9a.public.blob.vercel-storage.com/a.apk".toHttpUrl()))
        assertFalse(site.allowsRedirect("https://public.blob.vercel-storage.com.evil.example/a.apk".toHttpUrl()))
        assertFalse(site.allowsRedirect("https://evil.example/a.apk".toHttpUrl()))
    }

    @Test fun onlyTheOwnerSignedReleaseIsOnTheProductionChannel() {
        val owner = listOf(UpdateChannel.OWNER_CERTIFICATE)
        assertEquals(UpdateChannel.PRODUCTION, UpdateChannel.resolve(false, "dev.yab.android", owner, null))
        assertNull(UpdateChannel.resolve(false, "dev.yab.android", listOf("debugkey"), null))
        assertNull(UpdateChannel.resolve(false, "dev.yab.android", emptyList(), null))
        assertNull(UpdateChannel.resolve(false, "dev.yab.android.dev", owner, null))
        assertNull(UpdateChannel.resolve(true, "dev.yab.android", owner, null))
        assertNull(UpdateChannel.resolve(true, "dev.yab.android.dev", emptyList(), null))
    }

    @Test fun aReleaseNeverReadsTheDebugOverride() {
        assertEquals(UpdateChannel.PRODUCTION, UpdateChannel.resolve(false, "dev.yab.android", listOf(UpdateChannel.OWNER_CERTIFICATE), "http://10.0.2.2:8080"))
    }

    @Test fun aDebugFixtureIsLocalOnly() {
        val local = UpdateChannel.resolve(true, "dev.yab.android.dev", emptyList(), "http://10.0.2.2:8123")!!
        assertEquals("http://10.0.2.2:8123/android/latest.json", local.manifestUrl)
        assertNotNull(UpdateManifest.parse(json(url = "\"http://10.0.2.2:8123/n.apk\""), local))
        assertNull(UpdateManifest.parse(json(url = "\"http://10.0.2.2:9/n.apk\""), local))
        assertNull(UpdateChannel.resolve(true, "dev.yab.android.dev", emptyList(), "https://yetanotherbrowser.com"))
        assertNull(UpdateChannel.resolve(true, "dev.yab.android.dev", emptyList(), "nonsense"))
    }
}
