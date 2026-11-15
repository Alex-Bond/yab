package dev.yab.sync

import dev.yab.browser.model.*
import dev.yab.core.sync.Order
import dev.yab.core.sync.Record
import dev.yab.core.sync.RecordKey
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
import java.io.Closeable
import java.net.URI
import java.util.UUID

/** One direction at a time: imported state becomes the baseline before observing the UI again. */
@OptIn(FlowPreview::class)
class BrowserSyncBinding(private val browser: BrowserController, private val sync: AndroidSyncBridge, scope: CoroutineScope,
                         private val persistence: BrowserRepository? = null) : Closeable {
    private var account: String? = null
    private var baseline: BrowserSnapshot? = null
    private var front: List<Any?>? = null
    private var joined = false
    private var localSearch = false
    private var checkpoint: BrowserSyncCheckpointStore? = null
    private var checkpointLoaded = false
    private val knownLocalHashes = linkedSetOf<String>()
    private val job = scope.launch {
        combine(browser.state, sync.accountRecords) { state, image -> state to image }
            .onEach { browser.publicSnapshot()?.let { knownLocalHashes.add(BrowserSnapshotHash.of(it)) } }
            .debounce(120).collect { (state, image) ->
            fun currentIdentity(): Boolean = sync.accountRecords.value.let { current ->
                current.account == image.account && current.epoch == image.epoch && current.device == image.device && !current.removed
            }
            if (sync.accountRecords.value.let { it.account != image.account || it.epoch != image.epoch || it.device != image.device }) return@collect
            val records = image.records
            val shown = state.tab
            val currentFront = listOf(shown?.url, shown?.title, shown?.id, state.space?.id, state.space?.isPrivate == true)
            if (front != currentFront) { front = currentFront; sync.updateFront(shown?.url, shown?.title.orEmpty(), shown?.id, state.space?.id, state.space?.isPrivate == true) }
            var current = browser.publicSnapshot() ?: return@collect
            if (image.account != account) {
                val previous = baseline
                if (account != null && !localSearch && previous != null && current.settings.searchEngine == previous.settings.searchEngine && current.settings.customSearchTemplate == previous.settings.customSearchTemplate) {
                    current = current.copy(settings = current.settings.copy(searchEngine = SearchEngine.GOOGLE, customSearchTemplate = ""))
                }
                browser.applySyncedSnapshot(current)
                account = image.account; baseline = null; joined = false; checkpointLoaded = false; checkpoint = null
                knownLocalHashes.clear(); knownLocalHashes.add(BrowserSnapshotHash.of(current))
                localSearch = current.settings.searchEngine != SearchEngine.GOOGLE || current.settings.customSearchTemplate.isNotBlank()
            }
            if (image.removed) { browser.applySyncedSnapshot(current); joined = false; return@collect }
            val expectedAccount = image.account ?: return@collect
            val own = image.device ?: return@collect
            // IO yields to browsing. Never apply a projection made before a newer local edit.
            var sourceSnapshot = browser.publicSnapshot() ?: return@collect
            fun currentSource(): Boolean = currentIdentity() && browser.publicSnapshot() == sourceSnapshot
            if (!currentSource() || !joined && image.phase != "live") return@collect
            try {
                if (!checkpointLoaded) {
                    checkpoint = sync.browserCheckpoint()
                    if (!currentSource()) return@collect
                    val saved = withContext(Dispatchers.IO) { checkpoint?.load() }
                    if (!currentSource()) return@collect
                    if (saved != null) {
                        baseline = saved.target; localSearch = saved.localSearch
                        val observed = knownLocalHashes.toList(); knownLocalHashes.clear(); knownLocalHashes.addAll(saved.knownLocalHashes); knownLocalHashes.addAll(observed)
                        val restored = saved.restore(current)
                        if (restored != current) {
                            current = restored; browser.applySyncedSnapshot(restored)
                            sourceSnapshot = browser.publicSnapshot() ?: return@collect
                        }
                    }
                    checkpointLoaded = true
                }
                val before = baseline
                if (before != null && (before.settings.searchEngine != current.settings.searchEngine || before.settings.customSearchTemplate != current.settings.customSearchTemplate)) localSearch = true
                val ready = BrowserSyncCodec.restoreClosedIds(current, before, records)
                val changes = BrowserSyncCodec.changes(ready, before, records, own)
                if (!currentSource()) return@collect
                if (changes.fields.isNotEmpty() || changes.removed.isNotEmpty()) sync.publishBrowser(changes.fields, changes.removed,
                    expectedAccount = expectedAccount, expectedEpoch = image.epoch, paintEdits = changes.paintEdits)
                if (!currentSource()) return@collect
                val received = sync.accountRecords.value.records
                val projected = BrowserSyncCodec.project(ready, received, own, importSearch = !localSearch)
                knownLocalHashes.add(BrowserSnapshotHash.of(current)); knownLocalHashes.add(BrowserSnapshotHash.of(projected))
                // Once the sole browser writer reached a known image, older interrupted images can be forgotten.
                val diskHash = withContext(Dispatchers.IO) { persistence?.load()?.let(BrowserSnapshotHash::of) }
                if (!currentSource()) return@collect
                if (diskHash != null && diskHash in knownLocalHashes) {
                    val hashes = knownLocalHashes.toList(); val index = hashes.indexOf(diskHash)
                    if (index > 0) { knownLocalHashes.clear(); knownLocalHashes.addAll(hashes.drop(index)) }
                }
                val savedTarget = BrowserSyncCheckpoint(account = expectedAccount, device = own,
                    target = projected, knownLocalHashes = knownLocalHashes.toList(), localSearch = localSearch)
                withContext(Dispatchers.IO) { checkpoint?.save(savedTarget) }
                if (!currentSource()) return@collect
                baseline = projected; joined = true
                // Disk/sync input contains local visits only; imported display rows alone are not a UI change.
                if (projected != current.copy(history = browser.state.value.history)) browser.applySyncedSnapshot(projected)
            } catch (error: CancellationException) { throw error }
            catch (error: Exception) { if (currentSource()) browser.message("Sync could not save this change. Your local tabs are still here.") }
        }
    }
    override fun close() { job.cancel() }
}

/** Pure mapping keeps Mac-only fields in the journal and never reconciles account-wide absence. */
object BrowserSyncCodec {
    data class Changes(val fields: Map<RecordKey, JsonObject>, val removed: Set<RecordKey>,
        val paintEdits: Map<RecordKey, BrowserPaintEdit> = emptyMap())
    private fun Record.text(key: String) = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
    private fun Record.number(key: String) = (this[key] as? JsonPrimitive)?.takeUnless { it.isString }?.doubleOrNull
    private fun Record.flag(key: String) = (this[key] as? JsonPrimitive)?.booleanOrNull == true
    private fun tabPlace(record: Record): TabPlace = when { record.text("pin") != null -> TabPlace.PINNED; record.flag("kept") -> TabPlace.KEPT; else -> TabPlace.TODAY }
    private fun web(text: String): Boolean = runCatching { URI(text).let { it.scheme in setOf("http", "https") && !it.host.isNullOrEmpty() && it.rawUserInfo == null } }.getOrDefault(false)
    private fun key(collection: String, id: String) = RecordKey(collection, id)
    private fun JsonObject.text(name: String): String? = (get(name) as? JsonPrimitive)?.takeIf { it.isString }?.content

    fun restoreClosedIds(current: BrowserSnapshot, before: BrowserSnapshot?, records: List<Record>): BrowserSnapshot {
        if (before == null) return current
        val oldIds = before.spaces.flatMap { it.tabs }.map { it.id }.toSet()
        val dead = records.filter { it.collection == "tab" && !it.alive() }.map { it.id }.toSet()
        val remap = current.spaces.flatMap { it.tabs }.filter { it.id !in oldIds && it.id in dead }.associate { it.id to UUID.randomUUID().toString() }
        if (remap.isEmpty()) return current
        return current.copy(spaces = current.spaces.map { space -> space.copy(tabs = space.tabs.map { tab ->
            tab.copy(id = remap[tab.id] ?: tab.id, openerId = tab.openerId?.let { remap[it] ?: it })
        }, currentTabId = space.currentTabId?.let { remap[it] ?: it }, keptOrder = space.keptOrder.map { key ->
            if (key.startsWith("tab:")) remap[key.removePrefix("tab:")]?.let { "tab:$it" } ?: key else key
        }) }, recency = current.recency.mapValues { (_, ids) -> ids.map { remap[it] ?: it } })
    }

    fun changes(current: BrowserSnapshot, before: BrowserSnapshot?, records: List<Record>, own: String, now: Long = System.currentTimeMillis()): Changes {
        require(current.spaces.none { it.isPrivate || it.tabs.any(BrowserTab::isPrivate) })
        val wire = records.associateBy { it.key }; val oldSpaces = before?.spaces.orEmpty().associateBy { it.id }
        val oldTabs = before?.spaces.orEmpty().flatMap { it.tabs }.associateBy { it.id }
        val fields = linkedMapOf<RecordKey, JsonObject>(); val removed = mutableSetOf<RecordKey>()
        val paintEdits = linkedMapOf<RecordKey, BrowserPaintEdit>()
        val spaceOrders = Order.assign(current.spaces.map { it.id }, records.filter { it.collection == "space" }.mapNotNull { row -> row.text("order")?.let { row.id to it } }.toMap())
        for (space in current.spaces) {
            val existing = wire[key("space", space.id)]; val old = oldSpaces[space.id]
            val patch = buildJsonObject {
                if (existing == null || old != null && old.name != space.name) put("name", space.name)
                if (existing == null) put("icon", space.emoji)
                else if (old != null && old.emoji != space.emoji) {
                    val synced = existing.text("icon").orEmpty()
                    val icon = SpaceSymbols.wire(space.emoji, synced)
                    // A receive may already carry this pick or its original Mac symbol.
                    if (icon != synced) {
                        put("icon", icon)
                        put("iconChoice", icon)
                        put("iconChoiceID", UUID.randomUUID().toString())
                    }
                }
                if (existing == null || old != null && old.ownSignIns != space.ownSignIns) put("ownSignIns", space.ownSignIns)
                if (existing == null) put("paint", space.look ?: buildJsonObject {
                    put("swatch", "custom"); put("color", "#%06X".format(space.color and 0xffffff))
                    put("grain", false); put("grainAmount", 0); put("transparency", 0); put("colors", JsonArray(emptyList()))
                }) else if (old != null && (old.color != space.color || old.look != space.look)) {
                    val opened = BrowserSpaceLook.from(old.look, old.color)
                    var edited = BrowserSpaceLook.from(space.look, space.color)
                    if (old.color != space.color && old.look == space.look) edited = edited.palette(space.color, edited.colors)
                    val changed = linkedMapOf<String, JsonElement?>()
                    for (name in listOf("swatch", "color", "colors", "grain", "grainAmount", "transparency", "drawings", "drawingsStrength")) {
                        if (opened.raw[name] != edited.raw[name]) changed[name] = edited.raw[name]
                    }
                    if (changed.isNotEmpty()) {
                        val edit = BrowserPaintEdit(changed, edited.raw)
                        put("paint", BrowserSyncPublication.mergePaint(existing["paint"] as? JsonObject, edit))
                        paintEdits[key("space", space.id)] = edit
                    }
                }
                if (existing == null || old != null && before?.spaces.orEmpty().map { it.id } != current.spaces.map { it.id }) put("order", spaceOrders.getValue(space.id))
            }
            if (patch.isNotEmpty()) fields[key("space", space.id)] = patch
            val folderOrders = Order.assign(space.folders.map { it.id }, records.filter { it.collection == "folder" && it.text("parent") == space.id }.mapNotNull { row -> row.text("order")?.let { row.id to it } }.toMap())
            for (folder in space.folders) {
                val had = old?.folders?.firstOrNull { it.id == folder.id }; val record = wire[key("folder", folder.id)]
                val changed = buildJsonObject {
                    if (record == null || had != null && had.name != folder.name) put("name", folder.name)
                    if (record == null || had != null && had.parentId != folder.parentId) put("folder", folder.parentId?.let(::JsonPrimitive) ?: JsonNull)
                    if (record == null) { put("parent", space.id); put("order", folderOrders.getValue(folder.id)) }
                    // Folding is local on iOS; preserve the Mac's open field.
                }
                if (changed.isNotEmpty()) fields[key("folder", folder.id)] = changed
            }
            val tabOrders = Order.assign(space.tabs.filterNot { it.isBlank }.map { it.id }, records.filter { it.collection == "tab" && it.text("parent") == space.id }.mapNotNull { row -> row.text("order")?.let { row.id to it } }.toMap())
            for (tab in space.tabs) {
                if (tab.isBlank || !web(tab.url)) continue
                val record = wire[key("tab", tab.id)]; val oldTab = oldTabs[tab.id]
                if (record != null && !record.alive()) continue
                val oldSpace = before?.spaces?.firstOrNull { candidate -> candidate.tabs.any { it.id == tab.id } }?.id
                val changed = buildJsonObject {
                    if (record == null || oldSpace != null && oldSpace != space.id) put("parent", space.id)
                    if (record == null || oldTab != null && oldTab.place != tab.place) {
                        put("kept", if (tab.place == TabPlace.KEPT) JsonPrimitive(true) else JsonNull)
                        put("pin", if (tab.place == TabPlace.PINNED) record?.get("pin") ?: JsonPrimitive("1") else JsonNull)
                        put("device", if (tab.place == TabPlace.TODAY) JsonPrimitive(own) else JsonNull)
                    }
                    if (record == null || oldTab != null && oldTab.folderId != tab.folderId) put("folder", tab.folderId?.let(::JsonPrimitive) ?: JsonNull)
                    if (record == null || tab.place == TabPlace.TODAY && (oldTab != null && oldTab.url != tab.url || before == null && record.text("device") == own && record.text("url") != tab.url)) put("url", tab.url)
                    if (record == null || tab.place == TabPlace.TODAY && (oldTab != null && oldTab.title != tab.title || before == null && record.text("device") == own && record.text("title") != tab.title)) put("title", tab.title)
                    if (record == null || oldTab != null && oldTab.place != tab.place || oldSpace != null && oldSpace != space.id ||
                        old != null && old.tabs.map { it.id } != space.tabs.map { it.id }) put("order", tabOrders.getValue(tab.id))
                    if (record == null || oldTab != null && tab.lastActiveAt / 300_000 != oldTab.lastActiveAt / 300_000) put("seen", tab.lastActiveAt / 300_000 * 300)
                }
                if (changed.isNotEmpty()) fields[key("tab", tab.id)] = changed
            }
        }
        if (before != null) {
            val spaces = current.spaces.map { it.id }.toSet(); val tabs = current.spaces.flatMap { it.tabs }.map { it.id }.toSet(); val folders = current.spaces.flatMap { it.folders }.map { it.id }.toSet()
            val deletedSpaces = oldSpaces.keys - spaces
            deletedSpaces.forEach { removed += key("space", it) }
            for (record in records) if (record.text("parent") in deletedSpaces && record.collection in setOf("tab", "folder", "pair")) removed += record.key
            for ((id, _) in oldTabs) if (id !in tabs) removed += key("tab", id)
            before.spaces.flatMap { it.folders }.filter { it.id !in folders }.forEach { removed += key("folder", it.id) }
        }
        val backfill = before?.settings?.syncHistory == false
        val oldVisits = if (backfill) emptyMap() else before?.history.orEmpty().filter { it.syncedKey == null }.associateBy { visitKey(it.url) }
        for (visit in current.history) if (current.settings.syncHistory && BrowserHistory.exportable(visit, now)) {
            val id = visitKey(visit.url); val old = oldVisits[id]; val record = wire[key("visit", id)]
            if ((old == null || old.visitedAt < visit.visitedAt) && (record?.number("last") ?: 0.0) * 1000 < visit.visitedAt) fields[key("visit", id)] = buildJsonObject {
                put("url", visit.url); put("title", visit.title.take(300)); put("last", visit.visitedAt / 1000)
            }
        }
        return Changes(fields, removed, paintEdits)
    }

    fun project(local: BrowserSnapshot, records: List<Record>, own: String, importSearch: Boolean = true, now: Long = System.currentTimeMillis()): BrowserSnapshot {
        val wire = records.associateBy { it.key }; val localSpaces = local.spaces.associateBy { it.id }; val localTabs = local.spaces.flatMap { it.tabs }.associateBy { it.id }
        val spaces = records.filter { it.collection == "space" && it.alive() && it.text("name") != null && runCatching { UUID.fromString(it.id) }.isSuccess }
            .sortedWith(compareBy<Record> { it.text("order") ?: "" }.thenBy { it.id }).map { record ->
                val old = localSpaces[record.id]; val paint = record["paint"] as? JsonObject
                val color = paint?.text("color")?.removePrefix("#")?.takeIf { it.length == 6 }?.toLongOrNull(16)?.let { it or 0xff000000 } ?: old?.color ?: 0xffeee9e2
                val tabs = records.filter { it.collection == "tab" && it.alive() && it.text("parent") == record.id &&
                    (tabPlace(it) != TabPlace.TODAY || it.text("device") == own) && it.text("url")?.let(::web) == true }
                    .sortedWith(compareBy<Record> { when (tabPlace(it)) { TabPlace.PINNED -> 0; TabPlace.KEPT -> 1; TabPlace.TODAY -> 2 } }.thenBy { it.text("order") ?: "" }.thenBy { it.id })
                    .map { row ->
                        val kept = tabPlace(row); val previous = localTabs[row.id]
                        BrowserTab(row.id, if (kept != TabPlace.TODAY && previous?.place == kept) previous.url else row.text("url")!!,
                            if (kept != TabPlace.TODAY && previous?.place == kept) previous.title else row.text("name") ?: row.text("title") ?: "Page", kept,
                            createdAt = previous?.createdAt ?: ((row.number("seen") ?: 0.0) * 1000).toLong(), lastActiveAt = previous?.lastActiveAt ?: ((row.number("seen") ?: 0.0) * 1000).toLong(),
                            locallyCreated = row.text("device") == own, shared = kept != TabPlace.TODAY, folderId = row.text("folder"), openerId = previous?.openerId,
                            hasDraft = previous?.hasDraft == true, hasTask = previous?.hasTask == true)
                    }
                val missingLocal = old?.tabs.orEmpty().filter { !it.isPrivate && wire[key("tab", it.id)] == null }
                val folders = records.filter { it.collection == "folder" && it.alive() && it.text("parent") == record.id && !it.flag("today") }
                    .sortedWith(compareBy<Record> { it.text("order") ?: "" }.thenBy { it.id }).map { row -> BrowserFolder(row.id, row.text("name") ?: "Folder", row.text("folder"), color = row.text("color"), open = old?.folders?.firstOrNull { it.id == row.id }?.open ?: true) }
                val projected = BrowserSpace(record.id, record.text("name")!!, record.text("icon") ?: "", color, record.flag("ownSignIns"), tabs = tabs + missingLocal,
                    currentTabId = if (old != null && old.currentTabId == null) null
                        else old?.currentTabId?.takeIf { id -> (tabs + missingLocal).any { it.id == id } } ?: (tabs + missingLocal).firstOrNull { it.place == TabPlace.TODAY }?.id,
                    folders = folders, look = paint)
                val order = records.filter { it.text("parent") == record.id && it.collection in setOf("tab", "folder") }
                    .mapNotNull { row -> row.text("order")?.let { "${row.collection}:${row.id}" to it } }.toMap()
                projected.copy(keptOrder = BrowserKeptTree.importedOrder(projected, order))
            }
        val unsynced = local.spaces.filter { wire[key("space", it.id)] == null }
        val combined = (spaces + unsynced).ifEmpty { local.spaces }
        val localVisits = local.history.filter { it.syncedKey == null }
        val latest = localVisits.groupBy { visitKey(it.url) }.mapValues { (_, visits) -> visits.maxOf { it.visitedAt } / 1000.0 }
        val incomingVisits = records.mapNotNull { row ->
            if (row.collection != "visit" || !row.alive() || row.text("url")?.let(::web) != true || row.stamps["last"]?.device == own) return@mapNotNull null
            val at = row.number("last")?.takeIf { it.isFinite() && it >= now / 1000.0 - 14 * 86_400 } ?: return@mapNotNull null
            if (local.historyForgetting.hides(row.id, at) || latest[row.id]?.let { it >= at - 60 } == true) return@mapNotNull null
            BrowserVisit(row.text("url")!!, row.text("title") ?: "", (at * 1000).toLong(), syncedKey = row.id, syncedAt = at, syncedDevice = row.stamps["last"]?.device)
        }
        val history = (localVisits + incomingVisits).sortedWith(compareByDescending<BrowserVisit> { it.visitedAt }.thenBy { it.identity }).take(10_000)
        val engineName = wire[key("setting", "search.engine")]?.get("value")?.jsonPrimitive?.contentOrNull
        val engine = SearchEngine.entries.firstOrNull { it.name.equals(engineName, true) }
        val template = wire[key("setting", "search.custom")]?.get("value")?.jsonPrimitive?.contentOrNull
        val settings = if (importSearch && engine != null && (engine != SearchEngine.CUSTOM || template?.let(BrowserAddress::validTemplate) == true)) local.settings.copy(searchEngine = engine, customSearchTemplate = template ?: local.settings.customSearchTemplate) else local.settings
        val ids = combined.flatMap { it.tabs }.map { it.id }.toSet()
        return local.copy(spaces = combined, selectedSpaceId = local.selectedSpaceId.takeIf { id -> combined.any { it.id == id } } ?: combined.first().id, history = history, settings = settings,
            recency = local.recency.filterKeys { id -> combined.any { it.id == id } }.mapValues { (_, values) -> values.filter { it in ids } })
    }
    private fun visitKey(text: String): String = BrowserHistory.key(text)
}
