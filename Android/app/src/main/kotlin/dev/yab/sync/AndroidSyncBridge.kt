package dev.yab.sync

import android.content.Context
import android.os.Build
import dev.yab.android.BuildConfig
import dev.yab.android.NowWidget
import dev.yab.android.AppIcon
import dev.yab.android.AppIcons
import dev.yab.android.AppIconSelection
import dev.yab.android.AndroidAppIconLocalStore
import dev.yab.agent.*
import dev.yab.core.crypto.Joining
import dev.yab.core.crypto.Seal
import dev.yab.core.sync.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.HttpUrl.Companion.toHttpUrl
import java.io.Closeable
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.Executors
import kotlin.coroutines.resume

data class SyncUiState(val phase: String = "off", val account: String? = null, val code: String? = null,
                       val check: String? = null, val devices: List<ListedDevice> = emptyList(), val error: String? = null)
data class AccountRecordsSnapshot(val account: String? = null, val epoch: Long = 0, val records: List<Record> = emptyList(),
                                  val removed: Boolean = false, val phase: String = "off", val device: String? = null)
data class SyncArrival(val id: String, val url: String, val title: String, val space: String?, val sender: String, val sentAt: Long) {
    fun fresh(now: Long = System.currentTimeMillis()): Boolean = now - sentAt in 0..600_000
}

/** Android's app adapter for the existing sealed Sync journal, with explicit peer compatibility. */
class AndroidSyncBridge(context: Context, private val baseUrl: String = "https://yab-sync.21st.workers.dev",
                        private val allowInsecureForTests: Boolean = false) : AgentSyncPort, AgentTaskPort, Closeable {
    init {
        val endpoint = baseUrl.toHttpUrl()
        val loopback = endpoint.host in setOf("localhost", "127.0.0.1", "::1")
        require(!allowInsecureForTests || BuildConfig.DEBUG && loopback) { "Test Sync transport requires a debug build and loopback" }
        require(endpoint.isHttps || allowInsecureForTests && BuildConfig.DEBUG && loopback) { "Sync requires HTTPS" }
    }
    private val context = context.applicationContext
    private val keys = SyncIdentityStore(this.context)
    private val nowShelf = NowShelfStore(File(this.context.noBackupFilesDir, NowShelfStore.FILE_NAME))
    private val dispatcher = Executors.newSingleThreadExecutor { Thread(it, "yab-sync-app").apply { isDaemon = true } }.asCoroutineDispatcher()
    private val scope = CoroutineScope(SupervisorJob() + dispatcher)
    private val http = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).build()
    private val identityLock = Any()
    private val operations = SyncOperationLease()
    private var rebuildWaiting = false
    @Volatile private var joiningOperation: SyncOperationLease.Ticket? = null
    private var leavingOperation: SyncOperationLease.Ticket? = null
    private var closing: Job? = null
    @Volatile private var identity: SyncIdentity? = null
    @Volatile private var epoch = 0L
    @Volatile private var client: SyncClient? = null
    private var journal: Journal? = null; private var pairing: PairingClient.Session? = null
    private var roster = emptyList<ListedDevice>(); private val presences = mutableMapOf<String, Record>()
    private val macUsedAt = mutableMapOf<String, Long>()
    private var macRouteStore: MacRouteStore? = null
    private var chosenMac: String? = null
    private var rosterTimer: Job? = null
    private var taskInbox: TaskRecordInbox? = null
    @Volatile private var taskScope: AgentTaskOrigin? = null
    private val mutableTasks = MutableStateFlow(emptyList<ReadOnlyTask>()); override val tasks = mutableTasks.asStateFlow()
    private val mutableTaskMacs = MutableStateFlow(emptyList<TaskMac>()); override val taskMacs = mutableTaskMacs.asStateFlow()
    @Volatile private var foreground = false
    private var pushToken: String? = null; private var pushAlerts = false
    private val mutableUi = MutableStateFlow(SyncUiState()); val ui = mutableUi.asStateFlow()
    private val mutableConnection = MutableStateFlow(RemoteConnection()); override val connection = mutableConnection.asStateFlow()
    private val mutableProjects = MutableStateFlow(ChatProjectsSnapshot()); override val projects = mutableProjects.asStateFlow()
    private val mutableSends = MutableStateFlow(emptyList<RemoteSend>()); override val sends = mutableSends.asStateFlow()
    private val mutableConversations = MutableStateFlow(emptyList<RemoteConversation>()); override val conversations = mutableConversations.asStateFlow()
    private val mutableApprovals = MutableStateFlow(emptyList<ApprovalRequest>()); val approvals = mutableApprovals.asStateFlow()
    private val mutableRecords = MutableStateFlow(emptyList<Record>()); val records = mutableRecords.asStateFlow()
    private val mutableAccountRecords = MutableStateFlow(AccountRecordsSnapshot()); val accountRecords = mutableAccountRecords.asStateFlow()
    private val mutableArrivals = MutableStateFlow(emptyList<SyncArrival>()); val arrivals = mutableArrivals.asStateFlow()
    private val mutableNowRows = MutableStateFlow(emptyList<NowMailRow>()); internal val nowRows = mutableNowRows.asStateFlow()
    @Volatile private var front: JsonObject? = null
    val ownDevice: String? get() = identity?.device
    val accountEpoch: Long get() = epoch
    fun identityLease(): SyncIdentityLease? = synchronized(identityLock) {
        if (closing != null) null else identity?.let { SyncIdentityLease(it.seal.account, it.device, epoch) }
    }
    override fun approvalAuthenticationIdentity(): ApprovalAuthenticationIdentity? = synchronized(identityLock) {
        identityLease()?.takeIf { client?.state !is SyncState.Refused }?.let {
            ApprovalAuthenticationIdentity(it.account, it.device, it.epoch)
        }
    }
    /** Cold native browser startup must distinguish an unread identity from truly unpaired storage. */
    suspend fun prepareNativeOwner(): AccountRecordsSnapshot = withContext(dispatcher) {
        check(!isClosing()) { "Sync ownership is closing" }
        if (identity == null) identity = keys.load() // A corrupt Keystore identity blocks startup.
        check(!isClosing()) { "Sync ownership closed while loading its local identity" }
        publishAccountRecords()
        mutableAccountRecords.value
    }
    /** Atomic publication plus immediate close/replacement gate; no authentication is manufactured. */
    fun nativeOwnerCurrent(expected: AccountRecordsSnapshot): Boolean = synchronized(identityLock) {
        val published = mutableAccountRecords.value
        val saved = identity
        val currentEpoch = epoch
        nativeAccountOwnerCurrent(expected, published, saved?.let { SyncIdentityLease(it.seal.account, it.device, currentEpoch) }, currentEpoch,
            closing != null || client?.state is SyncState.Refused) && epoch == currentEpoch && identity === saved
    }
    fun recoveryLease(): SyncIdentityLease? {
        val source = identityLease() ?: return null
        val active = client ?: return null
        return source.takeIf { active.state !is SyncState.Refused && active.seal.account == it.account && active.device.id == it.device && identityLease() == it }
    }
    internal fun browserCheckpoint(): BrowserSyncCheckpointStore? = identity?.let {
        BrowserSyncCheckpointStore(File(context.noBackupFilesDir, "Sync/${it.seal.account}/browser-${it.device}.json"), it.seal.account, it.device)
    }
    private data class ApprovalBinding(val request: ApprovalRequest, val record: Record, val body: JsonObject, val digest: String,
                                       val detail: Record?, val detailBody: JsonObject?, val detailDigest: String?)
    private var approvalBindings = emptyMap<String, ApprovalBinding>()
    private val answeredApprovals = linkedMapOf<String, ApprovalBinding>()
    private val mutableApprovalResults = MutableStateFlow(emptyList<ApprovalResult>()); override val approvalResults = mutableApprovalResults.asStateFlow()
    private var approvalExpiry: Job? = null
    override fun forgetApprovalResult(id: String) {
        val lease = identityLease() ?: return
        scope.launch {
            if (identityLease() != lease) return@launch
            answeredApprovals.remove(id); mutableApprovalResults.value = mutableApprovalResults.value.filterNot { it.id == id }
        }
    }

    fun start() { foreground = true; scope.launch { safely { startEngine() } } }
    fun pause() { foreground = false; scope.launch { client?.stop() } }
    override fun updateTaskScope(origin: AgentTaskOrigin?) { taskScope = origin?.takeUnless { it.isPrivate } }
    private fun taskEpoch(mac: String): String? {
        if (client?.state != SyncState.Live || roster.none { it.id == mac && isMac(it) && !it.revoked && capability(mac, "androidSync") }) return null
        val presence = presences[mac] ?: return null
        val at = presence.number("at") ?: return null
        val age = System.currentTimeMillis() / 1000.0 - at
        if (presence.key != RecordKey("presence", mac) || !at.isFinite() || at <= 0 || age !in -5.0..<150.0 || presence["asleep"]?.jsonPrimitive?.booleanOrNull == true) return null
        return TaskRecords.readOnlyEpoch(journal?.record(RecordKey("commandcap", mac)), mac)
    }
    override suspend fun sendTask(words: String, origin: AgentTaskOrigin, mac: String, epoch: String): ReadOnlyTask = withContext(dispatcher) {
        val saved = identity ?: error("Join your Mac first")
        val active = client ?: error("Join your Mac first")
        val expectedEpoch = this@AndroidSyncBridge.epoch
        require(foreground && !origin.isPrivate && taskScope == origin) { "The public source changed. Send again." }
        require(taskEpoch(mac) == epoch) { "This Mac is no longer ready for a read-only task" }
        val listed = awaitSyncCallback<List<ListedDevice>> { active.devices(it) }.getOrThrow()
        require(client === active && identity?.device == saved.device && this@AndroidSyncBridge.epoch == expectedEpoch && taskScope == origin) { "Sync or the public source changed" }
        roster = listed.filterNot(ListedDevice::revoked)
        require(taskEpoch(mac) == epoch) { "This Mac is no longer ready for a read-only task" }
        val journal = journal ?: error("Sync is unavailable")
        val spaceKey = RecordKey("space", origin.space); val space = journal.record(spaceKey)
        require(space?.schema == 1 && space.alive()) { "This public space is not yet in Sync" }
        val expected = linkedMapOf<RecordKey, Record?>(spaceKey to space, RecordKey("commandcap", mac) to journal.record(RecordKey("commandcap", mac)))
        if (origin.tab != null) {
            val key = RecordKey("tab", origin.tab); val tab = journal.record(key)
            require(tab?.schema == 1 && tab.alive() && tab.string("parent") == origin.space && tab.string("url") == origin.url && tab.string("title").orEmpty() == origin.title.orEmpty() && TaskRecords.web(origin.url.orEmpty()) != null) { "This page changed or is not yet in Sync" }
            expected[key] = tab
        } else require(origin.url == null && origin.title == null)
        val request = TaskRecords.Request.create(saved.seal.account, saved.device, mac, origin.space, words, epoch, origin.tab, origin.url, origin.title)
        currentCoroutineContext().ensureActive()
        require(foreground && taskScope == origin && taskEpoch(mac) == epoch) { "The task source or producer changed" }
        val record = journal.changeConditionally(RecordKey(TaskRecords.REQUEST, request.id), request.fields(), expected)
        check(TaskRecords.Request.read(record, saved.seal.account, saved.device) == request && journal.record(record.key) == record)
        active.kick(); rebuild()
        mutableTasks.value.first { it.id == request.id }
    }
    override suspend fun openTaskResult(task: ReadOnlyTask, url: String): String? = withContext(dispatcher) {
        val saved = identity ?: return@withContext null
        val active = client ?: return@withContext null
        val source = taskScope ?: return@withContext null
        val expectedEpoch = epoch
        val target = TaskRecords.web(url) ?: return@withContext null
        if (!foreground || source.space != task.request.space || source.isPrivate || active.state is SyncState.Refused) return@withContext null
        val listed = awaitSyncCallback<List<ListedDevice>> { active.devices(it) }.getOrNull() ?: return@withContext null
        if (!foreground || client !== active || epoch != expectedEpoch || identity?.device != saved.device || taskScope != source) return@withContext null
        roster = listed.filterNot(ListedDevice::revoked); rebuild()
        val current = mutableTasks.value.firstOrNull { it.id == task.id } ?: return@withContext null
        if (current.request != task.request || current.observation != task.observation || current.observation?.status != TaskRecords.Status.done) return@withContext null
        target
    }
    private fun rebuildTasks(known: List<ListedDevice>) {
        val saved = identity ?: return
        if (client?.state is SyncState.Refused) { mutableTasks.value = emptyList(); mutableTaskMacs.value = emptyList(); return }
        val journal = journal ?: return
        val peers = known.filter { TaskRecords.supports(journal.record(RecordKey("commandcap", it.id)), it.id) }.associateBy { it.id }
        mutableTaskMacs.value = peers.values.mapNotNull { peer -> taskEpoch(peer.id)?.let { TaskMac(peer.id, peer.name, it) } }
        val inbox = taskInbox ?: return
        mutableTasks.value = journal.all(TaskRecords.REQUEST).mapNotNull { record -> runCatching {
            val request = TaskRecords.Request.read(record, saved.seal.account, saved.device)
            val peer = peers[request.mac] ?: return@runCatching null
            require(request.readOnlyEpoch != null)
            val current = journal.record(RecordKey(TaskRecords.OBSERVATION, request.id))
            val checked = current?.let { runCatching { TaskRecords.Observation.read(it, request) }.getOrNull() }
            if (checked != null) runCatching { inbox.accept(checked, request) }.onFailure { /* Retain only an already durable revision. */ }
            val observed = if (checked != null) inbox.current(request) else null
            ReadOnlyTask(request, observed, peer.name, taskEpoch(peer.id) != null)
        }.getOrNull() }.sortedWith(compareBy<ReadOnlyTask> { it.request.created }.thenBy { it.id })
    }
    private fun startEngine() {
        if (identity == null) identity = try { keys.load() } catch (error: Exception) { clearNow(); throw error }
        val saved = identity
        if (saved == null) clearNow() else if (client == null) attach(saved) else client?.start()
    }
    /** A widget URI carries no destination. Re-read its owner and current sealed-journal facts. */
    suspend fun resolveNowLink(address: String): String? {
        val link = NowShelfCodec.parse(address) ?: return null
        return try {
            val started = withContext(dispatcher) {
                startEngine()
                identity?.let { it.seal.account == link.account && it.device == link.device } == true
            }
            if (!started) return null
            withTimeout(15_000) { ui.first { it.account != link.account || it.phase == "live" || it.phase == "removed" } }
            withContext(dispatcher) {
                val saved = identity ?: return@withContext null
                val current = client ?: return@withContext null
                val expectedEpoch = epoch
                if (saved.seal.account != link.account || saved.device != link.device || current.state != SyncState.Live) return@withContext null
                val listed = awaitSyncCallback<List<ListedDevice>> { current.devices(it) }.getOrNull() ?: return@withContext null
                if (client !== current || epoch != expectedEpoch || identity?.device != saved.device) return@withContext null
                roster = listed.filterNot(ListedDevice::revoked); mutableUi.update { it.copy(devices = roster) }; rebuild()
                NowShelfCodec.resolve(link, nowShelf.read(), saved.seal.account, saved.device, mutableNowRows.value)
            }
        } catch (_: TimeoutCancellationException) { null }
        catch (error: CancellationException) { throw error }
        catch (_: Exception) { null }
    }
    /** Final UI-thread lease check after the suspend resolver resumes its caller. */
    fun isNowLinkCurrent(address: String, url: String): Boolean {
        val link = NowShelfCodec.parse(address) ?: return false
        val saved = identity ?: return false
        val current = mutableUi.value
        return saved.seal.account == link.account && saved.device == link.device && current.account == link.account && current.phase == "live" &&
            current.devices.any { it.id == link.owner && !it.revoked } && mutableNowRows.value.any { it.id == link.id && it.owner == link.owner && it.fingerprint == link.fingerprint && it.web == url }
    }
    private fun clearNow() {
        mutableNowRows.value = emptyList()
        runCatching { nowShelf.clear(); NowWidget.updateAll(context) }
    }
    private fun shelveNow(knownMacs: Set<String>) {
        val saved = identity ?: return clearNow()
        if (client?.state is SyncState.Refused) return clearNow()
        val rows = NowShelfCodec.rows(journal?.all("now").orEmpty(), knownMacs)
        mutableNowRows.value = rows
        runCatching { if (nowShelf.write(saved.seal.account, saved.device, rows)) NowWidget.updateAll(context) }
            .onFailure { mutableUi.update { it.copy(error = "Now widget could not save its rows") } }
    }
    suspend fun registerPushToken(token: String, alerts: Boolean): Boolean = withContext(dispatcher) {
        require(token.length in 1..4096 && token.all { it.code in 33..126 })
        pushToken = token; pushAlerts = alerts
        val current = client ?: return@withContext false
        try { awaitSyncCallback<Boolean> { done -> current.registerPush(buildJsonObject { put("token", token); put("env", "fcm"); put("topic", context.packageName); put("alerts", alerts) }, done) }.getOrDefault(false) }
        catch (error: TimeoutCancellationException) { false }
    }
    suspend fun forgetPushToken(): Boolean = withContext(dispatcher) {
        pushToken = null; val current = client ?: return@withContext true
        try { awaitSyncCallback<Boolean> { done -> current.unregisterPush(done) }.getOrDefault(false) } catch (error: TimeoutCancellationException) { false }
    }
    suspend fun wakeFromPush(): Boolean {
        val ready = withContext(dispatcher) { safely { startEngine() }; identity != null && client != null }
        if (!ready) return false
        return try { withTimeout(20_000) { ui.first { it.phase == "live" && it.devices.isNotEmpty() }; true } }
            catch (error: TimeoutCancellationException) { false }
    }
    suspend fun finishPushWake() { if (!foreground) withContext(dispatcher) { client?.stop() } }
    suspend fun openPushApproval(name: String, blob: String): ApprovalRequest? = withContext(dispatcher) {
        if (blob.length > 96 * 1024) return@withContext null
        val seal = identity?.seal ?: return@withContext null
        val record = runCatching { seal.open(java.util.Base64.getDecoder().decode(blob), name) }.getOrNull() ?: return@withContext null
        if (record.collection != "assistantapproval") return@withContext null
        val binding = approvalBindings[record.id] ?: return@withContext null
        val body = record.string("body")?.let { runCatching { Json.parseToJsonElement(it).jsonObject }.getOrNull() } ?: return@withContext null
        if (record.stamps["body"]?.device != binding.request.mac || requestDigest(body) != binding.digest || binding.request.expiresAt <= System.currentTimeMillis()) null else binding.request
    }
    fun selectMac(id: String?) {
        identityLease()?.let { selectMac(id, it) }
    }
    fun selectMac(id: String?, expected: SyncIdentityLease) {
        scope.launch {
            if (identityLease() != expected) return@launch
            safely {
                require(id == null || mutableConnection.value.macs.any { it.id == id })
                macRouteStore?.save(id); chosenMac = id; mutableConnection.update { it.copy(selectedMac = id) }
                publishAccountRecords()
            }
        }
    }
    fun updateFront(url: String?, title: String = "", tab: String? = null, space: String? = null, isPrivate: Boolean = false) {
        front = if (isPrivate || url == null || !webUrl(url, excludeLocal = true)) null else buildJsonObject {
            put("url", url); put("title", title.take(200)); tab?.let { put("tab", it) }; space?.let { put("space", it) }; put("changed", System.currentTimeMillis() / 1000)
        }
        client?.sayPresence()
    }
    suspend fun publishBrowser(changes: Map<RecordKey, JsonObject>, removed: Set<RecordKey> = emptySet(), expected: Map<RecordKey, Record?> = emptyMap(),
                               expectedAccount: String? = null, expectedEpoch: Long? = null,
                               paintEdits: Map<RecordKey, BrowserPaintEdit> = emptyMap()) = withContext(dispatcher) {
        BrowserSyncPublication.publish(changes, removed, expectedAccount, expectedEpoch,
            currentAccount = { identity?.seal?.account }, currentEpoch = { epoch },
            refused = { client?.state is SyncState.Refused }, journal = { this@AndroidSyncBridge.journal }, paintEdits = paintEdits, expected = expected) { publication ->
        val journal = publication.journal
        journal.changeBatch(publication.fields, expected)
        val deletedSpaces = removed.filter { it.collection == "space" }.map { it.id }.toSet()
        for (key in removed) {
            val record = journal.record(key) ?: continue
            // Today belongs to one device; a missing imported row can never delete another device's tab.
            if (key.collection != "tab" || record["kept"]?.jsonPrimitive?.booleanOrNull == true || record.string("pin") != null || record.string("device") == identity?.device || record.string("parent") in deletedSpaces) journal.remove(key)
        }
        } ?: return@withContext
        client?.kick(); rebuild()
    }
    /** Only an actual local seasonal wear or the one-time installed legacy migration earns a grant. */
    suspend fun keepAppIcon(icon: AppIcon, source: SyncIdentityLease) = withContext(dispatcher) {
        check(identityLease() == source && !isClosing() && client?.state !is SyncState.Refused) { "The app icon Sync account changed." }
        require(icon.canKeepLocally && icon in AndroidAppIconLocalStore(context).read().kept) { "This app icon has not been worn on this device." }
        val journal = journal ?: error("Sync is unavailable. The worn icon is saved locally.")
        keepAppIcon(journal, icon)
        client?.kick(); rebuild()
    }
    private fun keepAppIcon(journal: Journal, icon: AppIcon) {
        val key = RecordKey("setting", icon.grantKey)
        val previous = journal.record(key)
        require(previous == null || previous.schema == 1) { "This app icon grant requires a newer Yab version." }
        val value = previous?.get("value") as? JsonPrimitive
        if (previous?.schema == 1 && previous.alive() && value != null && !value.isString && value.booleanOrNull == true) return
        journal.changeConditionally(key, JsonObject(previous?.visible.orEmpty() + ("value" to JsonPrimitive(true))), mapOf(key to previous))
    }
    private fun restoreKeptAppIcons(journal: Journal) {
        // A corrupt or unsupported local icon preference cannot fabricate a grant or block unrelated Sync.
        val local = runCatching { AppIconSelection(AndroidAppIconLocalStore(context), AppIcons(context)).migrateLegacy() }.getOrNull() ?: return
        local.kept.filter { it.canKeepLocally }.filter { journal.record(RecordKey("setting", it.grantKey))?.schema.let { schema -> schema == null || schema == 1 } }
            .forEach { keepAppIcon(journal, it) }
    }
    suspend fun openOnMac(url: String, title: String, space: String? = null,
                          expected: SyncIdentityLease? = null): String = withContext(dispatcher) {
        // The dispatcher may have changed account while a captured menu action was queued.
        // Check its complete identity here, before looking up a recipient or writing a send.
        check(expected == null || identityLease() == expected) { "The page menu Sync owner changed" }
        check(!isClosing() && client?.state !is SyncState.Refused) { "Sync is unavailable" }
        require(webUrl(url, excludeLocal = true)) { "This page cannot be sent to another device" }
        val identity = identity ?: error("Join your Mac first"); val journal = journal ?: error("Sync unavailable")
        val connection = mutableConnection.value
        val eligible = connection.macs.filter { capability(it.id, "open") }
        val mac = connection.commandMac(eligible)
            ?: throw AgentUnavailable("Choose an updated Mac before sending this page")
        val id = UUID.randomUUID().toString()
        journal.change(RecordKey("send", id), buildJsonObject {
            put("device", mac.id); put("clientDevice", identity.device); put("kind", "open"); put("url", url); put("title", title.filterNot(Char::isISOControl).take(200)); put("at", System.currentTimeMillis() / 1000.0)
            space?.takeIf { runCatching { UUID.fromString(it) }.isSuccess }?.let { put("space", it.uppercase()) }
        }); client?.kick(); id
    }
    /** Existing SyncKit closeTab is the tab's removal-wins record, with its exact rendered owner. */
    internal suspend fun useMacToday(row: MacTodayRow, close: Boolean, sourceCurrent: () -> Boolean): String = withContext(dispatcher) {
        val saved = identity ?: error("Join your Mac first"); val journal = journal ?: error("Sync unavailable")
        require(saved.seal.account == row.account && epoch == row.epoch && client?.state !is SyncState.Refused && sourceCurrent()) { "The account or public source changed" }
        require(mutableConnection.value.macs.any { it.id == row.mac } && capability(row.mac, "androidSync")) { "This Mac is no longer in this account" }
        val record = journal.record(RecordKey("tab", row.id)) ?: error("This Mac's page is no longer open")
        require(record == row.record && record.alive() && record.schema == 1 && record.string("parent") == row.space && (record["kept"] as? JsonPrimitive)?.booleanOrNull != true && record.string("pin") == null) { "This Mac's page changed" }
        require(record.string("device") == row.mac || record.string("device") == null && mutableConnection.value.macs.firstOrNull()?.id == row.mac) { "This page has a different owner" }
        val url = record.string("url")?.takeIf { webUrl(it) } ?: error("This page cannot be opened")
        require(url == row.url && sourceCurrent()) { "This page or public source changed" }
        if (close) { journal.removeConditionally(record.key, mapOf(record.key to record)); client?.kick(); rebuild() }
        url
    }
    suspend fun takeArrival(id: String, open: suspend (SyncArrival) -> Unit): Boolean = withContext(dispatcher) {
        val identity = identity ?: return@withContext false; val journal = journal ?: return@withContext false
        val key = RecordKey("send", id); val record = journal.record(key) ?: return@withContext false
        val arrival = mutableArrivals.value.firstOrNull { it.id == id } ?: return@withContext false
        val receipt = "open/${identity.seal.account}/${identity.device}/$id"
        if (!journal.reserveReceipt(receipt)) return@withContext false
        journal.changeConditionally(key, JsonObject(record.visible + ("state" to JsonPrimitive("opening"))), mapOf(key to record))
        val state = try { withContext(Dispatchers.Main.immediate) { open(arrival) }; "taken" } catch (error: Exception) { "failed" }
        val current = journal.record(key) ?: error("Open receipt disappeared")
        journal.change(key, JsonObject(current.visible + mapOf("state" to JsonPrimitive(state), "took" to JsonPrimitive(System.currentTimeMillis() / 1000.0))))
        client?.kick(); rebuild(); state == "taken"
    }
    fun join(scannedCode: String? = null, onJoined: ((SyncIdentityLease) -> Unit)? = null, onJoinFailed: (() -> Unit)? = null) {
        val source = sessionSource()
        scope.launch { safely {
            if (sessionSource() != source || isClosing()) return@safely
            check(identity == null && client == null) { "Turn off Sync before joining another account" }
            val operation = operations.begin(source)
            joiningOperation = operation
            val oldPairing = pairing; pairing = null; oldPairing?.close()
            try {
                verifyServerSupport()
                if (!operationCurrent(operation)) return@safely
                val code = scannedCode?.let { Joining.code(it) ?: error("This is not a Yab pairing code") }
                val joining = Joining(code ?: Joining.makeCode())
                mutableUi.value = SyncUiState("joining", code = joining.code, check = joining.check)
                pairing = PairingClient(baseUrl, http, allowInsecureForTests).join(joining) { result -> scope.launch pairingResult@{
                    if (!finishOperation(operation)) return@pairingResult
                    joiningOperation = null; pairing = null
                    result.fold({ seal ->
                        val joined = acceptJoinedIdentity(seal)
                        if (joined != null) publishJoinedPresentation(joined, onJoined) else publishJoinFailure(onJoinFailed)
                    }, { error ->
                        mutableUi.value = SyncUiState(error = error.message ?: "Pairing failed")
                        publishJoinFailure(onJoinFailed)
                    })
                } }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (error: Exception) {
                if (finishOperation(operation)) {
                    joiningOperation = null
                    mutableUi.value = SyncUiState(error = error.message ?: "Pairing failed")
                    publishJoinFailure(onJoinFailed)
                }
            }
        } }
    }
    /** FirstRun owns this exact request even while health has not yielded a code. Legacy join stays unchanged. */
    fun joinRequest(scannedCode: String? = null, onJoined: ((SyncIdentityLease) -> Unit)? = null,
        onJoinFailed: (() -> Unit)? = null): CodeJoinRequest {
        val source = sessionSource()
        val creationMarker = operations.marker()
        val request = CodeJoinRequest(this, source, { ticket, session, operationRequired ->
            synchronized(identityLock) {
                !isClosing() && sessionSource() == source && (!operationRequired || ticket == null ||
                    operations.current(ticket, source) && (session == null || pairing === session))
            }
        }, { ticket ->
            synchronized(identityLock) {
                !isClosing() && sessionSource() == source && (if (ticket == null) operations.idleSince(creationMarker)
                    else operations.current(ticket, source) || operations.idleSince(ticket.marker))
            }
        }, { original, snapshot ->
            original.claimRecovery(this, snapshot) { ticket -> makeRecoveryHandoff(source, ticket?.marker ?: creationMarker) }
        }, ::cancelCodeJoin)
        scope.launch {
            if (isClosing() || !request.current(this@AndroidSyncBridge, sessionSource())) return@launch
            var operation: SyncOperationLease.Ticket? = null
            try {
                check(identity == null && client == null) { "Turn off Sync before joining another account" }
                val ticket = request.allocate(this@AndroidSyncBridge, sessionSource()) {
                    synchronized(identityLock) {
                        if (isClosing() || sessionSource() != source) null else operations.begin(source)
                    }
                } ?: return@launch
                operation = ticket
                joiningOperation = ticket
                val oldPairing = pairing; pairing = null; oldPairing?.close()
                verifyServerSupport()
                if (!operationCurrent(ticket) || !request.current(this@AndroidSyncBridge, sessionSource())) return@launch
                val code = scannedCode?.let { Joining.code(it) ?: error("This is not a Yab pairing code") }
                val joining = Joining(code ?: Joining.makeCode())
                request.publish(this@AndroidSyncBridge, sessionSource(), ticket, { operationCurrent(ticket) }, joining.code, joining.check) {
                    synchronized(identityLock) {
                        check(operationCurrent(ticket)) { "Original code request changed" }
                        mutableUi.value = SyncUiState("joining", code = joining.code, check = joining.check)
                        PairingClient(baseUrl, http, allowInsecureForTests).join(joining) { result -> scope.launch pairingResult@{
                            if (!request.commit(this@AndroidSyncBridge, sessionSource(), ticket, { finishOperation(ticket) })) return@pairingResult
                            joiningOperation = null; pairing = null
                            result.fold({ seal ->
                                val joined = acceptJoinedIdentity(seal)
                                request.outcome(this@AndroidSyncBridge, ticket, if (joined == null) "Sync unavailable" else null)
                                if (joined != null) publishJoinedPresentation(joined, onJoined) else publishJoinFailure(onJoinFailed)
                            }, { error ->
                                request.outcome(this@AndroidSyncBridge, ticket, error.message ?: "Pairing failed")
                                synchronized(identityLock) {
                                    if (!isClosing() && sessionSource() == source) {
                                        mutableUi.value = SyncUiState(error = error.message ?: "Pairing failed")
                                        publishJoinFailure(onJoinFailed)
                                    }
                                }
                            })
                        } }.also { pairing = it }
                    }
                }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (error: Exception) {
                val ticket = operation
                if (ticket != null && request.commit(this@AndroidSyncBridge, sessionSource(), ticket, { finishOperation(ticket) })) {
                    request.outcome(this@AndroidSyncBridge, ticket, error.message ?: "Pairing failed")
                    synchronized(identityLock) {
                        if (!isClosing() && sessionSource() == source) {
                            joiningOperation = null
                            mutableUi.value = SyncUiState(error = error.message ?: "Pairing failed")
                            publishJoinFailure(onJoinFailed)
                        }
                    }
                } else if (ticket == null && !isClosing()) {
                    request.failUnbound(this@AndroidSyncBridge, sessionSource(), error.message ?: "Sync unavailable") {
                        synchronized(identityLock) {
                            if (!isClosing() && sessionSource() == source) {
                                mutableUi.update { it.copy(error = error.message ?: "Sync unavailable") }
                                publishJoinFailure(onJoinFailed)
                            }
                        }
                    }
                }
            }
        }
        return request
    }
    private fun cancelCodeJoin(request: CodeJoinRequest): Boolean {
        if (isClosing()) return false
        val source = sessionSource()
        val cancelled = request.cancel(this, source) { !isClosing() && sessionSource() == source } ?: return false
        scope.launch {
            val ticket = cancelled.ticket
            synchronized(identityLock) {
                if (ticket != null && joiningOperation === ticket && finishOperation(ticket)) {
                    joiningOperation = null
                    if (pairing === cancelled.session) pairing = null
                    mutableUi.value = SyncUiState()
                }
            }
            cancelled.session?.close()
        }
        return true
    }
    fun cancelJoin() { mutableUi.value.code?.let(::cancelJoin) }
    fun cancelJoin(code: String) {
        val operation = joiningOperation ?: return
        scope.launch {
            if (mutableUi.value.code != code) return@launch
            if (!finishOperation(operation)) return@launch
            joiningOperation = null
            val oldPairing = pairing; pairing = null; oldPairing?.close()
            mutableUi.value = SyncUiState()
        }
    }
    fun joinRecovery(recovery: String, onJoined: ((SyncIdentityLease) -> Unit)? = null, onJoinFailed: (() -> Unit)? = null) {
        val source = sessionSource()
        scope.launch { safely {
            if (sessionSource() != source || isClosing()) return@safely
            check(identity == null && client == null) { "Turn off Sync before joining another account" }
            val operation = operations.begin(source)
            joiningOperation = null
            val oldPairing = pairing; pairing = null; oldPairing?.close()
            try {
                val seal = Seal.fromRecovery(recovery) ?: error("Recovery Key has an invalid checksum")
                verifyServerSupport()
                if (!finishOperation(operation)) return@safely
                val joined = acceptJoinedIdentity(seal)
                if (joined != null) publishJoinedPresentation(joined, onJoined) else publishJoinFailure(onJoinFailed)
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (error: Exception) {
                if (finishOperation(operation)) {
                    mutableUi.value = SyncUiState(error = error.message ?: "Sync unavailable")
                    publishJoinFailure(onJoinFailed)
                }
            }
        } }
    }
    private fun makeRecoveryHandoff(source: SyncOperationLease.Source, marker: SyncOperationLease.Marker): RecoveryHandoff =
        RecoveryHandoff(this, source, marker, ::cancelRecoveryHandoff) { original ->
            original.retry(this, { expected -> synchronized(identityLock) {
                !isClosing() && sessionSource() == source && identity == null && client == null && operations.idleSince(expected)
            } }, { expected -> makeRecoveryHandoff(source, expected) })
        }
    private fun cancelRecoveryHandoff(handoff: RecoveryHandoff, snapshot: RecoveryHandoff.Presentation): Boolean =
        handoff.cancel(this, snapshot) { ticket -> synchronized(identityLock) {
            !isClosing() && sessionSource() == handoff.source &&
                (ticket == null || operations.finish(ticket, handoff.source))
        } }
    /** Original-request admission is atomic before parsing, health or any global mutation. */
    internal fun joinRecoveryRequest(recovery: String, handoff: RecoveryHandoff,
        onJoined: ((SyncIdentityLease) -> Unit)? = null, onJoinFailed: (() -> Unit)? = null) {
        scope.launch {
            val source = handoff.source
            val operation = handoff.admit(this@AndroidSyncBridge) {
                synchronized(identityLock) {
                    if (isClosing() || sessionSource() != source || identity != null || client != null ||
                        pairing != null || joiningOperation != null) null
                    else operations.beginIfIdleSince(handoff.marker, source)
                }
            } ?: return@launch
            fun commit(): Boolean = handoff.commit(this@AndroidSyncBridge, operation) { synchronized(identityLock) {
                !isClosing() && sessionSource() == source && operations.finish(operation, source)
            } }
            try {
                if (!operationCurrent(operation)) { handoff.refuse(this@AndroidSyncBridge, operation); return@launch }
                val seal = Seal.fromRecovery(recovery) ?: error("Recovery Key has an invalid checksum")
                verifyServerSupport()
                if (!commit()) return@launch
                val joined = acceptJoinedIdentity(seal)
                if (handoff.outcome(this@AndroidSyncBridge, operation, if (joined == null) "Sync unavailable" else null)) {
                    if (joined != null) publishJoinedPresentation(joined, onJoined)
                    else publishRecoveryFailure(operation, source, "Sync unavailable", onJoinFailed)
                }
            } catch (cancelled: CancellationException) {
                if (!handoff.outcome(this@AndroidSyncBridge, operation, "Sync unavailable"))
                    handoff.refuse(this@AndroidSyncBridge, operation)
                throw cancelled
            }
            catch (error: Exception) {
                // An exception after durable work began belongs to the winning
                // commit. It cannot try commit again or reopen cancellation.
                if (handoff.committed(this@AndroidSyncBridge, operation) || commit()) {
                    if (handoff.outcome(this@AndroidSyncBridge, operation, error.message ?: "Sync unavailable"))
                        publishRecoveryFailure(operation, source, error.message ?: "Sync unavailable", onJoinFailed)
                } else handoff.refuse(this@AndroidSyncBridge, operation)
            }
        }
    }
    /** Own terminal cleanup only; no new source/operation can publish this failure. */
    private fun publishRecoveryFailure(operation: SyncOperationLease.Ticket, original: SyncOperationLease.Source,
        error: String, observer: (() -> Unit)?) {
        val terminalSource = synchronized(identityLock) {
            if (isClosing() || !operations.idleSince(operation.marker)) return
            val terminal = sessionSource()
            // A partial own attach keeps the helper's error, never a new write
            // authorized by the old unpaired source.
            if (terminal == original) mutableUi.value = SyncUiState(error = error)
            terminal
        }
        if (observer == null) return
        scope.launch(Dispatchers.Main.immediate) {
            val current = synchronized(identityLock) {
                !isClosing() && sessionSource() == terminalSource && operations.idleSince(operation.marker)
            }
            if (!current) return@launch
            try { observer() } catch (_: Exception) { }
        }
    }
    /** The settings view must put its own biometric gate in front of this export. */
    suspend fun recoveryKey(expected: SyncIdentityLease): String = withContext(dispatcher) {
        require(recoveryLease() == expected) { "Sync changed or this device was removed. Unlock again for the current account." }
        val seal = identity?.seal ?: error("Sync is off")
        currentCoroutineContext().ensureActive()
        require(recoveryLease() == expected) { "Sync changed. Unlock again for the current account." }
        seal.recovery
    }
    fun disconnect() { disconnectFrom(sessionSource()) }
    fun disconnect(expected: SyncIdentityLease) { disconnectFrom(SyncOperationLease.Source(expected.account, expected.device, expected.epoch)) }
    private fun disconnectFrom(source: SyncOperationLease.Source) {
        scope.launch {
            if (sessionSource() != source || isClosing()) return@launch
            if (leavingOperation?.let { operationCurrent(it) } == true) return@launch
            val operation = operations.begin(source)
            leavingOperation = operation
            joiningOperation = null
            val oldPairing = pairing; pairing = null; oldPairing?.close()
            val old = client
            try {
                if (old != null && old.state !is SyncState.Refused) {
                    val removed = try { awaitSyncCallback<Boolean> { done -> old.removeDevice(old.device.id, done) }.getOrThrow() }
                        catch (timeout: TimeoutCancellationException) { throw IllegalStateException("The server did not answer. Try turning off Sync again when online.", timeout) }
                    if (client !== old || !operationCurrent(operation)) return@launch
                    check(removed) { "The server did not remove this device. Try again when online." }
                }
                if (finishOperation(operation)) clearLocal()
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (error: Exception) {
                if (finishOperation(operation)) mutableUi.update { it.copy(error = error.message ?: "Sync unavailable") }
            }
            finally { if (leavingOperation === operation) leavingOperation = null }
        }
    }
    private fun isClosing(): Boolean = synchronized(identityLock) { closing != null }
    private fun operationCurrent(ticket: SyncOperationLease.Ticket): Boolean = !isClosing() && operations.current(ticket, sessionSource())
    private fun finishOperation(ticket: SyncOperationLease.Ticket): Boolean = !isClosing() && operations.finish(ticket, sessionSource())
    private fun sessionSource(): SyncOperationLease.Source = synchronized(identityLock) {
        identity.let { SyncOperationLease.Source(it?.seal?.account, it?.device, epoch) }
    }
    private fun acceptJoinedIdentity(seal: Seal): SyncIdentityLease? {
        if (isClosing()) return null
        val source = sessionSource()
        val saved = SyncIdentity(seal, UUID.randomUUID().toString(), null)
        try {
            keys.save(saved); identity = saved; attach(saved)
            return identityLease()?.takeIf { it.account == saved.seal.account && it.device == saved.device &&
                client?.let { active -> active.seal.account == it.account && active.device.id == it.device && active.state !is SyncState.Refused } == true }
        }
        catch (cancelled: CancellationException) { throw cancelled }
        catch (error: Exception) {
            if (!isClosing() && (sessionSource() == source || identity?.device == saved.device))
                mutableUi.value = SyncUiState(account = identity?.seal?.account, error = error.message ?: "Sync unavailable")
        }
        return null
    }
    /** An optional UI observation of this finished join only, never a reconnect or a Sync capability. */
    private fun publishJoinedPresentation(joined: SyncIdentityLease?, observer: ((SyncIdentityLease) -> Unit)?) {
        if (joined == null || observer == null) return
        scope.launch(Dispatchers.Main.immediate) {
            if (identityLease() != joined || client?.state is SyncState.Refused) return@launch
            // Presentation failure must not change a successfully saved account or its Sync error.
            try { observer(joined) } catch (_: Exception) { }
        }
    }
    /** An observation of this original completed operation, never a UI.error/phase inference. */
    private fun publishJoinFailure(observer: (() -> Unit)?) {
        if (observer == null) return
        // Identity may already be saved when its original attach fails. Delivery may
        // retire that original presentation only while this exact terminal source remains.
        val terminalSource = sessionSource()
        scope.launch(Dispatchers.Main.immediate) {
            if (isClosing() || sessionSource() != terminalSource) return@launch
            // A presentation exception must not replace the original failure or identity state.
            try { observer() } catch (_: Exception) { }
        }
    }
    private fun clearLocal() {
        operations.invalidate(); joiningOperation = null; leavingOperation = null
        synchronized(identityLock) { epoch++; identity = null }
        mutableAccountRecords.value = AccountRecordsSnapshot(epoch = epoch)
        mutableProjects.value = ChatProjectsSnapshot.publish(mutableProjects.value, null, null, epoch, emptyList())
        pairing?.close(); pairing = null; rosterTimer?.cancel(); client?.close(); client = null; journal?.close(); journal = null
        keys.forget(); File(context.noBackupFilesDir, "Sync").deleteRecursively(); roster = emptyList(); presences.clear()
        macUsedAt.clear(); macRouteStore = null; chosenMac = null
        mutableConnection.value = RemoteConnection(epoch = epoch); mutableSends.value = emptyList(); mutableConversations.value = emptyList(); mutableApprovals.value = emptyList(); mutableRecords.value = emptyList(); mutableArrivals.value = emptyList(); front = null
        approvalBindings = emptyMap(); mutableUi.value = SyncUiState()
        answeredApprovals.clear(); mutableApprovalResults.value = emptyList(); approvalExpiry?.cancel(); approvalExpiry = null
        taskScope = null; taskInbox = null; mutableTasks.value = emptyList(); mutableTaskMacs.value = emptyList()
        clearNow()
    }
    private fun verifyServerSupport() {
        val request = Request.Builder().url(baseUrl.trimEnd('/') + "/v1/health").build()
        http.newCall(request).execute().use { response ->
            val body = response.body?.string()?.takeIf { it.length <= 64_000 } ?: error("Sync server did not answer")
            val supported = response.isSuccessful && runCatching { Json.parseToJsonElement(body).jsonObject.number("androidSync") == 1.0 }.getOrDefault(false)
            check(supported) { "Update the Yab Sync server and your Mac before joining Android. Existing devices remain unchanged." }
        }
    }
    private fun attach(saved: SyncIdentity) {
        if (nowShelf.read()?.let { it.account != saved.seal.account || it.device != saved.device } == true) clearNow()
        verifyServerSupport(); val currentEpoch = ++epoch
        val folder = File(context.noBackupFilesDir, "Sync/${saved.seal.account}").apply { check(isDirectory || mkdirs()) }
        macRouteStore = MacRouteStore(File(folder, "mac-route.json"), saved.seal.account)
        chosenMac = macRouteStore?.read()
        val opened = FileJournal(File(folder, "journal.json"), saved.device, saved.seal.account)
        taskInbox = try { TaskRecordInbox(File(folder, "task-records-${saved.device}.json"), saved.seal.account, saved.device) }
            catch (error: Exception) { opened.close(); throw error }
        lateinit var next: SyncClient
        next = SyncClient(baseUrl, opened, saved.seal,
            Device(saved.device, Build.MODEL, "Android ${Build.MANUFACTURER} ${Build.MODEL}", formFactor = if (context.resources.configuration.smallestScreenWidthDp >= 600) "tablet" else "phone"), saved.token,
            http, saveToken = { token -> synchronized(identityLock) {
                check(epoch == currentEpoch && identity?.device == saved.device) { "Sync account changed" }
                val updated = saved.copy(token = token); keys.save(updated); identity = updated
            } }, allowInsecureForTests = allowInsecureForTests)
        next.onState = { state -> scope.launch { if (client === next) {
            mutableUi.update { it.copy(phase = when (state) { SyncState.Off -> "off"; SyncState.Connecting -> "connecting"; SyncState.Live -> "live"; is SyncState.Waiting -> "waiting"; is SyncState.Refused -> "removed" },
                account = saved.seal.account, code = null, check = null, error = when (state) { is SyncState.Waiting -> state.reason; is SyncState.Refused -> state.reason; else -> null }) }
            if (state == SyncState.Live) {
                opened.change(RecordKey("commandcap", saved.device), SyncCapabilities.local(saved.device)); next.kick(); refreshDevices()
                pushToken?.let { registerPushToken(it, pushAlerts) }
                rebuild()
            }
            if (state is SyncState.Refused) {
                mutableConnection.update { it.copy(macs = emptyList()) }; mutableSends.value = emptyList(); mutableTasks.value = emptyList(); mutableTaskMacs.value = emptyList(); clearNow()
                approvalBindings = emptyMap(); mutableApprovals.value = emptyList(); answeredApprovals.clear(); mutableApprovalResults.value = emptyList(); approvalExpiry?.cancel()
            }
            if (state != SyncState.Live) mutableTaskMacs.value = emptyList()
            publishAccountRecords()
        } } }
        // A device catching up on a Mac's whole account hears hundreds of pages: all of them count once, at Live.
        next.onRecords = { scope.launch { if (client === next && next.state != SyncState.Connecting) rebuildSoon() } }
        next.onPresence = { device, record -> scope.launch { if (client === next) {
            val tab = record.string("tab")
            val at = record.number("at")?.takeIf { it.isFinite() && it > 0 && it * 1000 <= Long.MAX_VALUE }?.times(1000)?.toLong()
            if (tab != null && (tab != presences[device]?.string("tab") || device !in macUsedAt) && at != null) macUsedAt[device] = maxOf(macUsedAt[device] ?: Long.MIN_VALUE, at)
            presences[device] = record; rebuildSoon()
        } } }
        next.presence = {
            Record("presence", saved.device, buildJsonObject {
                put("name", Build.MODEL); put("kind", "android"); put("at", System.currentTimeMillis() / 1000.0)
                front?.forEach { (key, value) -> put(key, value) }
            })
        }
        next.onFailure = { scope.launch { if (client === next) mutableUi.update { it.copy(error = "Sync could not read or save its data. Reopen Yab to retry.") } } }
        journal = opened; client = next; mutableUi.value = SyncUiState("connecting", saved.seal.account)
        restoreKeptAppIcons(opened)
        publishAccountRecords()
        mutableConnection.value = RemoteConnection(account = saved.seal.account, epoch = epoch)
        rebuild(); next.start()
        rosterTimer?.cancel(); rosterTimer = scope.launch { while (isActive) { delay(55_000); refreshDevices() } }
    }
    private fun refreshDevices() { val expected = client ?: return; expected.devices { result -> scope.launch { if (client === expected) result.onSuccess { roster = it.filterNot(ListedDevice::revoked); mutableUi.update { ui -> ui.copy(devices = roster) }; rebuild() } } } }
    private fun capability(mac: String, field: String, version: Double = 1.0): Boolean {
        val record = journal?.record(RecordKey("commandcap", mac)) ?: return false
        return record.alive() && record.string("device") == mac && record.stamps["device"]?.device == mac && record.number(field) == version && record.stamps[field]?.device == mac
    }
    private fun isMac(device: ListedDevice): Boolean = SyncDevicePlatform.isMac(device.platform, device.model)
    /** Account and journal bytes cross threads in one emission, including removal and reattachment. */
    private fun publishAccountRecords() {
        val saved = identity
        mutableAccountRecords.value = if (saved == null) AccountRecordsSnapshot(epoch = epoch)
        else AccountRecordsSnapshot(saved.seal.account, epoch, journal?.all().orEmpty(), client?.state is SyncState.Refused,
            mutableUi.value.phase, saved.device)
        mutableProjects.value = ChatProjectsSnapshot.publish(mutableProjects.value, saved?.seal?.account, saved?.device, epoch,
            if (saved == null || isClosing()) emptyList() else SyncProject.all(journal?.all(ChatProjects.COLLECTION).orEmpty()),
            client?.state is SyncState.Refused || isClosing(), mutableConnection.value,
            if (saved == null || isClosing()) emptyList() else journal?.all("chat").orEmpty().filter { it.alive() && it.id.startsWith("a:") }
                .mapNotNull { head -> head.string("device")?.let { ChatProjectMembership(head.id, it, head.string("cli")?.let(::provider), head.string("project")) } }
                .sortedBy { it.chat })
    }
    private fun rebuildSoon() {
        if (rebuildWaiting) return
        rebuildWaiting = true
        scope.launch { rebuildWaiting = false; rebuild() }
    }
    private fun rebuild() {
        val identity = identity ?: return; val journal = journal ?: return
        if (client?.state is SyncState.Refused) {
            mutableConnection.value = RemoteConnection(account = identity.seal.account, epoch = epoch)
            mutableSends.value = emptyList()
            mutableConversations.value = emptyList(); mutableApprovals.value = emptyList(); approvalBindings = emptyMap()
            answeredApprovals.clear(); mutableApprovalResults.value = emptyList(); approvalExpiry?.cancel(); approvalExpiry = null
            mutableTasks.value = emptyList(); mutableTaskMacs.value = emptyList(); mutableArrivals.value = emptyList(); clearNow()
            mutableRecords.value = journal.all()
            publishAccountRecords()
            return
        }
        val available = roster.filter { it.id != identity.device && isMac(it) && capability(it.id, "androidSync") }
        rebuildTasks(available)
        shelveNow(available.map { it.id }.toSet())
        val macs = available.map { device ->
            val front = presences[device.id]
            val at = front?.number("at")?.takeIf { it.isFinite() && it > 0 && it * 1000 <= Long.MAX_VALUE }?.times(1000)?.toLong()
            val last = listOfNotNull(device.lastSeen, at).maxOrNull()
            val availability = MacAvailability.heard(front?.get("asleep")?.jsonPrimitive?.booleanOrNull == true, front?.string("why"), at, last, System.currentTimeMillis())
            val models = if (capability(device.id, "modelPick")) (journal.record(RecordKey("commandcap", device.id))?.get("models") as? JsonArray).orEmpty().mapNotNull { value ->
                val model = value as? JsonObject ?: return@mapNotNull null; val provider = model.string("cli")?.let(::provider) ?: return@mapNotNull null
                RemoteModel(model.string("model") ?: return@mapNotNull null, model.string("name") ?: model.string("model")!!, provider, (model["efforts"] as? JsonArray).orEmpty().mapNotNull { it.jsonPrimitive.contentOrNull })
            } else emptyList()
            RemoteMac(device.id, device.name, availability.phase == MacPhase.UP,
                if (capability(device.id, "chatAgent")) AgentProvider.entries.toSet() else emptySet(),
                capability(device.id, "attachments"), capability(device.id, "chatControl"), models, capability(device.id, "chatMetadata"), availability, last, macUsedAt[device.id], front?.string("tab"),
                ChatProjects.supports(journal.record(RecordKey("commandcap", device.id)), device.id))
        }.sortedWith(compareBy<RemoteMac> { if (it.availability.phase == MacPhase.UP) 0 else 1 }.thenBy { it.name }.thenBy { it.id })
        mutableConnection.update { it.copy(account = identity.seal.account, epoch = epoch, macs = macs, selectedMac = chosenMac?.takeIf { id -> macs.any { it.id == id } }) }
        mutableRecords.value = journal.all()
        publishAccountRecords()
        val sends = journal.all("send").filter { it.string("clientDevice") == identity.device }
        mutableSends.value = sends.mapNotNull { remoteSend(it) }.sortedWith(compareBy<RemoteSend> { it.sentAt }.thenBy { it.id })
        val transcriptNow = System.currentTimeMillis()
        val chatItems = journal.all("chatitem").groupBy { (if (it.alive()) it.visible else it.fields).string("chat") }
        val sendsInOrder = sends.sortedBy { it.number("at") ?: 0.0 }
        mutableConversations.value = journal.all("chat").mapNotNull { head ->
            val f = if (head.alive()) head.visible else head.fields
            val mac = f.string("device") ?: return@mapNotNull null; if (!head.id.startsWith("a:") || available.none { it.id == mac }) return@mapNotNull null
            val provider = f.string("cli")?.let(::provider) ?: return@mapNotNull null
            val owner = RemoteOwner(identity.seal.account, mac, head.id, provider)
            if (f.string("kind") != null && f.string("kind") != "agent") return@mapNotNull null
            val items = chatItems[head.id].orEmpty()
            val messages = ChatTranscript.messages(head, items, sends, now = transcriptNow)
            val going = f.string("state") in setOf("starting", "running", "waiting", "signing-in")
            RemoteConversation(sendsInOrder.lastOrNull { it.string("chat") == head.id }?.string("clientChat"), owner, f.string("title") ?: "Chat", messages, ChatTurnSemantics.isLive(head, transcriptNow),
                f["pinned"]?.jsonPrimitive?.booleanOrNull == true, f["archived"]?.jsonPrimitive?.booleanOrNull == true, f["unread"]?.jsonPrimitive?.booleanOrNull == true,
                ChatTurnSemantics.millis(ChatTurnSemantics.updatedSeconds(head)) ?: 0, f.string("state") ?: "done",
                if (going) (f["choices"] as? JsonArray).orEmpty().mapNotNull { (it as? JsonPrimitive)?.takeIf(JsonPrimitive::isString)?.content } else emptyList(), true,
                origin = f.string("origin"), routine = f.string("routine"), project = f.string("project"))
        }
        rebuildApprovals(available.map { it.id }.toSet())
        mutableArrivals.value = journal.all("send").mapNotNull { record ->
            if (!record.alive() || record.string("kind") != "open" || record.string("device") != identity.device || record.string("state") != null) return@mapNotNull null
            val sender = record.string("clientDevice") ?: return@mapNotNull null
            if (available.none { it.id == sender } || listOf("chat", "text", "choice", "project").any { record[it] != null }) return@mapNotNull null
            val url = record.string("url")?.takeIf { webUrl(it) } ?: return@mapNotNull null
            val sent = record.number("at")?.takeIf { it.isFinite() }?.times(1000)?.toLong() ?: return@mapNotNull null
            if (System.currentTimeMillis() - sent !in -300_000..43_200_000) return@mapNotNull null
            if (journal.hasReceipt("open/${identity.seal.account}/${identity.device}/${record.id}")) return@mapNotNull null
            SyncArrival(record.id, url, record.string("title") ?: url, record.string("space"), sender, sent)
        }.sortedBy { it.sentAt }
    }
    override suspend fun send(command: AgentSendCommand): AgentSendReceipt = withContext(dispatcher) {
        val identity = identity ?: throw AgentUnavailable("Join your Mac first"); val journal = journal ?: error("Sync unavailable")
        require(command.account == identity.seal.account && command.question.page?.isPrivate != true)
        require(command.expectedEpoch == null || command.expectedEpoch == epoch) { "Sync session changed. Send again." }
        require(client?.state !is SyncState.Refused) { "This device was removed from Sync" }
        val mac = mutableConnection.value.macs.firstOrNull { it.id == command.mac } ?: throw AgentUnavailable("Update Yab on your Mac before sending from Android")
        require(command.provider in mac.providers && (command.files.isEmpty() || mac.takesFiles)); AttachmentLimits.validate(command.files.map { it.bytes.size })
        require(command.question.words.toByteArray().size <= 524_288)
        val owner = command.owner
        command.project?.let { project ->
            val expected = command.projectLease ?: error(ChatProjectLease.CHANGED)
            expected.requireKind(ChatProjectLease.Kind.SEND)
            require(owner == null && expected.project == project && expected.mac == command.mac && expected.provider == command.provider &&
                expected.chat?.id == command.clientChat && expected.snapshot.device == identity.device &&
                identityLease()?.let { it.account == expected.snapshot.account && it.device == expected.snapshot.device && it.epoch == expected.snapshot.epoch } == true &&
                expected.current(mutableProjects.value, mutableConnection.value) && ChatProjects.supports(journal.record(RecordKey("commandcap", command.mac)), command.mac)) { ChatProjectLease.CHANGED }
        }
        if (owner != null) {
            require(owner.account == command.account && owner.mac == command.mac && owner.provider == command.provider)
            val head = journal.record(RecordKey("chat", owner.chat)) ?: error("The conversation is no longer available")
            require(head.string("device") == owner.mac && head.string("cli")?.let(::provider) == owner.provider)
        }
        val key = RecordKey("send", command.id)
        journal.record(key)?.let { existing ->
            require(existing.string("clientDevice") == identity.device && existing.string("clientChat") == command.clientChat && existing.string("device") == command.mac) { "Send identity changed" }
            return@withContext AgentSendReceipt(owner, remoteSend(existing))
        }
        val capturedProject = linkedMapOf<RecordKey, Record?>(key to null)
        command.project?.let { project ->
            val capKey = RecordKey("commandcap", command.mac); val cap = journal.record(capKey)
            val projectKey = RecordKey(ChatProjects.COLLECTION, project); val originalProject = journal.record(projectKey)
            require(ChatProjects.supports(cap, command.mac) && originalProject?.let { SyncProject.read(it) }?.takeUnless { it.archived } ==
                command.projectLease?.snapshot?.project(project)) { ChatProjectLease.CHANGED }
            capturedProject[capKey] = cap; capturedProject[projectKey] = originalProject
        }
        val writes = linkedMapOf<RecordKey, JsonObject>()
        val files = command.files.mapIndexed { index, file ->
            val digest = sha(file.bytes); require(file.file.digest.equals(digest, ignoreCase = true)) { "Attachment changed" }
            val parts = (0 until maxOf(file.bytes.size, 1) step 48_000).mapIndexed { n, start ->
                val id = "${command.id}/$index/$n"
                writes[RecordKey("sendpart", id)] = buildJsonObject { put("send", command.id); put("data", java.util.Base64.getEncoder().encodeToString(file.bytes.copyOfRange(start, minOf(start + 48_000, file.bytes.size)))) }; id
            }
            buildJsonObject { put("name", File(file.file.name).name); put("type", file.file.mime); put("size", file.bytes.size); put("digest", digest); put("parts", JsonArray(parts.map(::JsonPrimitive))) }
        }
        val fields = buildJsonObject {
            put("device", command.mac); put("at", System.currentTimeMillis() / 1000.0); put("clientDevice", identity.device); put("clientChat", command.clientChat); put("question", command.question.words)
            if (owner == null) { put("kind", "agent"); put("cli", wireProvider(command.provider)); put("agentText", questionText(command.question)) }
            else { put("chat", owner.chat); put("text", questionText(command.question)) }
            command.project?.let { put("project", it) }
            if (files.isNotEmpty()) put("files", JsonArray(files))
            if (command.selection.model != null || command.selection.effort != null) {
                require(capability(command.mac, "modelPick")); val selected = mac.models.firstOrNull { it.id == command.selection.model && it.provider == command.provider } ?: error("This model is unavailable")
                put("model", selected.id); command.selection.effort?.let { require(it in selected.efforts); put("effort", it) }
            }
        }
        require((fields.string("text") ?: fields.string("agentText") ?: "").toByteArray().size <= 524_288) { "Page context is too large" }
        command.project?.let { require(command.projectLease?.current(mutableProjects.value, mutableConnection.value) == true && identityLease()?.device == identity.device) { ChatProjectLease.CHANGED } }
        writes[key] = fields; journal.changeBatch(writes, capturedProject); client?.kick(); rebuild(); AgentSendReceipt(owner, mutableSends.value.firstOrNull { it.id == key.id })
    }
    private fun remoteSend(record: Record): RemoteSend? {
        val saved = identity ?: return null
        val send = ChatSend.read(record, saved.device) ?: return null
        if (mutableConnection.value.macs.none { it.id == send.device }) return null
        val head = send.chat?.let { journal?.record(RecordKey("chat", it)) }
        val provider = send.cli?.let(::provider) ?: head?.takeIf { it.alive() && it.string("device") == send.device }?.string("cli")?.let(::provider) ?: return null
        return RemoteSend(saved.seal.account, epoch, send.id, send.clientChat, send.device, provider, (send.at * 1000).toLong(),
            MacSendState.valueOf(send.state.name), send.question, send.files.map { ChatFile(it.name, it.type, it.size, it.digest) },
            sha(canonical(record.toJson()).toByteArray()), send.chat, send.reason,
            record.number("took")?.takeIf { it.isFinite() && it > 0 && it * 1000 <= Long.MAX_VALUE }?.times(1000)?.toLong(), send.project)
    }
    private fun checkedSend(expected: RemoteSend, sourceCurrent: () -> Boolean): ChatSend {
        val saved = identity ?: error("Join your Mac first")
        require(expected.account == saved.seal.account && expected.epoch == epoch && client?.state !is SyncState.Refused && sourceCurrent()) { "The account or conversation changed" }
        val record = journal?.record(RecordKey("send", expected.id)) ?: error("This request is no longer available")
        require(remoteSend(record) == expected) { "Your Mac already took or changed this request" }
        return ChatSend.read(record, saved.device) ?: error("This request cannot be read safely")
    }
    private fun restoredFiles(send: ChatSend, expected: MutableMap<RecordKey, Record?>): List<PreparedAttachment> = send.assemble { key ->
        journal?.record(key).also { expected[key] = it }
    }.map { (file, bytes) -> PreparedAttachment(ChatFile(file.name, file.type, file.size, file.digest), bytes) }
    override suspend fun cancelSend(expected: RemoteSend, sourceCurrent: () -> Boolean): MacSendDraft? = withContext(dispatcher) {
        val send = checkedSend(expected, sourceCurrent)
        if (send.state != ChatSend.State.WAITING) return@withContext null
        val captured = linkedMapOf<RecordKey, Record?>(send.record.key to send.record)
        val files = restoredFiles(send, captured)
        require(sourceCurrent()) { "The conversation changed" }
        journal!!.changeBatch(mapOf(send.record.key to JsonObject(send.record.visible + ("state" to JsonPrimitive("cancelled")))), captured)
        client?.kick(); rebuild(); MacSendDraft(send.question, files, expected.provider)
    }
    override suspend fun redirectPending(expected: RemoteSend, mac: String, clientChat: String, sourceCurrent: () -> Boolean): RemoteSend? = withContext(dispatcher) {
        val send = checkedSend(expected, sourceCurrent)
        require(send.state == ChatSend.State.WAITING && mac != send.device && clientChat.isNotBlank() && clientChat != send.clientChat) { "Only words still waiting can start on another Mac" }
        copySend(send, expected, mac, clientChat, newChat = true, cancelOld = true, sourceCurrent = sourceCurrent)
    }
    override suspend fun resendSend(expected: RemoteSend, sourceCurrent: () -> Boolean): RemoteSend? = withContext(dispatcher) {
        val send = checkedSend(expected, sourceCurrent)
        require(send.state in setOf(ChatSend.State.EXPIRED, ChatSend.State.FAILED)) { "This request has not expired or failed" }
        copySend(send, expected, send.device, send.clientChat, newChat = send.chat == null, cancelOld = false, sourceCurrent = sourceCurrent)
    }
    /** One explicit new command consumes the offered Mac; the persistent manual choice never changes. */
    private fun copySend(send: ChatSend, expected: RemoteSend, mac: String, clientChat: String, newChat: Boolean, cancelOld: Boolean, sourceCurrent: () -> Boolean): RemoteSend {
        val saved = identity ?: error("Sync changed"); val journal = journal ?: error("Sync unavailable")
        val target = mutableConnection.value.macs.firstOrNull { it.id == mac } ?: error("This Mac is no longer available")
        require(expected.provider in target.providers && (!cancelOld || target.availability.phase == MacPhase.UP)) { "This Mac cannot take the request now" }
        val capKey = RecordKey("commandcap", mac); val cap = journal.record(capKey) ?: error("Update Yab on this Mac")
        fun supports(field: String): Boolean = cap.alive() && cap.string("device") == mac && cap.stamps["device"]?.device == mac && cap.number(field) == 1.0 && cap.stamps[field]?.device == mac
        require(supports("androidSync") && supports("chatAgent") && (send.files.isEmpty() || supports("attachments"))) { "Update Yab on this Mac to send these files" }
        val captured = linkedMapOf<RecordKey, Record?>(send.record.key to send.record, capKey to cap)
        send.project?.takeIf { newChat }?.let { project ->
            require(ChatProjects.valid(project) && ChatProjects.supports(cap, mac)) { "This Mac cannot start this project chat" }
            val projectKey = RecordKey(ChatProjects.COLLECTION, project)
            val originalProject = journal.record(projectKey)
            require(originalProject?.let { SyncProject.read(it) }?.archived == false) { ChatProjects.MISSING }
            captured[projectKey] = originalProject
        }
        if (!newChat) {
            val headKey = RecordKey("chat", send.chat ?: error("The conversation changed")); val head = journal.record(headKey)
            require(head?.alive() == true && head.string("device") == mac && head.string("cli")?.let(::provider) == expected.provider) { "The conversation owner changed" }
            captured[headKey] = head
        }
        val files = restoredFiles(send, captured)
        val id = UUID.randomUUID().toString(); val key = RecordKey("send", id); captured[key] = null
        val writes = linkedMapOf<RecordKey, JsonObject>()
        val described = files.mapIndexed { index, file ->
            val parts = (0 until maxOf(file.bytes.size, 1) step 48_000).mapIndexed { n, start ->
                val part = RecordKey("sendpart", "$id/$index/$n"); captured[part] = null
                writes[part] = buildJsonObject { put("send", id); put("data", java.util.Base64.getEncoder().encodeToString(file.bytes.copyOfRange(start, minOf(start + 48_000, file.bytes.size)))) }; part.id
            }
            buildJsonObject { put("name", File(file.file.name).name); put("type", file.file.mime); put("size", file.bytes.size); put("digest", file.file.digest); put("parts", JsonArray(parts.map(::JsonPrimitive))) }
        }
        if (cancelOld) writes[send.record.key] = JsonObject(send.record.visible + ("state" to JsonPrimitive("cancelled")))
        writes[key] = buildJsonObject {
            put("device", mac); put("clientDevice", saved.device); put("clientChat", clientChat); put("question", send.question); put("at", System.currentTimeMillis() / 1000.0)
            if (newChat) { put("kind", "agent"); put("cli", wireProvider(expected.provider)); put("agentText", send.prompt) }
            else { put("chat", send.chat!!); put("text", send.prompt) }
            send.project?.takeIf { newChat }?.let { put("project", it) }
            if (described.isNotEmpty()) put("files", JsonArray(described))
            val model = send.record.string("model")
            if (mac == send.device && model != null && supports("modelPick") && target.models.any { it.id == model && it.provider == expected.provider }) {
                put("model", model)
                send.record.string("effort")?.takeIf { effort -> target.models.any { it.id == model && effort in it.efforts } }?.let { put("effort", it) }
            }
        }
        require(sourceCurrent() && identity?.device == saved.device && epoch == expected.epoch) { "The account or conversation changed" }
        journal.changeBatch(writes, captured); client?.kick(); rebuild()
        return mutableSends.value.firstOrNull { it.id == id } ?: error("The new request could not be read")
    }
    private suspend fun <T> chatMutation(expected: ChatMutationLease?, operation: suspend () -> T): T =
        dispatchChatMutation(dispatcher, expected, {
            identityLease()?.takeIf { client?.state !is SyncState.Refused }?.let { ChatMutationIdentity(it.account, it.device, it.epoch) }
        }, operation)
    override suspend fun moveToProject(owner: RemoteOwner, project: String?, expected: ChatProjectLease): Boolean = withContext(dispatcher) {
        expected.requireKind(ChatProjectLease.Kind.MOVE)
        val saved = identityLease() ?: error(ChatProjectLease.CHANGED)
        val originalChat = expected.chat ?: error(ChatProjectLease.CHANGED)
        val journal = journal ?: error("Sync unavailable")
        require(saved.account == expected.snapshot.account && saved.device == expected.snapshot.device && saved.epoch == expected.snapshot.epoch &&
            originalChat.owner == owner && !originalChat.privateOrigin && !originalChat.ephemeral && expected.project == project &&
            expected.current(mutableProjects.value, mutableConnection.value)) { ChatProjectLease.CHANGED }
        val key = RecordKey("chat", owner.chat); val head = journal.record(key) ?: error("Chat unavailable")
        val capKey = RecordKey("commandcap", owner.mac); val cap = journal.record(capKey)
        require(owner.account == saved.account && head.alive() && head.id.startsWith("a:") && head.string("kind") == "agent" && head.string("device") == owner.mac &&
            head.string("cli")?.let(::provider) == owner.provider && head.string("project") == originalChat.project &&
            capability(owner.mac, "chatMetadata") && ChatProjects.supports(cap, owner.mac)) { ChatProjectLease.CHANGED }
        val captured = linkedMapOf<RecordKey, Record?>(key to head, capKey to cap)
        project?.let { id ->
            val target = RecordKey(ChatProjects.COLLECTION, id); val record = journal.record(target)
            require(record?.let { SyncProject.read(it) }?.takeUnless { it.archived } == expected.snapshot.project(id)) { ChatProjectLease.CHANGED }
            captured[target] = record
        }
        val fields = JsonObject(head.visible + ("project" to (project?.let(::JsonPrimitive) ?: JsonNull)))
        require(identityLease() == saved && expected.current(mutableProjects.value, mutableConnection.value)) { ChatProjectLease.CHANGED }
        journal.changeBatch(mapOf(key to fields), captured); client?.kick(); rebuild(); true
    }
    override suspend fun patchChat(owner: RemoteOwner, flags: ChatFlags): Boolean = patchChatChecked(owner, flags, null)
    override suspend fun patchChat(owner: RemoteOwner, flags: ChatFlags, expected: ChatMutationLease): Boolean = patchChatChecked(owner, flags, expected)
    private suspend fun patchChatChecked(owner: RemoteOwner, flags: ChatFlags, expected: ChatMutationLease?): Boolean = chatMutation(expected) {
        expected?.requireOwner(owner)
        val saved = identity ?: return@chatMutation false; val journal = journal ?: return@chatMutation false
        require(owner.account == saved.seal.account && mutableConnection.value.macs.any { it.id == owner.mac }) { "Chat owner changed" }
        if (expected == null && !capability(owner.mac, "chatMetadata")) return@chatMutation false
        val key = RecordKey("chat", owner.chat)
        val head = journal.record(key) ?: if (expected == null) return@chatMutation false else error("Chat unavailable")
        if (!head.alive()) { if (expected == null) return@chatMutation false else error("Chat unavailable") }
        require(head.string("device") == owner.mac && head.string("cli")?.let(::provider) == owner.provider)
        if (!capability(owner.mac, "chatMetadata")) return@chatMutation false
        val fields = buildJsonObject {
            head.visible.forEach { (key, value) -> put(key, value) }
            flags.pinned?.let { put("pinned", if (it) JsonPrimitive(true) else JsonNull) }
            flags.archived?.let { put("archived", if (it) JsonPrimitive(true) else JsonNull) }
            flags.unread?.let { put("unread", if (it) JsonPrimitive(true) else JsonNull) }
            flags.title?.trim()?.takeIf(String::isNotEmpty)?.let { put("title", it.take(300)) }
        }
        expected?.requireIdentity(identityLease()?.let { ChatMutationIdentity(it.account, it.device, it.epoch) })
        journal.changeConditionally(key, fields, mapOf(key to head)); client?.kick(); rebuild(); true
    }
    override suspend fun retractPending(clientChat: String): Boolean = retractPendingChecked(clientChat, null)
    override suspend fun retractPending(clientChat: String, expected: ChatMutationLease): Boolean = retractPendingChecked(clientChat, expected)
    private suspend fun retractPendingChecked(clientChat: String, expected: ChatMutationLease?): Boolean = chatMutation(expected) {
        val saved = identity ?: return@chatMutation false; val journal = journal ?: return@chatMutation false
        if (expected != null) {
            require(expected.chat.id == clientChat && expected.chat.owner == null && !expected.chat.privateOrigin) { ChatMutationLease.CHANGED }
            val captured = expected.chat.pendingSend ?: return@chatMutation false
            require(captured.clientChat == clientChat) { ChatMutationLease.CHANGED }
            val send = checkedSend(captured, expected::sourceCurrent)
            if (send.state != ChatSend.State.WAITING) return@chatMutation false
            expected.requireIdentity(identityLease()?.let { ChatMutationIdentity(it.account, it.device, it.epoch) })
            journal.changeBatch(mapOf(send.record.key to JsonObject(send.record.visible + ("state" to JsonPrimitive("cancelled")))), mapOf(send.record.key to send.record))
            client?.kick(); rebuild(); return@chatMutation true
        }
        val pending = journal.all("send").filter { it.alive() && it.string("clientDevice") == saved.device && it.string("clientChat") == clientChat && it.string("action") == null }
        if (pending.any { it.string("state") in setOf("taken", "processing") }) return@chatMutation false
        val waiting = pending.filter { it.string("state") == null }
        journal.changeBatch(waiting.associate { it.key to JsonObject(it.visible + ("state" to JsonPrimitive("cancelled"))) }, waiting.associate { it.key to it })
        client?.kick(); rebuild(); true
    }
    override suspend fun stop(owner: RemoteOwner) { control(owner, "stop") }
    override suspend fun delete(owner: RemoteOwner) { control(owner, "delete") }
    override suspend fun stop(owner: RemoteOwner, expected: ChatMutationLease) { control(owner, "stop", expected) }
    override suspend fun delete(owner: RemoteOwner, expected: ChatMutationLease) { control(owner, "delete", expected) }
    private suspend fun control(owner: RemoteOwner, action: String, expected: ChatMutationLease? = null) = chatMutation(expected) {
        expected?.requireOwner(owner)
        val identity = identity ?: error("Sync is off"); val journal = journal ?: error("Sync unavailable")
        require(owner.account == identity.seal.account && capability(owner.mac, "androidSync") && capability(owner.mac, "chatControl"))
        val head = journal.record(RecordKey("chat", owner.chat)) ?: error("Chat unavailable")
        require(head.string("device") == owner.mac && head.string("cli")?.let(::provider) == owner.provider && owner.chat.startsWith("a:"))
        if (expected != null) {
            require(head.alive()) { "Chat unavailable" }
            expected.requireIdentity(identityLease()?.let { ChatMutationIdentity(it.account, it.device, it.epoch) })
        }
        val key = RecordKey("send", UUID.randomUUID().toString())
        val fields = buildJsonObject { put("device", owner.mac); put("chat", owner.chat); put("action", action); put("clientDevice", identity.device); put("at", System.currentTimeMillis() / 1000.0) }
        if (expected == null) journal.change(key, fields)
        else journal.changeBatch(mapOf(key to fields), mapOf(key to null, head.key to head))
        client?.kick()
    }
    override suspend fun answerApproval(answer: ApprovalAnswer): Unit = withContext(dispatcher) {
        val interaction = answer.requireCurrentInteraction()
        val identity = identity ?: error("Sync is off"); val journal = journal ?: error("Sync unavailable")
        val lease = identityLease() ?: error("Sync ownership changed")
        require(answer.expectedEpoch == null || answer.expectedEpoch == lease.epoch) { "Sync ownership changed" }
        require(answer.request.sourceEpoch == null || answer.request.sourceEpoch == lease.epoch) { "This approval belongs to an earlier Sync session" }
        val binding = approvalBindings[answer.request.id] ?: error("This approval expired or was answered")
        require(answer.request == binding.request && answer.request.account == identity.seal.account && answer.request.expiresAt > System.currentTimeMillis())
        require(client?.state !is SyncState.Refused && mutableConnection.value.macs.any { it.id == answer.request.mac }) { "This approval's owner is no longer available" }
        require(capability(answer.request.mac, "androidSync"))
        require(!answer.approved || answer.proof?.let { System.currentTimeMillis() - it.authenticatedAt in 0..60_000 } == true) { "Unlock verification expired" }
        require(if (answer.approved && answer.request.choices.isNotEmpty()) answer.choice in answer.request.choices else answer.choice == null)
        val writes = linkedMapOf<RecordKey, JsonObject>(); val added = mutableListOf<String>()
        var card: String? = null; var place: String? = null
        if (answer.approved) {
            answer.picks.validate(answer.request.payment); require(answer.picks.added.isEmpty()) { "Only this device can mint new Wallet records" }
            val pay = answer.request.payment
            card = answer.picks.card; place = answer.picks.place
            require(card == null || pay?.takesCard == true); require(place == null || pay?.takesPlace == true)
            answer.picks.newCard?.let { value ->
                val id = UUID.randomUUID().toString(); writes[RecordKey("card", id)] = Wallet.card(id, value.number, value.csc, value.name, value.month, value.year, identity.seal)
                card = id; added += id
            }
            answer.picks.newPlace?.let { value ->
                val id = UUID.randomUUID().toString(); writes[RecordKey("address", id)] = Wallet.address(id, value.name, value.street, value.city, value.postal, identity.seal)
                place = id; added += id
            }
        }
        val body = buildJsonObject {
            put("id", answer.request.id); put("account", identity.seal.account); put("mac", answer.request.mac); put("device", identity.device)
            put("requestDigest", binding.digest); put("yes", answer.approved); put("at", System.currentTimeMillis() / 1000.0)
            if (answer.approved) {
                put("proved", true); answer.choice?.let { put("choice", it) }; binding.detailDigest?.let { put("detailDigest", it) }
                card?.let { put("card", it) }; place?.let { put("place", it) }; if (added.isNotEmpty()) put("added", JsonArray(added.map(::JsonPrimitive)))
            }
        }
        val answerKey = RecordKey("assistantanswer", answer.request.id)
        val expected = mutableMapOf(binding.record.key to binding.record, answerKey to null)
        expected[RecordKey("assistantdetail", answer.request.id)] = binding.detail
        writes[answerKey] = buildJsonObject { put("body", canonical(body)) }
        require(identityLease() == lease) { "Sync ownership changed before answering" }
        // Lock order is approval ticket -> journal. Revoke never takes the journal monitor.
        // Only this synchronous local batch is serialized with STOP/disposal.
        interaction.withCurrent {
            require(answer.authenticationIdentity == null || answer.authenticationIdentity ==
                ApprovalAuthenticationIdentity(lease.account, lease.device, lease.epoch)) { "Approval authentication ownership changed" }
            require(identityLease() == lease) { "Sync ownership changed before answering" }
            journal.changeBatch(writes, expected)
        }
        if (answer.approved) {
            answeredApprovals[answer.request.id] = binding
            while (answeredApprovals.size > 32) answeredApprovals.remove(answeredApprovals.keys.first())
        }
        client?.kick(); rebuild()
    }
    private fun rebuildApprovals(known: Set<String>) {
        val identity = identity ?: return; val journal = journal ?: return
        val bindings = journal.all("assistantapproval").mapNotNull { record -> runCatching {
            require(record.schema == 1 && record.alive() && record.fields.keys == setOf("body"))
            val writer = record.stamps["body"]?.device ?: error("Missing owner"); require(writer in known)
            val text = record.string("body") ?: error("Missing body"); require(text.toByteArray().size <= 16_384)
            val body = Json.parseToJsonElement(text).jsonObject
            require(body.string("id").equals(record.id, ignoreCase = true) && body.string("account") == identity.seal.account && body.string("mac") == writer)
            require(listOf("account", "mac", "assistant", "session", "permit").all { body.string(it)?.let { value -> value.isNotEmpty() && value.toByteArray().size <= 256 } == true })
            val tab = body.string("tab") ?: error("Missing place")
            require(runCatching { UUID.fromString(tab) }.isSuccess || tab.startsWith("chat:") && tab.toByteArray().size in 6..261)
            val issued = body.number("issued") ?: error("Missing date"); val expires = body.number("expires") ?: error("Missing expiry")
            require(issued.isFinite() && expires.isFinite() && expires > issued && expires - issued <= 86_400 && expires * 1000 > System.currentTimeMillis())
            body["seen"]?.takeUnless { it == JsonNull }?.jsonObject?.let { seen -> require(seen.string("device") == writer && seen.number("at")?.let { it.isFinite() && it >= issued - 300 } == true) }
            require(runCatching { UUID.fromString(record.id) }.isSuccess)
            require(journal.record(RecordKey("assistantanswer", record.id))?.alive() != true)
            val digest = requestDigest(body)
            val detail = journal.record(RecordKey("assistantdetail", record.id))
            val detailBody = detail?.takeIf { it.alive() }?.let { require(it.schema == 1 && it.fields.keys == setOf("body") && it.stamps["body"]?.device == writer); Json.parseToJsonElement(it.string("body")!!).jsonObject.also { d -> require(d.string("id").equals(record.id, ignoreCase = true)); require(canonical(d).toByteArray().size <= 60_000) } }
            val detailDigest = detailBody?.let { ApprovalCanonical.detailDigest(it) }
            val title = body.string("title") ?: error("Missing title"); require(title.isNotEmpty() && title.toByteArray().size <= 300)
            val lines = (body["lines"] as? JsonArray ?: error("Missing lines")).map { it.jsonPrimitive.content }; require(lines.size <= 20 && lines.all { it.toByteArray().size <= 2000 })
            val choices = (body["choices"] as? JsonArray).orEmpty().map { it.jsonPrimitive.content }; require((body["choices"] == null || body["choices"] == JsonNull || choices.isNotEmpty()) && choices.size <= 3 && choices.distinct().size == choices.size && choices.all { it.isNotEmpty() && it.toByteArray().size <= 256 })
            val revision = sha((digest + (detailDigest ?: "")).toByteArray()).take(15).toLong(16)
            val pay = detailBody?.get("pay") as? JsonObject
            val mails = (detailBody?.get("mails") as? JsonArray).orEmpty().map { value -> val m = value.jsonObject
                ApprovalMail(person(m["from"]), people(m["to"]), m.string("subject") ?: "", m.string("body") ?: "",
                    people(m["cc"]), people(m["bcc"]), (m["files"] as? JsonArray).orEmpty().map { approvalFile(it.jsonObject) }, m.number("date"))
            }
            require(mails.size <= 20)
            val files = (detailBody?.get("files") as? JsonArray).orEmpty().map { approvalFile(it.jsonObject) }
            val allFiles = files + mails.flatMap { it.files }
            require(allFiles.size <= 20 && allFiles.map { it.id }.distinct().size == allFiles.size)
            val previews = allFiles.flatMap { file -> (0 until file.previewPages).mapNotNull { page ->
                val id = "${record.id.lowercase()}.${file.id}.$page"
                journal.record(RecordKey("assistantpreview", id))?.let { preview -> runCatching {
                    require(preview.alive() && preview.schema == 1 && preview.fields.keys == setOf("body") && preview.stamps["body"]?.device == writer)
                    val p = Json.parseToJsonElement(preview.string("body")!!).jsonObject
                    val jpeg = p.string("jpeg") ?: error("Missing picture"); require(p.string("id") == id && jpeg.length <= 72_000)
                    require(java.util.Base64.getDecoder().decode(jpeg).size <= 54_000)
                    ApprovalPreview(file.id, page, jpeg)
                }.getOrNull() }
            } }
            val payment = pay?.let { p ->
                val cards = (p["cards"] as? JsonArray).orEmpty().map { value -> val c = value.jsonObject; ApprovalCard(c.string("id") ?: error("Missing card"), c.string("brand") ?: "", c.string("last4") ?: "", c.string("name") ?: "") }
                val places = (p["places"] as? JsonArray).orEmpty().map { value -> val a = value.jsonObject; ApprovalPlace(a.string("id") ?: error("Missing address"), a.string("line") ?: "", a.string("who") ?: "") }
                require(cards.size <= 12 && places.size <= 12 && cards.map { it.id }.distinct().size == cards.size && places.map { it.id }.distinct().size == places.size)
                val card = p.string("card"); val place = p.string("place")
                require(card == null || cards.any { it.id == card }); require(place == null || places.any { it.id == place })
                ApprovalPayment(p.string("site") ?: "", p.string("item") ?: "", p.string("amount") ?: "", delivery = p.string("delivery") ?: "",
                    cards = cards, places = places, card = card, place = place, takesCard = p["takesCard"]?.jsonPrimitive?.booleanOrNull == true, takesPlace = p["takesPlace"]?.jsonPrimitive?.booleanOrNull == true)
            }
            val permit = body.string("permit")!!
            val targetPerson = person(detailBody?.get("person")).ifBlank { null }
            val kind = ApprovalSemantics.kind(permit, payment, mails, files, targetPerson, detailBody?.string("text"), choices)
            val verb = ApprovalSemantics.verb(detailBody?.string("verb"), kind, tab, permit, payment, mails)
            val request = ApprovalRequest(record.id, identity.seal.account, writer, revision, (expires * 1000).toLong(), title.substringBefore(':'), title.substringAfter(':', title).trim(), lines.take(3).filterNot { it.contains('\n') }.joinToString(" · ").take(180),
                kind, lines, choices, payment, mails, files, previews, targetPerson, detailBody?.string("text"), verb, digest, detailDigest, permit, tab, (issued * 1000).toLong(),
                sourceEpoch = epoch, sourceSession = body.string("session"), sourceIssuedAt = issued, sourceVerb = detailBody?.string("verb"))
            record.id to ApprovalBinding(request, record, body, digest, detail, detailBody, detailDigest)
        }.getOrNull() }.toMap()
        approvalBindings = bindings; mutableApprovals.value = ApprovalContent.order(bindings.values.map { it.request })
        mutableApprovalResults.value = answeredApprovals.values.mapNotNull { answered ->
            if (answered.request.account != identity.seal.account || answered.request.mac !in known) null else journal.record(RecordKey("assistantresult", answered.request.id))?.let { ApprovalResultCodec.read(it, answered.request) }
        }
        approvalExpiry?.cancel()
        val expected = client
        mutableApprovals.value.minOfOrNull { it.expiresAt }?.let { expiry -> approvalExpiry = scope.launch {
            delay((expiry - System.currentTimeMillis() + 1).coerceAtLeast(1))
            if (client === expected) rebuild()
        } }
    }
    private suspend fun safely(action: suspend () -> Unit) { try { action() } catch (error: CancellationException) { throw error } catch (error: Exception) { mutableUi.update { it.copy(error = error.message ?: "Sync unavailable") } } }
    override fun close() { synchronized(identityLock) {
        if (closing == null) {
            operations.invalidate(); joiningOperation = null
            mutableUi.value = SyncUiState()
            mutableProjects.value = ChatProjectsSnapshot.publish(mutableProjects.value, null, null, epoch, emptyList())
            closing = scope.launch {
                try { synchronized(identityLock) { epoch++ }; pairing?.close(); rosterTimer?.cancel(); client?.close(); journal?.close() }
                finally { scope.cancel(); dispatcher.close() }
            }
        }
    } }
    internal suspend fun awaitClosedForTests() {
        check(BuildConfig.DEBUG)
        close(); val job = synchronized(identityLock) { checkNotNull(closing) }
        withTimeout(10_000) { job.join() }
    }
    companion object {
        private fun provider(value: String): AgentProvider? = AgentProvider.fromWire(value)
        private fun wireProvider(value: AgentProvider): String = value.wire
        private fun questionText(question: LocalQuestion): String = question.page?.let { "${question.words}\n\nPage: ${it.title}\n${it.url}\n\n${it.text}" } ?: question.words
        private fun sha(data: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(data).joinToString("") { "%02x".format(it.toInt() and 255) }
        private fun requestDigest(body: JsonObject): String = ApprovalCanonical.requestDigest(body)
        private fun canonical(value: JsonElement): String = when (value) { is JsonObject -> value.entries.sortedBy { it.key }.joinToString(",", "{", "}") { JsonPrimitive(it.key).toString() + ":" + canonical(it.value) }; is JsonArray -> value.joinToString(",", "[", "]") { canonical(it) }; else -> value.toString() }
        private fun JsonObject.string(name: String): String? = (get(name) as? JsonPrimitive)?.takeIf { it.isString }?.content
        private fun JsonObject.number(name: String): Double? = (get(name) as? JsonPrimitive)?.takeUnless { it.isString }?.doubleOrNull
        private fun person(value: JsonElement?): String = (value as? JsonObject)?.let { p -> listOfNotNull(p.string("name")?.takeIf { it.isNotBlank() }, p.string("address")?.takeIf { it.isNotBlank() }).distinct().joinToString(" · ") } ?: ""
        private fun people(value: JsonElement?): List<String> = (value as? JsonArray).orEmpty().map(::person)
        private fun approvalFile(f: JsonObject): ApprovalFile = ApprovalFileCodec.read(f)
        private fun Record.string(name: String): String? = visible.string(name)
        private fun Record.number(name: String): Double? = visible.number(name)
        private fun webUrl(text: String, excludeLocal: Boolean = false): Boolean {
            if (text.toByteArray().size > 8192 || text.any(Char::isISOControl)) return false
            val uri = runCatching { java.net.URI(text) }.getOrNull() ?: return false
            val host = uri.host?.lowercase() ?: return false
            return uri.scheme?.lowercase() in setOf("http", "https") && uri.rawUserInfo == null && host.isNotEmpty() &&
                (!excludeLocal || host !in setOf("localhost", "0.0.0.0", "::1", "[::1]") && !host.endsWith(".localhost") && !host.startsWith("127."))
        }
    }
}
