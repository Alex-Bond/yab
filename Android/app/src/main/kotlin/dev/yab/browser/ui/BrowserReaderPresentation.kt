package dev.yab.browser.ui

import dev.yab.browser.engine.ReaderPreferencesStore
import dev.yab.browser.model.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

enum class ReaderCardPage { THEMES, CUSTOMIZE, FONTS }
data class ReaderCardFrame(val shown: Boolean = true, val page: ReaderCardPage = ReaderCardPage.THEMES,
    val generation: Long = 0, val dropped: Boolean = false)

/** One original Reader/card opening. Global prefs outlive this local presentation, not its controls. */
class BrowserReaderPresentation(val store: ReaderPreferencesStore, private val originalCurrent: () -> Boolean) {
    private var retired = false
    private var before: ReaderPreferences? = null
    private val mutable = MutableStateFlow(ReaderCardFrame())
    val state = mutable.asStateFlow()
    fun current(): Boolean {
        if (retired) return false
        if (!originalCurrent()) { retired = true; return false }
        return !retired && mutable.value.shown
    }
    fun control(): Control = Control(this, mutable.value.generation, store.snapshot().theme, store.themeRevision)
    fun drop() = finish(true)
    private fun finish(dropped: Boolean) {
        retired = true; before = null
        mutable.value = mutable.value.copy(shown = false, generation = mutable.value.generation + 1, dropped = dropped)
    }
    private fun page(value: ReaderCardPage) { mutable.value = mutable.value.copy(page = value, generation = mutable.value.generation + 1) }
    private fun close(): Boolean {
        if (mutable.value.page != ReaderCardPage.THEMES && before?.let { !store.set(it) } == true) return false
        finish(false); return true
    }
    class Control internal constructor(private val owner: BrowserReaderPresentation, private val generation: Long,
        private val theme: ReaderTheme, private val themeRevision: Long) {
        private var retired = false
        fun retire() { retired = true }
        private fun current(): Boolean {
            if (retired || !owner.current() || owner.mutable.value.generation != generation ||
                owner.store.themeRevision != themeRevision || owner.store.snapshot().theme != theme) { retired = true; return false }
            val after = !retired && owner.current() && owner.mutable.value.generation == generation &&
                owner.store.themeRevision == themeRevision && owner.store.snapshot().theme == theme
            if (!after) retired = true
            return after
        }
        fun change(change: (ReaderLook) -> ReaderLook): Boolean = current() && owner.store.set(owner.store.snapshot().change(change))
        fun step(by: Int): Boolean = current() && owner.store.set(owner.store.snapshot().step(by))
        fun theme(value: ReaderTheme): Boolean = current() && owner.store.set(owner.store.snapshot().copy(theme = value))
        fun mode(value: ReaderMode): Boolean = current() && owner.store.set(owner.store.snapshot().copy(mode = value))
        fun reset(): Boolean = current() && owner.store.set(owner.store.snapshot().reset())
        internal fun windowSetting(action: () -> Unit): Boolean {
            if (!current()) return false
            action(); return true
        }
        fun customize(): Boolean {
            if (!current() || owner.mutable.value.page != ReaderCardPage.THEMES) return false
            owner.before = owner.store.snapshot(); owner.page(ReaderCardPage.CUSTOMIZE); return true
        }
        fun fonts(): Boolean {
            if (!current() || owner.mutable.value.page != ReaderCardPage.CUSTOMIZE) return false
            owner.page(ReaderCardPage.FONTS); return true
        }
        fun back(): Boolean {
            if (!current() || owner.mutable.value.page != ReaderCardPage.FONTS) return false
            owner.page(ReaderCardPage.CUSTOMIZE); return true
        }
        fun done(): Boolean {
            if (!current() || owner.mutable.value.page == ReaderCardPage.THEMES) return false
            owner.before = null; owner.page(ReaderCardPage.THEMES); return true
        }
        fun cancel(): Boolean {
            if (!current() || owner.mutable.value.page == ReaderCardPage.THEMES) return false
            if (owner.before?.let { !owner.store.set(it) } == true) return false
            owner.before = null; owner.page(ReaderCardPage.THEMES); return true
        }
        fun close(): Boolean = current() && owner.close()
    }
}
