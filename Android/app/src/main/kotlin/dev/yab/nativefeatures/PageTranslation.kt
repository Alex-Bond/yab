package dev.yab.nativefeatures

import com.google.android.gms.tasks.Task
import com.google.mlkit.common.model.DownloadConditions
import com.google.mlkit.common.model.RemoteModelManager
import com.google.mlkit.nl.languageid.LanguageIdentification
import com.google.mlkit.nl.translate.TranslateLanguage
import com.google.mlkit.nl.translate.TranslateRemoteModel
import com.google.mlkit.nl.translate.Translation
import com.google.mlkit.nl.translate.TranslatorOptions
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

data class TranslationOwner(val tabId: String, val document: String, val privateOrigin: Boolean, val contentDocument: String? = null)
data class TranslationSegment(val id: String, val text: String)
data class TranslationDocument(val owner: TranslationOwner, val title: String, val language: String?, val segments: List<TranslationSegment>,
    val url: String? = null, val translated: Boolean = false, val targetLanguage: String? = null)
data class TranslationPage(val owner: TranslationOwner, val url: String)

/** Engine code owns DOM identity and must refuse writes after navigation, replacement or privacy change. */
interface PageTranslationPort {
    val current: StateFlow<TranslationPage?> get() = emptyTranslationPage
    suspend fun collect(): TranslationDocument
    fun isCurrent(owner: TranslationOwner): Boolean
    suspend fun begin(owner: TranslationOwner, target: String) {}
    suspend fun changed(owner: TranslationOwner): Boolean = false
    suspend fun apply(owner: TranslationOwner, translated: List<TranslationSegment>)
    suspend fun showOriginal(owner: TranslationOwner)
}
private val emptyTranslationPage = MutableStateFlow<TranslationPage?>(null)

interface TranslationRuntime {
    suspend fun identify(text: String): String?
    suspend fun modelsReady(source: String, target: String): Boolean
    suspend fun download(source: String, target: String)
    suspend fun translate(source: String, target: String, text: List<String>): List<String>
}

class MlKitTranslationRuntime : TranslationRuntime {
    override suspend fun identify(text: String): String? {
        val identifier = LanguageIdentification.getClient()
        return try { identifier.identifyLanguage(text.take(5000)).awaitResult().takeUnless { it == "und" } }
        finally { identifier.close() }
    }
    override suspend fun modelsReady(source: String, target: String): Boolean {
        val manager = RemoteModelManager.getInstance()
        for (language in setOf(source, target).filterNot { it == TranslateLanguage.ENGLISH }) {
            if (!manager.isModelDownloaded(TranslateRemoteModel.Builder(language).build()).awaitResult()) return false
        }
        return true
    }
    override suspend fun download(source: String, target: String) {
        val translator = Translation.getClient(TranslatorOptions.Builder().setSourceLanguage(source).setTargetLanguage(target).build())
        try { translator.downloadModelIfNeeded(DownloadConditions.Builder().requireWifi().build()).awaitResult() }
        finally { translator.close() }
    }
    override suspend fun translate(source: String, target: String, text: List<String>): List<String> {
        val translator = Translation.getClient(TranslatorOptions.Builder().setSourceLanguage(source).setTargetLanguage(target).build())
        return try { text.map { if (it.isBlank()) it else translator.translate(it).awaitResult() } }
        finally { translator.close() }
    }
}

enum class TranslationPhase { ORIGINAL, READING, NEED_MODEL, DOWNLOADING, TRANSLATING, TRANSLATED, FAILED }
data class PageTranslationState(val phase: TranslationPhase = TranslationPhase.ORIGINAL, val source: String? = null, val target: String? = null,
    val error: String? = null, val host: String? = null, val always: Boolean = false)

/** One rendered menu's original local document and translator session. Never persisted or synced. */
data class TranslationMenuLease internal constructor(val page: PageTranslationState, val url: String,
    internal val owner: TranslationOwner, internal val session: Any, internal val generation: Long,
    internal val revision: Long)

/** Splits long text without dropping original bytes; one node's translated pieces are joined before apply. */
object TranslationBatching {
    data class Piece(val id: String, val text: String, val prefix: String = "", val suffix: String = "")
    fun pieces(segments: List<TranslationSegment>, maxCharacters: Int = 2500): List<Piece> {
        require(maxCharacters > 0)
        require(segments.map { it.id }.toSet().size == segments.size) { "Duplicate page node identity" }
        return segments.flatMap { segment ->
            val pieces = mutableListOf<Piece>()
            var offset = 0
            while (offset < segment.text.length) {
                var end = minOf(offset + maxCharacters, segment.text.length)
                if (end < segment.text.length && end > offset && segment.text[end - 1].isHighSurrogate() && segment.text[end].isLowSurrogate()) end--
                if (end == offset) end = minOf(offset + 2, segment.text.length)
                if (end < segment.text.length) {
                    val space = segment.text.lastIndexOf(' ', end - 1)
                    if (space > offset + maxCharacters / 2) end = space + 1
                }
                val part = segment.text.substring(offset, end)
                val leading = part.takeWhile(Char::isWhitespace)
                val trailing = part.drop(leading.length).takeLastWhile(Char::isWhitespace)
                pieces += Piece(segment.id, part.substring(leading.length, part.length - trailing.length), leading, trailing)
                offset = end
            }
            if (pieces.isEmpty()) pieces += Piece(segment.id, "")
            pieces
        }
    }
    fun combine(pieces: List<Piece>, translated: List<String>): List<TranslationSegment> {
        require(pieces.size == translated.size) { "Translation returned a different number of page nodes" }
        return pieces.indices.groupBy { pieces[it].id }.map { (id, indices) -> TranslationSegment(id, indices.joinToString("") { pieces[it].prefix + translated[it] + pieces[it].suffix }) }
    }
}

class PageTranslationController(private val port: PageTranslationPort, private val runtime: TranslationRuntime = MlKitTranslationRuntime(),
    private val rules: TranslationRuleStore = MemoryTranslationRules(), private val pollMillis: Long = 1500) {
    private val mutable = MutableStateFlow(PageTranslationState())
    val state: StateFlow<PageTranslationState> = mutable
    private val menuMutable = MutableStateFlow<TranslationMenuLease?>(null)
    val menu: StateFlow<TranslationMenuLease?> = menuMutable
    private var menuRevision = 0L
    private var generation = 0L
    private data class Pending(val document: TranslationDocument, val source: String, val target: String, val generation: Long)
    private var pending: Pending? = null
    private data class Session(val owner: TranslationOwner, val source: String, val target: String, val host: String?,
        var translated: Boolean = false, var suppressed: Boolean = false, var phase: TranslationPhase = TranslationPhase.ORIGINAL,
        var error: String? = null, var always: Boolean = false)
    private val sessions = mutableMapOf<String, Session>()
    private var selected: TranslationOwner? = null
    private var targetLanguage: String? = null
    private val ruleWrites = Mutex()

    fun captureMenu(): TranslationMenuLease? {
        val owner = selected ?: return null
        val session = sessions[owner.tabId]?.takeIf { it.owner == owner } ?: return null
        val page = mutable.value
        if (!port.isCurrent(owner) || page.source == null || page.target == null || page.source == page.target) return null
        val url = port.current.value?.takeIf { it.owner == owner }?.url ?: return null
        return TranslationMenuLease(page, url, owner, session, generation, menuRevision)
    }
    private fun refreshMenu() {
        val next = captureMenu()
        if (next == menuMutable.value) return
        ++menuRevision
        menuMutable.value = next?.copy(revision = menuRevision)
    }
    fun menuDocumentCurrent(lease: TranslationMenuLease): Boolean = selected == lease.owner &&
        sessions[lease.owner.tabId] === lease.session && port.isCurrent(lease.owner)
    private fun menuCurrent(lease: TranslationMenuLease): Boolean = menuDocumentCurrent(lease) &&
        generation == lease.generation && menuRevision == lease.revision && mutable.value == lease.page
    suspend fun toggleFromMenu(lease: TranslationMenuLease): Boolean {
        if (!menuCurrent(lease)) return false
        if (lease.page.phase in setOf(TranslationPhase.ORIGINAL, TranslationPhase.FAILED))
            translateCurrent(checkNotNull(lease.page.target), lease.owner)
        else showOriginal()
        return true
    }
    suspend fun alwaysFromMenu(lease: TranslationMenuLease, translateNow: Boolean = true): Boolean {
        if (!menuCurrent(lease)) return false
        setAlways(!lease.page.always, translateNow)
        return true
    }

    /** Binding lives outside the dialog. Only the selected live document is polled. */
    suspend fun observe(target: String, enabled: Boolean = true) {
        if (!enabled) { invalidate(); selected = null; mutable.value = PageTranslationState(); return }
        targetLanguage = target
        try {
            port.current.distinctUntilChanged { a, b -> a?.owner == b?.owner }.collectLatest { page ->
                invalidate(); selected = page?.owner
                if (page == null) { mutable.value = PageTranslationState(); return@collectLatest }
                sessions[page.owner.tabId]?.takeIf { it.owner != page.owner }?.let { sessions.remove(page.owner.tabId) }
                val turn = generation
                try {
                    val document = port.collect()
                    check(document.owner == page.owner) { "The page changed" }
                    val request = prepare(document, target, turn)
                    val session = sessions[page.owner.tabId] ?: return@collectLatest
                    publish(session)
                    if (session.always && !session.suppressed && !session.translated && request.source != request.target) {
                        // An Always rule authorizes local translation, never an unattended download.
                        if (runtime.modelsReady(request.source, request.target)) {
                            checkCurrent(page.owner, turn)
                            perform(request)
                        }
                    }
                } catch (cancelled: CancellationException) { throw cancelled }
                catch (error: Exception) { if (turn == generation && port.isCurrent(page.owner)) fail(page.owner, error) }
                while (true) {
                    delay(pollMillis)
                    if (!port.isCurrent(page.owner)) return@collectLatest
                    val current = sessions[page.owner.tabId] ?: return@collectLatest
                    if (current.owner != page.owner || !current.translated || current.phase != TranslationPhase.TRANSLATED) continue
                    try {
                        val changed = port.changed(page.owner)
                        if (changed && current.phase == TranslationPhase.TRANSLATED && current.translated && selected == page.owner) catchUp(current)
                    } catch (cancelled: CancellationException) { throw cancelled }
                    catch (error: Exception) { if (port.isCurrent(page.owner)) fail(page.owner, error) }
                }
            }
        } finally { invalidate(); selected = null; mutable.value = PageTranslationState() }
    }

    suspend fun translate(targetLanguage: String) = translateCurrent(targetLanguage, null)

    private suspend fun translateCurrent(targetLanguage: String, expectedOwner: TranslationOwner?) {
        val turn = ++generation
        pending = null
        this.targetLanguage = targetLanguage
        mutable.value = if (expectedOwner == null) PageTranslationState(TranslationPhase.READING)
            else mutable.value.copy(phase = TranslationPhase.READING, error = null)
        refreshMenu()
        try {
            val document = port.collect()
            if (expectedOwner != null && document.owner != expectedOwner) {
                if (turn == generation) { mutable.value = PageTranslationState(); refreshMenu() }
                return
            }
            selected = document.owner
            val request = prepare(document, targetLanguage, turn)
            val session = sessions.getValue(document.owner.tabId)
            session.suppressed = false
            if (request.source == request.target) { publish(session); return }
            require(document.segments.isNotEmpty() || document.translated) { "There is no page text to translate" }
            val ready = runtime.modelsReady(request.source, request.target)
            checkCurrent(document.owner, turn)
            if (!ready) {
                pending = request
                session.phase = TranslationPhase.NEED_MODEL; publish(session)
            } else perform(request)
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (error: Exception) { if (turn == generation) fail(selected, error) }
    }

    private suspend fun prepare(document: TranslationDocument, targetLanguage: String, turn: Long): Pending {
        checkCurrent(document.owner, turn)
        val existing = sessions[document.owner.tabId]?.takeIf { it.owner == document.owner }
        val source = existing?.source ?: document.language?.let(::translationLanguage)
            ?: runtime.identify(document.segments.joinToString(" ") { it.text }.take(5000))?.let(::translationLanguage)
            ?: throw IllegalArgumentException("This page's language could not be identified")
        val target = translationLanguage(targetLanguage) ?: throw IllegalArgumentException("The selected language is not supported on this device")
        checkCurrent(document.owner, turn)
        val host = document.url?.let(::translationHost)
        val always = if (host != null) withContext(Dispatchers.IO) { rules.source(host, document.owner.privateOrigin) == source } else false
        checkCurrent(document.owner, turn)
        if (existing != null && existing.target != target && (existing.translated || document.translated)) {
            port.showOriginal(document.owner)
            checkCurrent(document.owner, turn)
        }
        val session = if (existing != null && existing.target == target) existing else Session(document.owner, source, target, host,
            translated = document.translated && document.targetLanguage == target)
        session.always = always
        session.phase = if (session.translated) TranslationPhase.TRANSLATED else TranslationPhase.ORIGINAL
        session.error = null
        sessions[document.owner.tabId] = session
        return Pending(document, source, target, turn)
    }

    /** Called only by the visible language-download confirmation. Translation text never goes to the download API. */
    suspend fun confirmDownload() {
        val request = pending ?: return
        try {
            checkCurrent(request.document.owner, request.generation)
            sessions[request.document.owner.tabId]?.let { it.phase = TranslationPhase.DOWNLOADING; publish(it) }
            runtime.download(request.source, request.target)
            checkCurrent(request.document.owner, request.generation)
            pending = null
            perform(request)
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (error: Exception) { if (request.generation == generation) fail(request.document.owner, error) }
    }

    private suspend fun perform(request: Pending) {
        checkCurrent(request.document.owner, request.generation)
        val session = sessions.getValue(request.document.owner.tabId)
        session.phase = TranslationPhase.TRANSLATING; publish(session)
        port.begin(request.document.owner, request.target)
        checkCurrent(request.document.owner, request.generation)
        val fresh = port.collect()
        check(fresh.owner == request.document.owner) { "The page changed" }
        checkCurrent(request.document.owner, request.generation)
        val pieces = TranslationBatching.pieces(fresh.segments)
        val outputs = mutableListOf<String>()
        for (batch in pieces.chunked(24)) {
            outputs += runtime.translate(request.source, request.target, batch.map { it.text })
            checkCurrent(request.document.owner, request.generation)
        }
        if (pieces.isNotEmpty()) port.apply(request.document.owner, TranslationBatching.combine(pieces, outputs))
        checkCurrent(request.document.owner, request.generation)
        session.translated = true; session.phase = TranslationPhase.TRANSLATED; session.error = null; publish(session)
    }
    private suspend fun catchUp(session: Session) {
        val turn = ++generation
        try {
            val document = port.collect()
            check(document.owner == session.owner) { "The page changed" }
            checkCurrent(session.owner, turn)
            if (document.segments.isEmpty()) return
            perform(Pending(document, session.source, session.target, turn))
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (error: Exception) { if (turn == generation) fail(session.owner, error) }
    }
    suspend fun showOriginal() {
        val turn = ++generation; pending = null
        val owner = selected ?: return
        sessions[owner.tabId]?.takeIf { it.owner == owner }?.let {
            it.translated = false; it.suppressed = true; it.phase = TranslationPhase.ORIGINAL; it.error = null; publish(it)
        }
        try { if (port.isCurrent(owner)) port.showOriginal(owner) }
        catch (cancelled: CancellationException) { throw cancelled }
        catch (error: Exception) { if (turn == generation && selected == owner && port.isCurrent(owner)) {
            mutable.value = mutable.value.copy(error = error.message); refreshMenu()
        } }
    }
    suspend fun setAlways(enabled: Boolean, translateNow: Boolean = true) {
        val owner = selected ?: return
        val session = sessions[owner.tabId]?.takeIf { it.owner == owner } ?: return
        val host = session.host ?: return
        check(port.isCurrent(owner)) { "The page changed" }
        try {
            ruleWrites.withLock { withContext(Dispatchers.IO) { rules.setSource(host, owner.privateOrigin, if (enabled) session.source else null) } }
            if (!port.isCurrent(owner) || selected != owner || sessions[owner.tabId] !== session) return
            session.always = enabled; publish(session)
            if (enabled && translateNow && session.phase in setOf(TranslationPhase.ORIGINAL, TranslationPhase.FAILED)) translate(targetLanguage ?: session.target)
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (error: Exception) { if (selected == owner) {
            mutable.value = mutable.value.copy(error = error.message ?: "The translation rule could not be saved"); refreshMenu()
        } }
    }
    private suspend fun fail(owner: TranslationOwner?, error: Exception) {
        val session = owner?.let { sessions[it.tabId] }?.takeIf { it.owner == owner }
        if (session != null) {
            session.translated = false; session.suppressed = true; session.phase = TranslationPhase.FAILED
            session.error = error.message ?: "This page could not be translated"; publish(session)
        } else mutable.value = PageTranslationState(TranslationPhase.FAILED, error = error.message ?: "This page could not be translated")
        refreshMenu()
        if (owner != null && port.isCurrent(owner)) {
            try { port.showOriginal(owner) } catch (cancelled: CancellationException) { throw cancelled } catch (_: Exception) { /* The document may have gone. */ }
        }
    }
    private fun publish(session: Session) {
        if (selected == session.owner) {
            mutable.value = PageTranslationState(session.phase, session.source, session.target, session.error, session.host, session.always)
            refreshMenu()
        }
    }
    private fun invalidate() { ++generation; ++menuRevision; pending = null; menuMutable.value = null }
    fun cancel() { invalidate(); selected = null; mutable.value = PageTranslationState() }
    private fun checkCurrent(owner: TranslationOwner, turn: Long) {
        check(turn == generation && port.isCurrent(owner)) { "The page changed. Translate the current page again." }
    }
}

private suspend fun <T> Task<T>.awaitResult(): T = suspendCancellableCoroutine { continuation ->
    addOnSuccessListener { value -> if (continuation.isActive) continuation.resume(value) }
    addOnFailureListener { error -> if (continuation.isActive) continuation.resumeWithException(error) }
    addOnCanceledListener { continuation.cancel() }
}
