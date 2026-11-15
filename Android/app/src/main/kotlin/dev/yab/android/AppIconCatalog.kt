package dev.yab.android

import dev.yab.core.sync.Record
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/** Stable IDs and earned access match production SyncKit/AppIconCatalog.swift. */
enum class AppIcon(val wireId: String, val title: String, val resourceName: String,
                   val friendCount: Int? = null, val reward: Boolean = false, val seasonal: Boolean = false) {
    Flat("07-flat", "Flat", "app_icon_flat"),
    Original("original", "Default", "app_icon_original"),
    WatercolorGlass("08-watercolor-glass", "Watercolor Glass", "app_icon_watercolor_glass"),
    Opal("01-prismatic-frost", "Opal", "app_icon_opal"),
    SmokedChrome("02-liquid-mercury", "Smoked Chrome", "app_icon_smoked_chrome", reward = true),
    Amber("04-prism-spectral", "Amber", "app_icon_amber", reward = true),
    RedEnamel("06-ember", "Red Enamel", "app_icon_red_enamel", reward = true),
    Pumpkin("16-halloween-pumpkin", "Pumpkin", "app_icon_pumpkin", seasonal = true),
    Ghost("17-halloween-ghost", "Ghost", "app_icon_ghost", seasonal = true),
    Mummy("18-halloween-mummy", "Mummy", "app_icon_mummy", seasonal = true),
    Witch("19-halloween-witch", "Witch", "app_icon_witch", seasonal = true),
    WaxSeal("11-wax-seal", "Wax Seal", "app_icon_wax_seal", friendCount = 1, reward = true),
    Bracelet("12-friendship-bracelet", "Friendship Bracelet", "app_icon_bracelet", friendCount = 3, reward = true),
    Ticket("13-golden-ticket", "Golden Ticket", "app_icon_ticket", friendCount = 7, reward = true),
    Yearbook("14-yearbook", "Yearbook", "app_icon_yearbook", friendCount = 10, reward = true),
    Arcade("15-arcade", "Arcade", "app_icon_arcade", reward = true),
    FirstEdition("20-first-edition", "First Edition", "app_icon_first_edition", reward = true),
    Charm("charm", "Best Friends", "app_icon_charm", reward = true);

    val grantKey get() = GRANT_PREFIX + wireId
    val canKeepLocally get() = seasonal || this in LEGACY_REWARDS
    fun variant(charm: AppIconCharm = AppIconCharm.DEFAULT) = AppIconVariant(this, if (this == Charm) charm else null)

    companion object {
        const val GRANT_PREFIX = "appearance.appIcon.unlocked."
        val LEGACY_REWARDS = setOf(SmokedChrome, Amber, RedEnamel)
        fun fromId(id: String) = entries.firstOrNull { it.wireId == id }
        fun halloweenEnd(zone: ZoneId = ZoneId.systemDefault()): Instant = LocalDate.of(2026, 11, 3).atStartOfDay(zone).toInstant()
        fun validReceipt(value: String?) = value != null && value.length == 64 && value.all { it in '0'..'9' || it in 'a'..'f' }
        val variants: List<AppIconVariant> get() = entries.filter { it != Charm }.map { it.variant() } +
            AppIconCharm.COLORS.flatMap { left -> (AppIconCharm.COLORS + "silver").map { right -> Charm.variant(AppIconCharm.of(left, right)) } }
    }
}

data class AppIconCharm private constructor(val left: String, val right: String) {
    companion object {
        val COLORS = listOf("mint", "lilac", "sky", "rose", "coral", "lemon", "indigo")
        val DEFAULT = AppIconCharm("mint", "silver")
        fun of(left: String?, right: String?) = AppIconCharm(
            left?.takeIf { it in COLORS } ?: "mint",
            if (right == null) "silver" else right.takeIf { it in COLORS || it == "silver" } ?: "mint")
    }
}

data class AppIconVariant(val icon: AppIcon, val charm: AppIconCharm? = null) {
    init { require((icon == AppIcon.Charm) == (charm != null)) }
    val alias: String get() = if (icon == AppIcon.Charm && charm != AppIconCharm.DEFAULT)
        "Charm_${charm!!.left}_${charm.right}" else icon.name
    val resourceName: String get() = if (icon == AppIcon.Charm && charm != AppIconCharm.DEFAULT)
        "app_icon_charm_${charm!!.left}_${charm.right}" else icon.resourceName
}

data class AppIconAccess(val imported: Set<AppIcon> = emptySet(), val charm: AppIconCharm = AppIconCharm.DEFAULT) {
    fun unlocked(icon: AppIcon, kept: Set<AppIcon>, at: Instant, zone: ZoneId = ZoneId.systemDefault()): Boolean =
        icon in imported || icon in kept || if (icon.seasonal) at < AppIcon.halloweenEnd(zone) else !icon.reward
    fun visible(icon: AppIcon, kept: Set<AppIcon>, at: Instant, zone: ZoneId = ZoneId.systemDefault()) =
        icon.friendCount != null || icon == AppIcon.Charm || unlocked(icon, kept, at, zone)
    companion object {
        private fun string(value: JsonElement?) = (value as? JsonPrimitive)?.takeIf { it.isString }?.content
        fun fromValues(values: Map<String, JsonElement>): AppIconAccess {
            val imported = AppIcon.entries.filterTo(linkedSetOf()) { icon ->
                (values[icon.grantKey] as? JsonPrimitive)?.let { !it.isString && it.booleanOrNull == true } == true
            }
            if (AppIcon.validReceipt(string(values["gift.firstEdition.receipt"]))) imported += AppIcon.FirstEdition
            // Phone accepts a synced color from the seven-color palette; silver is the absent right half.
            val left = string(values["invite.charm.left"])
            val rawRight = string(values["invite.charm.right"])
            val right = rawRight?.takeIf { it in AppIconCharm.COLORS } ?: rawRight?.let { "mint" }
            return AppIconAccess(imported, AppIconCharm.of(left, right))
        }
        fun fromRecords(records: List<Record>) = fromValues(records.asSequence()
            .filter { it.collection == "setting" && it.schema == 1 && it.alive() }
            .mapNotNull { row -> row["value"]?.let { row.id to it } }.toMap())
    }
}

data class AppIconLocalState(val kept: Set<AppIcon> = emptySet(), val migrated: Boolean = false) {
    fun merged(other: AppIconLocalState) = AppIconLocalState(kept + other.kept, migrated || other.migrated)
}
interface AppIconLocalStore {
    fun read(): AppIconLocalState
    /** Atomic monotonic union with the latest durable state, across every store instance. */
    fun merge(value: AppIconLocalState): AppIconLocalState
}
interface AppIconNativePort {
    fun selected(): List<AppIconVariant>
    fun choose(variant: AppIconVariant)
}

/** Native readback, not browsing or receiving an account grant, earns a seasonal icon. */
class AppIconSelection(private val local: AppIconLocalStore, private val native: AppIconNativePort,
                       private val now: () -> Instant = Instant::now, private val zone: () -> ZoneId = ZoneId::systemDefault) {
    fun migrateLegacy(): AppIconLocalState {
        val previous = local.read()
        if (previous.migrated) return previous
        val chosen = native.selected().singleOrNull()?.icon?.takeIf { it in AppIcon.LEGACY_REWARDS }
        val next = previous.copy(kept = previous.kept + listOfNotNull(chosen), migrated = true)
        return local.merge(next)
    }
    /** Returns only a newly worn seasonal icon. The caller publishes it under its captured Sync lease. */
    fun choose(icon: AppIcon, access: AppIconAccess, isCurrent: () -> Boolean): AppIcon? {
        check(isCurrent()) { "This app icon page changed. Choose again." }
        val before = migrateLegacy()
        check(access.unlocked(icon, before.kept, now(), zone())) { "Unlock this icon on your Mac first." }
        val variant = icon.variant(access.charm)
        if (native.selected() == listOf(variant)) return null
        check(isCurrent()) { "The app icon account changed. Choose again." }
        native.choose(variant)
        check(native.selected() == listOf(variant)) { "The launcher could not change the icon. Try again." }
        val current = local.read()
        if (!icon.seasonal || icon in current.kept || !access.unlocked(icon, current.kept, now(), zone())) return null
        local.merge(AppIconLocalState(kept = setOf(icon)))
        return icon.takeIf { isCurrent() }
    }
}
