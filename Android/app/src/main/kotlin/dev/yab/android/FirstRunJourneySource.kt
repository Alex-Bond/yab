package dev.yab.android

import dev.yab.sync.SyncUiState

/** A saved journey retains its actual initial Live observation; this grants no Sync authority. */
internal class FirstRunJourneySource(
    private val original: TabletJoinPresentation.Source,
    private val originalUi: SyncUiState,
    private val native: () -> TabletJoinPresentation.Source,
    private val ui: () -> SyncUiState,
    private val entryAvailable: () -> Boolean,
) {
    private var retired = false
    /** Initial admission never adopts a replacement source or a newer Live status. */
    fun initialCurrent(): Boolean {
        if (retired || !original.available || native() != original ||
            original.identity != null && ui() !== originalUi || !entryAvailable() ||
            native() != original || original.identity != null && ui() !== originalUi) {
            retired = true
            return false
        }
        return true
    }
    /** A raced unavailable constructor must never be assigned as the retained visible owner. */
    fun create(code: () -> String?): FirstRunPresentation? {
        if (!initialCurrent()) return null
        val flow = FirstRunPresentation(::current, code)
        if (!initialCurrent()) { flow.close(); return null }
        return flow
    }
    fun current(): TabletJoinPresentation.Source {
        val now = native()
        if (retired) return now.copy(available = false)
        // A genuine join that began unpaired retains the original completion-before-Live contract.
        if (original.identity == null) return now
        if (now != original || ui() !== originalUi || !entryAvailable() || native() != now || ui() !== originalUi) {
            retired = true
            return now.copy(available = false)
        }
        return now
    }
}
