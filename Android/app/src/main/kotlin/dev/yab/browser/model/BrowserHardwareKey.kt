package dev.yab.browser.model

/** The browser's own chords. Android key codes and event delivery stay in the Activity. */
enum class BrowserHardwareKey {
    NEW_TAB, OPEN_LOCATION, CLOSE_TAB, REOPEN_TAB, RELOAD, BACK, FORWARD, FIND,
    NEXT_TAB, PREVIOUS_TAB, TAB_1, TAB_2, TAB_3, TAB_4, TAB_5, TAB_6, TAB_7, TAB_8, TAB_9;

    internal val tabNumber: Int? get() = when (this) {
        TAB_1 -> 1; TAB_2 -> 2; TAB_3 -> 3; TAB_4 -> 4; TAB_5 -> 5
        TAB_6 -> 6; TAB_7 -> 7; TAB_8 -> 8; TAB_9 -> 9
        else -> null
    }

    companion object {
        /** Control is Android's command equivalent; Meta supports an attached Mac keyboard.
         * Tab belongs only to Control, leaving the system's Meta-Tab untouched. */
        fun fromChord(input: String, control: Boolean, meta: Boolean, shift: Boolean = false,
            alt: Boolean = false, repeatCount: Int = 0): BrowserHardwareKey? {
            if (alt || repeatCount != 0 || control == meta) return null
            if (input == "\t") return if (control) {
                if (shift) PREVIOUS_TAB else NEXT_TAB
            } else null
            if (shift) return if (input == "t") REOPEN_TAB else null
            return when (input) {
                "t" -> NEW_TAB; "l" -> OPEN_LOCATION; "w" -> CLOSE_TAB; "r" -> RELOAD
                "[" -> BACK; "]" -> FORWARD; "f" -> FIND
                "1" -> TAB_1; "2" -> TAB_2; "3" -> TAB_3; "4" -> TAB_4; "5" -> TAB_5
                "6" -> TAB_6; "7" -> TAB_7; "8" -> TAB_8; "9" -> TAB_9
                else -> null
            }
        }
    }
}

/** One rendered Activity/window/account/cover owner. A refused owner never revives. */
class BrowserHardwareKeyHost(private val originalCurrent: () -> Boolean,
    private val originalContinuationCurrent: () -> Boolean) {
    constructor(originalCurrent: () -> Boolean) : this(originalCurrent, originalCurrent)
    private var retired = false
    fun retire() { retired = true }
    fun current(): Boolean = check(originalCurrent)
    /** Only the adapter's post-close step may omit the native page it just closed.
     * The same captured window/account/cover owner remains mandatory. */
    fun continuationCurrent(): Boolean = check(originalContinuationCurrent)
    private fun check(original: () -> Boolean): Boolean {
        if (retired) return false
        if (!original()) { retired = true; return false }
        return !retired
    }
}

/** Captured during render, never reacquired by a retained key callback. */
class BrowserHardwareKeyLease internal constructor(
    internal val controller: BrowserController,
    val key: BrowserHardwareKey,
    internal val host: BrowserHardwareKeyHost,
    internal val revision: Long,
    internal val ownership: Long,
    internal val lifetime: SettingsPresentationLifetime,
    internal val original: BrowserState,
    internal val undo: Any?,
    internal val navigation: Long,
    internal val window: WorkspaceWindowState,
    internal val welcomeBoundary: Long,
) {
    internal var consumed = false
    internal var retired = false
}

internal data class BrowserHardwareKeyTabFacts(val id: String, val url: String, val privately: Boolean,
    val opener: String?, val place: TabPlace, val folder: String?)
internal data class BrowserHardwareKeyTabOwner(val tab: String, val space: String, val profile: WebsiteProfile)

internal data class BrowserHardwareKeyFacts(val loading: Boolean, val surface: BrowserSurface,
    val epoch: Long, val space: String, val profile: WebsiteProfile?, val front: String?,
    val blocked: Boolean, val privateLocked: Boolean, val lockPrivate: Boolean, val welcomed: Boolean,
    val fieldNewTab: Boolean, val fieldPrivate: Boolean,
    val tabs: List<BrowserHardwareKeyTabFacts>, val owners: List<BrowserHardwareKeyTabOwner>,
    val order: List<String>, val workspace: BrowserWorkspace?,
    val pageLoading: Boolean, val reader: Boolean, val back: Boolean, val forward: Boolean, val undo: Boolean)

internal fun BrowserState.hardwareKeyFacts(): BrowserHardwareKeyFacts {
    val selected = space?.tabs.orEmpty()
    val ids = selected.mapTo(mutableSetOf(), BrowserTab::id)
    return BrowserHardwareKeyFacts(loading, surface, surfaceEpoch,
        selectedSpaceId, space?.websiteProfile, tab?.id, privateContentBlocked, privateLocked, settings.lockPrivate, settings.welcomed,
        fieldIsNewTab, fieldIsPrivate,
        selected.map { BrowserHardwareKeyTabFacts(it.id, it.url, it.isPrivate, it.openerId, it.place, it.folderId) },
        spaces.flatMap { owner -> owner.tabs.filter { it.id in ids }.map { BrowserHardwareKeyTabOwner(it.id, owner.id, owner.websiteProfile) } },
        pagingOrder().map(BrowserTab::id), workspace, page.loading, page.readerEnabled, page.canGoBack, page.canGoForward, undoAvailable)
}
