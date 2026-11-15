package dev.yab.sync

import dev.yab.agent.*
import dev.yab.browser.model.*
import dev.yab.core.sync.Record
import java.io.Closeable
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*

data class MacTodayRow(val account: String, val epoch: Long, val mac: String, val space: String, val id: String,
    val url: String, val title: String, val front: Boolean, val closing: Boolean = false, internal val record: Record)
data class MacTodayGroup(val mac: RemoteMac, val rows: List<MacTodayRow>)
data class MacTodayState(val enabled: Boolean = false, val account: String? = null, val space: String? = null, val groups: List<MacTodayGroup> = emptyList())

/** Mac Today is separate from this device's own Today, including legacy unowned Mac rows. */
object MacTodayProjection {
    private fun Record.text(key: String) = (get(key) as? JsonPrimitive)?.takeIf { it.isString }?.content
    fun groups(image: AccountRecordsSnapshot, connection: RemoteConnection, space: String, closing: List<MacTodayRow> = emptyList()): List<MacTodayGroup> {
        val account = image.account ?: return emptyList()
        if (image.removed || connection.account != account) return emptyList()
        val macs = connection.macs.associateBy { it.id }
        val rows = image.records.mapNotNull { row ->
            if (row.collection != "tab" || row.schema != 1 || !row.alive() || row.text("parent") != space || (row["kept"] as? JsonPrimitive)?.booleanOrNull == true || row.text("pin") != null) return@mapNotNull null
            val mac = row.text("device")?.let { macs[it] } ?: if (row.text("device") == null) connection.macs.firstOrNull() else null
            if (mac == null) return@mapNotNull null
            val url = row.text("url")?.takeIf(AgentMarkdown::safeUrl) ?: return@mapNotNull null
            MacTodayRow(account, image.epoch, mac.id, space, row.id, url, row.text("title")?.takeIf(String::isNotBlank) ?: url, mac.frontTab == row.id, record = row)
        }
        val pending = closing.filter { row -> row.account == account && row.epoch == image.epoch && row.space == space && macs[row.mac]?.availability?.phase?.let { it != MacPhase.UP } == true && rows.none { it.id == row.id } }
        return connection.macs.mapNotNull { mac ->
            val sorted = (rows + pending).filter { it.mac == mac.id }.sortedWith(compareByDescending<MacTodayRow> { it.front && !it.closing }
                .thenBy { it.record.text("order") ?: "" }.thenBy { it.id })
            sorted.takeIf { it.isNotEmpty() }?.let { MacTodayGroup(mac, it) }
        }
    }
}

class MacTodayController(private val browser: BrowserController, private val sync: AndroidSyncBridge, parent: CoroutineScope) : Closeable {
    private val life = SupervisorJob(parent.coroutineContext[Job])
    private val scope = CoroutineScope(parent.coroutineContext + life)
    private val closing = MutableStateFlow(emptyList<MacTodayRow>())
    private val mutableBusy = MutableStateFlow(emptySet<String>()); val busy = mutableBusy.asStateFlow()
    private val mutableError = MutableStateFlow<String?>(null); val error = mutableError.asStateFlow()
    val state = combine(browser.state, sync.accountRecords, sync.connection, closing) { current, image, connection, pending ->
        val enabled = current.settings.macTabs && !current.loading && current.space?.isPrivate != true && !current.fieldPrivate && !current.privateContentBlocked
        MacTodayState(enabled, image.account, current.space?.id, if (enabled && current.space != null) MacTodayProjection.groups(image, connection, current.space!!.id, pending) else emptyList())
    }.stateIn(scope, SharingStarted.Eagerly, MacTodayState())
    fun clearError() { mutableError.value = null }
    private fun source() = browser.state.value.let { listOf(it.selectedSpaceId, it.tab?.id, it.surface, it.fieldPrivate, it.space?.isPrivate, it.privateContentBlocked) }
    fun open(row: MacTodayRow) = act(row, false)
    fun close(row: MacTodayRow) = act(row, true)
    private fun act(row: MacTodayRow, close: Boolean) {
        if (row.closing || row.id in mutableBusy.value || state.value.groups.none { group -> group.rows.any { it == row } }) return
        val captured = source()
        scope.launch {
            mutableBusy.update { it + row.id }; mutableError.value = null
            try {
                val current = { source() == captured && browser.state.value.settings.macTabs && state.value.account == row.account && state.value.space == row.space }
                val url = sync.useMacToday(row, close, current)
                if (current()) {
                    if (close) {
                        if (sync.connection.value.macs.firstOrNull { it.id == row.mac }?.availability?.phase != MacPhase.UP) closing.update { old -> old.filter { it.account == row.account && it.epoch == row.epoch && it.id != row.id } + row.copy(closing = true) }
                    } else browser.openUrl(url, newTab = true, privately = false)
                }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) { if (sync.accountRecords.value.let { it.account == row.account && it.epoch == row.epoch && !it.removed }) mutableError.value = failure.message ?: "This Mac's page changed. Try again." }
            finally { mutableBusy.update { it - row.id } }
        }
    }
    override fun close() { life.cancel(); closing.value = emptyList(); mutableError.value = null }
}
