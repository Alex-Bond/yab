package dev.yab.browser.model

/** Process-local navigation keys, never serialized as a preference or a Sync record. */
internal sealed interface SettingsDestination {
    val title: String
    data class Page(override val title: String) : SettingsDestination
    data class Space(val id: String) : SettingsDestination { override val title = "Space" }
    data class Editor(val id: String, val step: SettingsSpaceStep, val namingNew: Boolean = false) : SettingsDestination {
        override val title get() = step.title
    }
}

internal enum class SettingsSpaceStep(val title: String) { NAME("Name"), EMOJI("Emoji"), COLOR("Color") }

/** A fresh owner after creating/selecting a public space, consumed once by the Settings host. */
internal class SettingsSpaceNavigation internal constructor(internal val lease: SettingsPresentationLease, val id: String)

/** A retained editor cannot return after its space was removed, or after its route/source left. */
internal class SettingsSpaceEditLease internal constructor(internal val settings: SettingsPresentationLease,
    val id: String, internal val identity: Any, internal val routeCurrent: () -> Boolean)

/** Only changed fields are submitted. Remote changes to untouched fields stay live. */
internal data class SettingsSpaceDraft(
    val opened: BrowserSpace,
    val name: String = opened.name,
    val emoji: String = SpaceSymbols.emoji(opened.emoji),
    val look: BrowserSpaceLook = BrowserSpaceLook.from(opened.look, opened.color),
    val nameChanged: Boolean = false,
    val emojiChanged: Boolean = false,
    val lookChanged: Boolean = false,
) {
    fun rename(value: String) = copy(name = value, nameChanged = true)
    fun pick(value: String) = copy(emoji = value, emojiChanged = true)
    fun paint(value: BrowserSpaceLook) = copy(look = value, lookChanged = true)
    fun saved(space: BrowserSpace) = SettingsSpaceDraft(space)
    val dirty get() = nameChanged || emojiChanged || lookChanged
}
