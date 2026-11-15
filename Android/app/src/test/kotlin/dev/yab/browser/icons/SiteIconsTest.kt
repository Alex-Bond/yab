package dev.yab.browser.icons

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class SiteIconsTest {
    @Test fun originsRetainSchemeAndEffectivePortAndNeverAcceptCredentialsOrExternalDeclaredIcons() {
        val https = SiteIconOrigin.from("https://EXAMPLE.test:443/path?q=secret")!!
        assertEquals("https://example.test", https.address)
        assertNotEquals(https, SiteIconOrigin.from("http://example.test"))
        assertNotEquals(https, SiteIconOrigin.from("https://example.test:444"))
        assertEquals("http://[::1]:8080", SiteIconOrigin.from("http://[::1]:8080/path")!!.address)
        for (bad in listOf("https://u:p@example.test", "https://@example.test", "data:image/png,abc", "file:///tmp/icon", "//example.test", "about:blank"))
            assertNull(bad, SiteIconOrigin.from(bad))
        assertEquals(listOf("https://cdn.other.test/icon.png", "https://example.test/favicon.ico"), https.candidates("https://cdn.other.test/icon.png"))
        assertEquals(listOf("https://example.test/favicon.ico"), https.candidates("http://other.test/icon.png"))
        assertEquals(listOf("https://example.test/custom.png", "https://example.test/favicon.ico"), https.candidates("https://example.test/custom.png"))
    }

    @Test fun aHomePageNamesItsIconsTheTouchIconFirstAndNoSvg() {
        val origin = SiteIconOrigin.from("https://site.test/page")!!
        val html = """<head><link rel="stylesheet" href="/a.css"><link rel="icon" href="/small.png">
            <link href="x" rel="mask-icon"><link rel='shortcut icon' href='https://cdn.test/s.ico?a=1&amp;b=2'>
            <LINK REL="apple-touch-icon" HREF=/touch.png><link rel="icon" href="/vector.svg"><link rel="icon" href="http://plain.test/i.png"></head>"""
        assertEquals(listOf("https://site.test/touch.png", "https://site.test/small.png", "https://site.test/x", "https://cdn.test/s.ico?a=1&b=2"),
            origin.declaredIcons(html))
    }

    @Test fun aRootWithoutAnIconAsksTheHomePageAndWhatIsTakenIsKept(): Unit = runTest {
        val fetched = mutableListOf<String>()
        val kept = mutableListOf<Pair<SiteIconOrigin, ByteArray>>()
        val icons = SiteIconRepository<Any>(backgroundScope, { url, _ -> fetched.add(url); if (url.endsWith("touch.png")) byteArrayOf(9) else null },
            { Any() }, { testScheduler.currentTime }, discover = { listOf("https://cdn.test/gone.png", "https://cdn.test/touch.png") },
            keep = { origin, bytes -> kept += origin to bytes })
        assertTrue(icons.load("https://site.test/page", null, false))
        assertEquals(listOf("https://site.test/favicon.ico", "https://cdn.test/gone.png", "https://cdn.test/touch.png"), fetched)
        assertEquals(SiteIconOrigin.from("https://site.test"), kept.single().first)
        assertFalse(icons.load("http://plain.test/page", null, false))
        assertEquals("https://plain site has no home page look", "http://plain.test/favicon.ico", fetched.last())
    }

    @Test fun iconsFromEarlierLaunchesNeverReplaceOneAlreadyHere(): Unit = runTest {
        val origin = SiteIconOrigin.from("https://site.test")!!
        val icons = SiteIconRepository(backgroundScope, { _, _ -> byteArrayOf(1) }, { "fresh" }, { testScheduler.currentTime })
        icons.restore(mapOf(origin to "kept"))
        assertEquals("kept", icons.image("https://site.test/page", false))
        assertTrue(icons.load("https://site.test/page", null, false))
        icons.restore(mapOf(origin to "older"))
        assertEquals("kept", icons.image("https://site.test/page", false))
        assertNull(icons.image("https://site.test/page", true))
    }

    @Test fun privateCannotReadPublicImageOrCreateARequestAndRootFailuresHaveThirtySecondBackoff(): Unit = runTest {
        val fetched = mutableListOf<String>()
        var succeeds = true
        val icons = SiteIconRepository(backgroundScope, { url, _ -> fetched.add(url); if (succeeds) byteArrayOf(7) else null }, { Any() }, { testScheduler.currentTime })
        assertTrue(icons.load("https://site.test/page", null, false))
        val first = icons.image("https://site.test/other", false)
        assertNotNull(first); assertNull(icons.image("https://site.test/page", true))
        assertFalse(icons.load("https://private.test/page", null, true))
        assertEquals(1, fetched.size)
        succeeds = false
        assertFalse(icons.load("https://failure.test/page", null, false))
        assertFalse(icons.load("https://failure.test/other", null, false)); assertEquals(2, fetched.size)
        advanceTimeBy(30_001)
        assertFalse(icons.load("https://failure.test/page", null, false)); assertEquals(3, fetched.size)
    }

    @Test fun aLateDeclaredIconJoinsTheColdRequestThenTriesItsOwnSameOriginCandidate(): Unit = runTest {
        val cold = CompletableDeferred<ByteArray?>()
        val fetched = mutableListOf<String>()
        val icons = SiteIconRepository(backgroundScope, { url, _ ->
            fetched.add(url); if (url.endsWith("favicon.ico")) cold.await() else byteArrayOf(8)
        }, { "decoded" }, { testScheduler.currentTime })
        val first = async { icons.load("https://site.test/page", null, false) }
        runCurrent()
        val declared = async { icons.load("https://site.test/page", "https://site.test/custom.png", false) }
        runCurrent(); assertEquals(1, fetched.size)
        cold.complete(null); advanceUntilIdle()
        assertFalse(first.await()); assertTrue(declared.await())
        assertEquals(listOf("https://site.test/favicon.ico", "https://site.test/custom.png"), fetched)
    }

    @Test fun clearingCancelsInflightPicturesAndTheirLateResultCannotRepopulateOrSpendANewLease(): Unit = runTest {
        val reply = CompletableDeferred<ByteArray>()
        var calls = 0
        val icons = SiteIconRepository(backgroundScope, { _, _ ->
            calls++; if (calls == 1) withContext(NonCancellable) { reply.await() } else byteArrayOf(2)
        }, { Any() })
        val old = async { runCatching { icons.load("https://site.test/page", null, false) } }
        runCurrent(); icons.removeAll(); reply.complete(byteArrayOf(1)); runCurrent()
        assertTrue(old.await().isFailure); assertNull(icons.image("https://site.test/page", false))
        assertTrue(icons.load("https://site.test/page", null, false)); assertEquals(2, calls)
    }

    @Test fun networkIsFourWideAndOversizedPayloadsCannotEnterTheRamCache(): Unit = runTest {
        val release = CompletableDeferred<Unit>(); var active = 0; var peak = 0
        val icons = SiteIconRepository(backgroundScope, { _, _ ->
            active++; peak = maxOf(active, peak); try { release.await(); byteArrayOf(1) } finally { active-- }
        }, { Any() })
        val requests = (1..9).map { index -> async { icons.load("https://s$index.test/page", null, false) } }
        runCurrent(); assertEquals(4, active); release.complete(Unit)
        assertTrue(requests.awaitAll().all { it }); assertEquals(4, peak)
        var decodes = 0
        val large = SiteIconRepository(backgroundScope, { _, _ -> ByteArray(1_048_577) }, { decodes++; Any() })
        assertFalse(large.load("https://site.test", null, false)); assertEquals(0, decodes)
    }

    @Test fun nativeMenuRebuildsReuseTheSameRasterAndOneLateSourceChangeReplacesIt() {
        val cache = TabIconRenderCache<Any>(); val firstSource = Any(); val later = Any()
        val first = cache.image("site|public|20|3", firstSource) { Any() }
        repeat(60) { assertSame(first, cache.image("site|public|20|3", firstSource) { error("Repeated menu render") }) }
        assertEquals(1, cache.renders)
        assertNotSame(first, cache.image("site|public|20|3", later) { Any() }); assertEquals(2, cache.renders)
        cache.image("site|private|20|3", null) { Any() }; cache.image("site|public|20|2", later) { Any() }
        assertEquals(4, cache.renders)
    }
}
