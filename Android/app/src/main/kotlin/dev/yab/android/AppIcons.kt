package dev.yab.android

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build

fun AppIcon.component(context: Context) = variant().component(context)
fun AppIconVariant.component(context: Context) = ComponentName(context.packageName, "${context.packageName}.icons.$alias")

/** Every catalog and charm choice has an actual, independently named launcher component. */
class AppIcons(context: Context) : AppIconNativePort {
    private val app = context.applicationContext
    private val manager get() = app.packageManager

    override fun selected(): List<AppIconVariant> = AppIcon.variants.filter { variant ->
        when (manager.getComponentEnabledSetting(variant.component(app))) {
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED -> true
            PackageManager.COMPONENT_ENABLED_STATE_DEFAULT -> variant == AppIcon.Flat.variant()
            else -> false
        }
    }
    fun enabled(): List<AppIcon> = selected().map { it.icon }
    fun choose(icon: AppIcon) = choose(icon.variant())

    override fun choose(variant: AppIconVariant) {
        require(variant in AppIcon.variants)
        if (Build.VERSION.SDK_INT >= 33) {
            manager.setComponentEnabledSettings(AppIcon.variants.map { value ->
                PackageManager.ComponentEnabledSetting(value.component(app),
                    if (value == variant) PackageManager.COMPONENT_ENABLED_STATE_ENABLED else PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                    PackageManager.DONT_KILL_APP)
            })
        } else {
            // Enable first so interruption leaves a real launcher entrance.
            manager.setComponentEnabledSetting(variant.component(app), PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
                PackageManager.DONT_KILL_APP)
            AppIcon.variants.filter { it != variant }.forEach { value ->
                manager.setComponentEnabledSetting(value.component(app), PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                    PackageManager.DONT_KILL_APP)
            }
        }
        check(selected() == listOf(variant)) { "The launcher could not change the icon. Try again." }
    }

    fun picture(variant: AppIconVariant, dark: Boolean = false): Int {
        val names = if (dark) listOf(variant.resourceName + "_preview_dark", variant.resourceName + "_dark", variant.resourceName + "_preview", variant.resourceName)
            else listOf(variant.resourceName + "_preview", variant.resourceName)
        return names.firstNotNullOfOrNull { name -> app.resources.getIdentifier(name, "drawable", app.packageName).takeIf { it != 0 } }
            ?: error("This app icon's original artwork is missing.")
    }
}

/** Account imports never enter preferences. One atomic editor stores only locally earned artwork. */
class AndroidAppIconLocalStore(context: Context, name: String = "app-icon-access") : AppIconLocalStore {
    private val preferences = context.applicationContext.getSharedPreferences(name, Context.MODE_PRIVATE)
    override fun read(): AppIconLocalState = synchronized(preferences) {
        val names = preferences.getStringSet("kept", emptySet()).orEmpty()
        check(names.size <= AppIcon.entries.size) { "The saved app icon access is invalid." }
        AppIconLocalState(names.mapNotNull(AppIcon::fromId).filterTo(linkedSetOf()) { it.canKeepLocally },
            preferences.getBoolean("migrated", false))
    }
    override fun merge(value: AppIconLocalState): AppIconLocalState = synchronized(preferences) {
        require(value.kept.all { it.canKeepLocally })
        val next = read().merged(value)
        check(preferences.edit().putStringSet("kept", next.kept.mapTo(linkedSetOf()) { it.wireId })
            .putBoolean("migrated", next.migrated).commit()) { "The app icon access could not be saved." }
        next
    }
}
