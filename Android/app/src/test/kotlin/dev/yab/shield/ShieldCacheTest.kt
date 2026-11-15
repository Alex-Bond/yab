package dev.yab.shield

import java.io.File
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.test.runTest
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test

class ShieldCacheTest {
    @Test fun failedInsecureOrMalformedUpdatesKeepLastWorkingTextAndNeverUseCookies() = runTest {
        val directory = java.nio.file.Files.createTempDirectory("shield-cache").toFile()
        val source = ShieldSource("fixture", "https://filters.example/list.txt", 4)
        var body = "! fixture\n||ads.example^\n"; var redirect: String? = null
        val requests = AtomicInteger()
        val http = OkHttpClient.Builder().addInterceptor { chain ->
            requests.incrementAndGet(); assertNull(chain.request().header("Cookie")); assertNull(chain.request().header("Authorization"))
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(if (redirect == null) 200 else 302).message("Fixture")
                .header("Set-Cookie", "private=must-not-be-reused")
                .apply { redirect?.let { header("Location", it) } }
                .body(body.toResponseBody("text/plain".toMediaType())).build()
        }.build()
        try {
            val cache = ShieldListCache(directory, http)
            assertTrue(cache.refresh(source, explicit = true).cached)
            val good = File(directory, "fixture.txt").readBytes()
            body = "bad"; assertNotNull(cache.refresh(source, explicit = true).error); assertArrayEquals(good, File(directory, "fixture.txt").readBytes())
            body = "x".repeat(4096) + "\n"; assertNotNull(cache.refresh(source, explicit = true).error)
            redirect = "http://filters.example/insecure"; val count = requests.get()
            assertNotNull(cache.refresh(source, explicit = true).error); assertEquals(count + 1, requests.get())
            assertArrayEquals(good, File(directory, "fixture.txt").readBytes())
            assertEquals("! fixture\n||ads.example^\n", cache.read(source))
            assertFalse(File(directory, "fixture.pending").exists())
        } finally { directory.deleteRecursively() }
    }
    @Test fun weeklyCacheAndMeteredNetworkAvoidAutomaticDownloads() = runTest {
        val directory = java.nio.file.Files.createTempDirectory("shield-freshness").toFile()
        val source = ShieldSource("fixture", "https://filters.example/list.txt", 4)
        val requests = AtomicInteger()
        val http = OkHttpClient.Builder().addInterceptor { chain -> requests.incrementAndGet()
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200).message("Fixture")
                .body("! fixture\n||ads.example^\n".toResponseBody()).build()
        }.build()
        try {
            val cache = ShieldListCache(directory, http)
            assertFalse(cache.refresh(source, metered = true).cached); assertEquals(0, requests.get())
            cache.refresh(source); assertEquals(1, requests.get())
            cache.refresh(source); assertEquals(1, requests.get())
            cache.refresh(source, explicit = true, metered = true); assertEquals(2, requests.get())
        } finally { directory.deleteRecursively() }
    }
}
