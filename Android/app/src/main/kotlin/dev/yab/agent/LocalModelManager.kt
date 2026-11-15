package dev.yab.agent

import android.content.Context
import android.net.Uri
import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import java.io.File
import java.security.MessageDigest
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import okhttp3.Call
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.concurrent.TimeUnit

data class LocalModelState(val ready: Boolean = false, val importing: Boolean = false, val bytes: Long = 0,
    val error: String? = null, val name: String? = null, val received: Long = 0, val total: Long = 0,
    val running: Boolean = false)

/** One file lease covers inference and atomic model replacement. Prompts never enter downloads. */
class LocalModelManager(context: Context, private val retainedScope: CoroutineScope? = null) {
    private val app = context.applicationContext
    private val folder = File(app.filesDir, "local-ai").apply { mkdirs() }
    val modelFile = File(folder, "model.litertlm")
    private val label = File(folder, "model.name")
    private val mutable = MutableStateFlow(current())
    val state: StateFlow<LocalModelState> = mutable
    private val lock = Mutex()
    @Volatile private var call: Call? = null
    @Volatile private var operation: Job? = null
    private var download: Job? = null
    private fun current(error: String? = null) = LocalModelState(ready = modelFile.isFile, bytes = modelFile.length(),
        name = runCatching { label.takeIf { it.isFile && it.length() < 512 }?.readText() }.getOrNull(), error = error)

    fun startDownload(model: LocalModelCatalog.Model, fallbackScope: CoroutineScope) {
        if (download?.isActive == true || mutable.value.importing || mutable.value.running) return
        download = (retainedScope ?: fallbackScope).launch { dev.yab.update.UpdateHolds.during { downloadModel(model) } }
    }
    fun cancelDownload() { download?.cancel(); operation?.cancel(); call?.cancel() }

    suspend fun <T> withInstalledModel(block: suspend (File) -> T): T {
        if (mutable.value.importing) throw AgentUnavailable("The model is downloading. Your question stayed on this device.")
        return lock.withLock {
            if (!modelFile.isFile) throw AgentUnavailable("Download an on-device model in AI settings. Your question stayed on this device.")
            mutable.value = mutable.value.copy(running = true)
            try { block(modelFile) } finally { mutable.value = mutable.value.copy(running = false) }
        }
    }

    suspend fun import(uri: Uri) = lock.withLock { withContext(Dispatchers.IO) {
        val temporary = try { File.createTempFile("import-", ".litertlm", folder) }
        catch (_: Exception) { mutable.value = current("Storage is unavailable. Free some space and try again."); return@withContext }
        val activeJob = currentCoroutineContext()[Job]; operation = activeJob
        mutable.value = current().copy(importing = true)
        try {
            val input = app.contentResolver.openInputStream(uri) ?: throw AgentUnavailable("The model could not be opened")
            input.use { source -> temporary.outputStream().use { output ->
                val buffer = ByteArray(1024 * 1024); var bytes = 0L
                while (true) {
                    currentCoroutineContext().ensureActive()
                    val read = source.read(buffer); if (read < 0) break
                    bytes += read
                    require(bytes <= 8L * 1024 * 1024 * 1024) { "Choose a model smaller than 8 GB" }
                    require(folder.usableSpace > read + 16L * 1024 * 1024) { "There is not enough storage for this model" }
                    output.write(buffer, 0, read)
                    mutable.value = mutable.value.copy(received = bytes)
                }
                require(bytes > 1024) { "This file is too small to be a language model" }; output.fd.sync()
            } }
            validate(temporary)
            currentCoroutineContext().ensureActive()
            label.delete()
            android.system.Os.rename(temporary.path, modelFile.path)
            mutable.value = current()
        } catch (cancelled: CancellationException) { mutable.value = current(); throw cancelled }
        catch (_: LinkageError) { mutable.value = current("This model runtime is unavailable on this device. The previous model was kept.") }
        catch (_: Exception) { mutable.value = current("The model could not be imported. The previous model was kept.") }
        finally { if (operation === activeJob) operation = null; temporary.delete() }
    } }

    suspend fun remove() = lock.withLock { withContext(Dispatchers.IO) {
        try {
            check(!modelFile.exists() || modelFile.delete()) { "The local model could not be removed" }
            label.delete(); mutable.value = current()
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { mutable.value = current("The model could not be removed. Try again.") }
    } }

    suspend fun downloadTestModel() = downloadModel(LocalModelCatalog.smokeTest)

    /** Only explicit model selection starts a download; no page or question is sent. */
    suspend fun downloadModel(model: LocalModelCatalog.Model) = lock.withLock { withContext(Dispatchers.IO) {
        require(model in LocalModelCatalog.available || model == LocalModelCatalog.smokeTest)
        val temporary = try { File.createTempFile("download-", ".litertlm", folder) }
        catch (_: Exception) { mutable.value = current("Storage is unavailable. Free some space and try again."); return@withContext }
        val activeJob = currentCoroutineContext()[Job]; operation = activeJob
        mutable.value = current().copy(importing = true, total = model.bytes)
        val active = OkHttpClient.Builder().readTimeout(30, TimeUnit.SECONDS).connectTimeout(30, TimeUnit.SECONDS)
            .build().newCall(Request.Builder().url(model.url).build())
        call = active
        try {
            require(folder.usableSpace > model.bytes + 16 * 1024 * 1024) { "There is not enough storage for this model" }
            active.execute().use { response ->
                check(response.isSuccessful) { "The model download failed" }
                val body = response.body ?: throw AgentUnavailable("The model download was empty")
                val digest = MessageDigest.getInstance("SHA-256"); var received = 0L
                body.byteStream().use { source -> temporary.outputStream().use { output ->
                    val buffer = ByteArray(1024 * 1024)
                    while (true) {
                        currentCoroutineContext().ensureActive()
                        val count = source.read(buffer); if (count < 0) break
                        received += count; require(received <= model.bytes) { "Unexpected model size" }
                        digest.update(buffer, 0, count); output.write(buffer, 0, count)
                        mutable.value = mutable.value.copy(received = received)
                    }
                    output.fd.sync()
                } }
                val actual = digest.digest().joinToString("") { "%02x".format(it) }
                require(received == model.bytes && actual == model.sha256) { "Model integrity check failed" }
                validate(temporary)
                currentCoroutineContext().ensureActive()
                label.delete()
                android.system.Os.rename(temporary.path, modelFile.path)
                // A failed label write must not turn a valid installed model into a failed download.
                runCatching { label.writeText(model.name) }
                mutable.value = current()
            }
        } catch (cancelled: CancellationException) { mutable.value = current(); throw cancelled }
        catch (_: LinkageError) { mutable.value = current("This model runtime is unavailable on this device. The previous model was kept.") }
        catch (_: Exception) { mutable.value = current("The model download did not finish. The previous model was kept.") }
        finally { if (operation === activeJob) operation = null; if (call === active) call = null; active.cancel(); temporary.delete() }
    } }

    private fun validate(file: File) {
        val engine = Engine(EngineConfig(modelPath = file.path, backend = Backend.CPU()))
        try { engine.initialize() } finally { if (engine.isInitialized()) engine.close() }
    }
}
