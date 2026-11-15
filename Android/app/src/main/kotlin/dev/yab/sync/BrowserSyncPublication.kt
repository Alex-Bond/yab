package dev.yab.sync

import dev.yab.core.sync.Journal
import dev.yab.core.sync.RecordKey
import dev.yab.browser.model.BrowserSpaceLook
import kotlinx.serialization.json.*

/** Only explicit editor-owned fields, not a stale whole projected paint value. */
data class BrowserPaintEdit(val fields: Map<String, JsonElement?>, val fallback: JsonObject)

/** Prepare the existing browser patch on the Sync serial dispatcher, immediately before its
 * journal write. Read live fields only after the existing account/epoch/refusal checks. The
 * mobile browser does not own the Mac's per-space search selection or unknown future fields. */
internal object BrowserSyncPublication {
    data class Prepared(val journal: Journal, val fields: Map<RecordKey, JsonObject>)

    fun prepare(changes: Map<RecordKey, JsonObject>, removed: Set<RecordKey>, expectedAccount: String?, expectedEpoch: Long?,
        currentAccount: () -> String?, currentEpoch: () -> Long, refused: () -> Boolean, journal: () -> Journal?,
        paintEdits: Map<RecordKey, BrowserPaintEdit> = emptyMap()): Prepared? {
        val live = checkedJournal(expectedAccount, expectedEpoch, currentAccount, currentEpoch, refused, journal) ?: return null
        return prepareFields(live, changes, removed, paintEdits)
    }

    /** Both concrete Android journals synchronize receive and changeBatch on this instance.
     * Keep their merge and the existing caller-CAS/write/removal operation under that same
     * monitor, without suspension, so another Sync executor cannot interleave a receive. */
    fun publish(changes: Map<RecordKey, JsonObject>, removed: Set<RecordKey>, expectedAccount: String?, expectedEpoch: Long?,
        currentAccount: () -> String?, currentEpoch: () -> Long, refused: () -> Boolean, journal: () -> Journal?,
        paintEdits: Map<RecordKey, BrowserPaintEdit> = emptyMap(), expected: Map<RecordKey, dev.yab.core.sync.Record?> = emptyMap(),
        operation: (Prepared) -> Unit): Journal? {
        val live = checkedJournal(expectedAccount, expectedEpoch, currentAccount, currentEpoch, refused, journal) ?: return null
        synchronized(live) {
            checkOwner(expectedAccount, expectedEpoch, currentAccount, currentEpoch, refused)
            require(expected.all { (key, source) -> live.record(key) == source }) { "Sync records changed" }
            operation(prepareFields(live, changes, removed, paintEdits))
        }
        return live
    }

    private fun checkedJournal(expectedAccount: String?, expectedEpoch: Long?, currentAccount: () -> String?,
        currentEpoch: () -> Long, refused: () -> Boolean, journal: () -> Journal?): Journal? {
        checkOwner(expectedAccount, expectedEpoch, currentAccount, currentEpoch, refused)
        return journal()
    }
    private fun checkOwner(expectedAccount: String?, expectedEpoch: Long?, currentAccount: () -> String?,
        currentEpoch: () -> Long, refused: () -> Boolean) {
        check(expectedAccount == null || currentAccount() == expectedAccount) { "Sync account changed" }
        check(expectedEpoch == null || currentEpoch() == expectedEpoch) { "Sync session changed" }
        check(!refused()) { "This device was removed from Sync" }
    }

    private fun prepareFields(live: Journal, changes: Map<RecordKey, JsonObject>, removed: Set<RecordKey>,
        paintEdits: Map<RecordKey, BrowserPaintEdit>): Prepared {
        require((changes.keys + removed).all { it.collection in setOf("space", "tab", "folder", "setting", "visit", "pair") })
        require(paintEdits.all { (key, edit) -> key.collection == "space" && key in changes &&
            edit.fields.keys.all { it in PAINT_FIELDS } })
        val patches = linkedMapOf<RecordKey, JsonObject>()
        for ((key, fields) in changes) {
            val source = live.record(key)
            val original = source?.visible ?: JsonObject(emptyMap())
            val edit = paintEdits[key]
            // A projected editor cannot recreate a remotely deleted existing space. Drop only
            // that key, allowing the binding's normal projection and other writes to finish.
            if (key.collection == "space" && (source != null && !source.alive() || edit != null && source == null)) continue
            patches[key] = if (edit == null) JsonObject(original + fields) else {
                JsonObject(original + fields + ("paint" to mergePaint(original["paint"] as? JsonObject, edit)))
            }
        }
        return Prepared(live, patches)
    }
    internal fun mergePaint(latest: JsonObject?, edit: BrowserPaintEdit): JsonObject {
        val paint = latest?.toMutableMap() ?: mutableMapOf()
        // An actual edit needs a valid paint identity. Missing/invalid paint can use only the
        // captured required seed, never resurrect old unknown fields after a remote clear.
        if ((paint["swatch"] as? JsonPrimitive)?.isString != true) edit.fallback["swatch"]?.let { paint["swatch"] = it }
        val color = (paint["color"] as? JsonPrimitive)?.takeIf { it.isString }?.content
        if (color == null || BrowserSpaceLook.parseHex(color) == null) edit.fallback["color"]?.let { paint["color"] = it }
        edit.fields.forEach { (name, value) -> if (value == null) paint.remove(name) else paint[name] = value }
        return JsonObject(paint)
    }
    private val PAINT_FIELDS = setOf("swatch", "color", "colors", "grain", "grainAmount", "transparency", "drawings", "drawingsStrength")
}
