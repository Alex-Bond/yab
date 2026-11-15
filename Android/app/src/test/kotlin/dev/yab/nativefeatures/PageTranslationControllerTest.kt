package dev.yab.nativefeatures

import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import org.junit.Assert.*
import org.junit.Test

class PageTranslationControllerTest {
    private class Page : PageTranslationPort {
        var valid = true
        var applied: List<TranslationSegment>? = null
        var owner = TranslationOwner("tab", "navigation-1", true)
        override val current = MutableStateFlow<TranslationPage?>(null)
        var segments = listOf(TranslationSegment("node", "Bom dia"))
        var changed = false
        var target: String? = null
        var restores = 0
        var language = "pt"
        var beforeCollect: (suspend () -> Unit)? = null
        override suspend fun collect(): TranslationDocument {
            beforeCollect?.invoke()
            return TranslationDocument(owner, "Private page", language, segments.filter { source -> applied?.none { it.id == source.id } != false },
                "https://www.example.com/article", applied != null, target)
        }
        override fun isCurrent(owner: TranslationOwner) = valid && owner == this.owner
        override suspend fun begin(owner: TranslationOwner, target: String) { check(isCurrent(owner)); this.target = target }
        override suspend fun changed(owner: TranslationOwner): Boolean { check(isCurrent(owner)); return changed.also { changed = false } }
        override suspend fun apply(owner: TranslationOwner, translated: List<TranslationSegment>) { check(isCurrent(owner)); applied = applied.orEmpty() + translated }
        override suspend fun showOriginal(owner: TranslationOwner) { check(isCurrent(owner)); applied = null; target = null; restores++ }
        fun visible() { current.value = TranslationPage(owner, "https://www.example.com/article") }
    }
    private class Runtime(private val onTranslate: () -> Unit = {}) : TranslationRuntime {
        var ready = false
        var downloads = 0
        override suspend fun identify(text: String) = "pt"
        override suspend fun modelsReady(source: String, target: String) = ready
        override suspend fun download(source: String, target: String) { downloads++; ready = true }
        override suspend fun translate(source: String, target: String, text: List<String>): List<String> { onTranslate(); return text.map { "Good morning" } }
    }
    @Test fun menuProjectionRefreshesForANewDocumentWithExactlyTheSameVisibleWords() = runBlocking {
        val page = Page(); val controller = PageTranslationController(page, Runtime())
        val observer = launch { controller.observe("en") }
        try {
            page.visible(); val first = withTimeout(2000) { controller.menu.first { it != null } }!!
            page.owner = page.owner.copy(document = "same-url-new-document"); page.visible()
            val second = withTimeout(2000) { controller.menu.first { it?.owner == page.owner } }!!
            assertEquals(first.page, second.page); assertEquals(first.url, second.url)
            assertNotEquals(first.revision, second.revision)
            assertFalse(controller.toggleFromMenu(first)); assertTrue(controller.toggleFromMenu(second))
            assertEquals(TranslationPhase.NEED_MODEL, controller.state.value.phase)
        } finally { observer.cancelAndJoin() }
    }
    @Test fun anOldAlwaysRowCannotReturnAfterItsCheckedStateCycles() = runBlocking {
        val page = Page(); val rules = MemoryTranslationRules(); val controller = PageTranslationController(page, Runtime(), rules)
        val observer = launch { controller.observe("en") }
        try {
            page.visible(); val first = withTimeout(2000) { controller.menu.first { it != null } }!!
            assertTrue(controller.alwaysFromMenu(first, false))
            assertTrue(controller.alwaysFromMenu(checkNotNull(controller.captureMenu()), false))
            val current = checkNotNull(controller.captureMenu())
            assertEquals(first.page, current.page); assertEquals(first.generation, current.generation)
            assertFalse(controller.alwaysFromMenu(first, false)); assertNull(rules.source("example.com", true))
        } finally { observer.cancelAndJoin() }
    }
    @Test fun menuKeepsTheOriginalDocumentAndRequiresAnExplicitModelDownload() = runBlocking {
        val page = Page(); val runtime = Runtime(); val controller = PageTranslationController(page, runtime)
        val observer = launch { controller.observe("en") }
        try {
            page.visible(); withTimeout(2000) { controller.state.first { it.source == "pt" } }
            val offered = checkNotNull(controller.captureMenu())
            assertTrue(controller.toggleFromMenu(offered))
            assertEquals(TranslationPhase.NEED_MODEL, controller.state.value.phase)
            assertEquals(0, runtime.downloads); assertNull(page.applied)
            assertFalse("An old Translate row became Show Original", controller.toggleFromMenu(offered))
            assertTrue(controller.toggleFromMenu(checkNotNull(controller.captureMenu())))
            assertEquals(TranslationPhase.ORIGINAL, controller.state.value.phase)
            assertEquals(0, runtime.downloads)
            page.owner = page.owner.copy(document = "replacement")
            assertFalse(controller.alwaysFromMenu(offered)); assertNull(controller.captureMenu())
        } finally { observer.cancelAndJoin() }
    }
    @Test fun collectedReplacementCannotBorrowTheMenusTranslationRequest() = runBlocking {
        val page = Page(); val runtime = Runtime().apply { ready = true }; val controller = PageTranslationController(page, runtime)
        val observer = launch { controller.observe("en") }
        try {
            page.visible(); withTimeout(2000) { controller.state.first { it.source == "pt" } }
            val offered = checkNotNull(controller.captureMenu())
            val entered = CompletableDeferred<Unit>(); val finish = CompletableDeferred<Unit>()
            page.beforeCollect = { entered.complete(Unit); finish.await() }
            val action = launch { assertTrue(controller.toggleFromMenu(offered)) }
            entered.await(); page.owner = page.owner.copy(tabId = "another-tab", document = "another-document")
            finish.complete(Unit); action.join()
            assertNull("A delayed original menu translated the replacement", page.applied)
            assertNull(page.target); assertEquals(0, runtime.downloads)
        } finally { observer.cancelAndJoin() }
    }
    @Test fun policyOnlyChoiceStoresTheRuleWithoutStartingTranslation() = runBlocking {
        val page = Page(); val runtime = Runtime().apply { ready = true }; val rules = MemoryTranslationRules()
        val controller = PageTranslationController(page, runtime, rules)
        val observer = launch { controller.observe("en") }
        try {
            page.visible(); withTimeout(2000) { controller.state.first { it.source == "pt" } }
            val offered = checkNotNull(controller.captureMenu())
            assertTrue(controller.alwaysFromMenu(offered, translateNow = false))
            assertEquals("pt", rules.source("example.com", true)); assertNull(page.applied)
            assertTrue(checkNotNull(controller.captureMenu()).page.always)
            assertFalse("A saved old row toggled the newer checked row", controller.alwaysFromMenu(offered))
        } finally { observer.cancelAndJoin() }
    }
    @Test fun noTranslateRowIsOfferedForTheReadersOwnLanguage() = runBlocking {
        val page = Page().apply { language = "en" }
        val controller = PageTranslationController(page, Runtime())
        val observer = launch { controller.observe("en") }
        try {
            page.visible(); withTimeout(2000) { controller.state.first { it.source == "en" } }
            assertNull(controller.captureMenu())
        } finally { observer.cancelAndJoin() }
    }
    @Test fun modelDownloadRequiresAnExplicitConfirmationAndOriginalCanBeRestored() = runBlocking {
        val page = Page(); val runtime = Runtime(); val controller = PageTranslationController(page, runtime)
        controller.translate("en")
        assertEquals(TranslationPhase.NEED_MODEL, controller.state.value.phase)
        assertEquals(0, runtime.downloads)
        assertNull(page.applied)
        controller.confirmDownload()
        assertEquals(1, runtime.downloads)
        assertEquals("Good morning", page.applied!!.single().text)
        controller.showOriginal()
        assertNull(page.applied)
    }
    @Test fun navigationDuringTranslationMakesPreparedResultsInert() = runBlocking {
        val page = Page(); val runtime = Runtime { page.valid = false }.apply { ready = true }
        val controller = PageTranslationController(page, runtime)
        controller.translate("en")
        assertNull(page.applied)
        assertEquals(TranslationPhase.FAILED, controller.state.value.phase)
    }
    @Test fun oldDownloadConfirmationCannotBorrowANewPage() = runBlocking {
        val page = Page(); val runtime = Runtime(); val controller = PageTranslationController(page, runtime)
        controller.translate("en")
        page.valid = false
        controller.confirmDownload()
        assertEquals(0, runtime.downloads)
        assertNull(page.applied)
    }
    @Test fun selectedDynamicNodesCatchUpWithoutTranslatingTheSameNodesAgainAndFailureRestores() = runBlocking {
        val page = Page()
        var calls = 0
        var fail = false
        val runtime = object : TranslationRuntime {
            override suspend fun identify(text: String) = "pt"
            override suspend fun modelsReady(source: String, target: String) = true
            override suspend fun download(source: String, target: String) = error("No download was authorized")
            override suspend fun translate(source: String, target: String, text: List<String>): List<String> {
                calls++; check(!fail) { "The local model failed" }; return text.map { "English: $it" }
            }
        }
        val controller = PageTranslationController(page, runtime, pollMillis = 20)
        val observer = launch { controller.observe("en") }
        try {
            page.visible()
            withTimeout(2000) { controller.state.first { it.source == "pt" } }
            controller.translate("en")
            assertEquals(1, calls)
            delay(100)
            assertEquals("Own translation mutations were retranslated", 1, calls)
            page.segments += TranslationSegment("new", "Novo comentário")
            page.changed = true
            withTimeout(2000) { while (page.applied?.size != 2) delay(10) }
            assertEquals(2, calls)
            fail = true; page.segments += TranslationSegment("fail", "Mais palavras"); page.changed = true
            withTimeout(2000) { controller.state.first { it.phase == TranslationPhase.FAILED } }
            assertNull("Catch-up failure left a half-translated page", page.applied)
            assertTrue(page.restores > 0)
        } finally { observer.cancelAndJoin() }
    }
    @Test fun alwaysRulePersistsAcrossDocumentsWhileOriginalSuppressesOnlyTheCurrentDocument() = runBlocking {
        val page = Page(); val runtime = Runtime().apply { ready = true }; val rules = MemoryTranslationRules()
        val controller = PageTranslationController(page, runtime, rules, pollMillis = 20)
        val observer = launch { controller.observe("en") }
        try {
            page.visible(); withTimeout(2000) { controller.state.first { it.source == "pt" } }
            controller.setAlways(true)
            assertEquals("pt", rules.source("example.com", true))
            assertNotNull(page.applied)
            controller.setAlways(false)
            assertNotNull("Turning off Always changed the document", page.applied)
            controller.setAlways(true)
            controller.showOriginal()
            assertEquals("pt", rules.source("example.com", true))
            delay(100); assertNull("Original was automatically translated again", page.applied)
            page.current.value = null; delay(30)
            page.visible(); delay(100)
            assertNull("Returning to the same document lost Original suppression", page.applied)
            page.owner = page.owner.copy(document = "navigation-2"); page.visible()
            withTimeout(2000) { controller.state.first { it.phase == TranslationPhase.TRANSLATED } }
            assertNotNull(page.applied)
            assertNull(rules.source("example.com", false))
        } finally { observer.cancelAndJoin() }
    }
    @Test fun alwaysNeverDownloadsModelsAndAnInFlightDownloadCannotApplyToANewDocument() = runBlocking {
        val page = Page(); val rules = MemoryTranslationRules().apply { setSource("example.com", true, "pt") }
        val started = CompletableDeferred<Unit>(); val finish = CompletableDeferred<Unit>(); var downloads = 0
        val runtime = object : TranslationRuntime {
            override suspend fun identify(text: String) = "pt"
            override suspend fun modelsReady(source: String, target: String) = false
            override suspend fun download(source: String, target: String) { downloads++; started.complete(Unit); finish.await() }
            override suspend fun translate(source: String, target: String, text: List<String>) = text.map { "English" }
        }
        val controller = PageTranslationController(page, runtime, rules, pollMillis = 20)
        val observer = launch { controller.observe("en") }
        try {
            page.visible(); withTimeout(2000) { controller.state.first { it.source == "pt" } }; delay(60)
            assertEquals(0, downloads); assertNull(page.applied)
            controller.translate("en")
            val download = launch { controller.confirmDownload() }
            withTimeout(2000) { started.await() }
            page.owner = page.owner.copy(document = "navigation-2"); page.visible(); delay(60)
            finish.complete(Unit); download.join()
            assertEquals(1, downloads); assertNull(page.applied)
        } finally { finish.complete(Unit); observer.cancelAndJoin() }
    }
    @Test fun changingTheTargetInvalidatesOldModelResultsAndRestoresBeforeTheNextLanguage() = runBlocking {
        val page = Page(); val started = CompletableDeferred<Unit>(); val finish = CompletableDeferred<Unit>()
        val runtime = object : TranslationRuntime {
            override suspend fun identify(text: String) = "pt"
            override suspend fun modelsReady(source: String, target: String) = true
            override suspend fun download(source: String, target: String) = Unit
            override suspend fun translate(source: String, target: String, text: List<String>): List<String> {
                if (target == "en") { started.complete(Unit); finish.await() }; return text.map { "$target result" }
            }
        }
        val controller = PageTranslationController(page, runtime, pollMillis = 20)
        var observer = launch { controller.observe("en") }
        try {
            page.visible(); withTimeout(2000) { controller.state.first { it.source == "pt" } }
            val old = launch { controller.translate("en") }; withTimeout(2000) { started.await() }
            observer.cancelAndJoin(); observer = launch { controller.observe("fr") }
            withTimeout(2000) { controller.state.first { it.target == "fr" } }
            finish.complete(Unit); old.join()
            assertNull("The English result crossed the target boundary", page.applied)
            controller.translate("fr")
            assertEquals("fr result", page.applied!!.single().text)
            observer.cancelAndJoin(); observer = launch { controller.observe("de") }
            withTimeout(2000) { controller.state.first { it.target == "de" } }
            assertNull("Changing target retained the previous translated DOM", page.applied)
            assertTrue(page.restores > 0)
        } finally { finish.complete(Unit); observer.cancelAndJoin() }
    }
    @Test fun lateOriginalAcknowledgmentCannotOverwriteANewerTranslation() = runBlocking {
        val page = Page(); val started = CompletableDeferred<Unit>(); val finish = CompletableDeferred<Unit>()
        val port = object : PageTranslationPort by page {
            override suspend fun showOriginal(owner: TranslationOwner) {
                page.showOriginal(owner); started.complete(Unit); finish.await()
            }
        }
        val controller = PageTranslationController(port, Runtime().apply { ready = true })
        controller.translate("en")
        val original = launch { controller.showOriginal() }
        try {
            withTimeout(2000) { started.await() }
            controller.translate("fr")
            finish.complete(Unit); original.join()
            assertEquals(TranslationPhase.TRANSLATED, controller.state.value.phase)
            assertEquals("fr", controller.state.value.target)
            assertNotNull(page.applied)
        } finally { finish.complete(Unit); original.cancelAndJoin() }
    }
}
