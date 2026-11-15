package dev.yab.android

import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.BitmapFactory
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.model.BrowserAppearance
import dev.yab.browser.ui.BrowserTheme
import dev.yab.core.sync.Clock
import dev.yab.core.sync.Record
import dev.yab.sync.AccountRecordsSnapshot
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.time.Instant

/** Actual compiled artwork/launcher state; account grant rows are synthetic consumer fixtures. */
@RunWith(AndroidJUnit4::class)
class AppIconCatalogDeviceTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private fun owned() = check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")

    @Test(timeout = 60_000)
    fun everyCatalogAndCharmVariantHasItsExactCompiledLauncherAndOriginalPicture() {
        owned()
        val native = AppIcons(context)
        val previous = native.selected().singleOrNull() ?: error("Exactly one initial launcher is required")
        val query = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER).setPackage(context.packageName)
        try {
            val all = context.packageManager.queryIntentActivities(query, PackageManager.MATCH_DISABLED_COMPONENTS)
            assertEquals(AppIcon.variants.map { it.component(context).className }.toSet(), all.map { it.activityInfo.name }.toSet())
            for (variant in AppIcon.variants) {
                val entry = all.single { it.activityInfo.name == variant.component(context).className }.activityInfo
                assertEquals(MainActivity::class.java.name, entry.targetActivity)
                assertEquals(context.resources.getIdentifier(variant.resourceName, "drawable", context.packageName), entry.icon)
                for (dark in listOf(false, true)) {
                    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                    BitmapFactory.decodeResource(context.resources, native.picture(variant, dark), bounds)
                    assertEquals(variant.alias, 1024, bounds.outWidth); assertEquals(variant.alias, 1024, bounds.outHeight)
                }
            }
            assertNotEquals(native.picture(AppIcon.Flat.variant(), false), native.picture(AppIcon.Flat.variant(), true))
            val first = AppIcon.Charm.variant(AppIconCharm.of("rose", "sky"))
            native.choose(first)
            assertEquals(listOf(first), native.selected())
            val second = AppIcon.Charm.variant(AppIconCharm.of("rose", "lilac"))
            native.choose(second)
            val realEntrance = context.packageManager.queryIntentActivities(query, 0).single()
            assertEquals(second.component(context).className, realEntrance.activityInfo.name)
            assertEquals(listOf(second), native.selected())
        } finally { native.choose(previous) }
    }

    @Test(timeout = 90_000)
    fun grantAndCharmUpdatesChangeThePickerWithoutChangingTheInstalledIconUntilUse() {
        owned()
        val native = AppIcons(context)
        val previous = native.selected().singleOrNull() ?: error("Exactly one initial launcher is required")
        val local = object : AppIconLocalStore {
            var saved = AppIconLocalState(migrated = true)
            override fun read() = saved
            override fun merge(value: AppIconLocalState): AppIconLocalState { saved = saved.merged(value); return saved }
        }
        fun setting(key: String, value: JsonElement) = Record("setting", key).updated(buildJsonObject { put("value", value) }, Clock("mac-fixture"))
        fun rows(right: String, ticket: Boolean = true) = listOf(setting(AppIcon.Ticket.grantKey, JsonPrimitive(ticket)),
            setting(AppIcon.Charm.grantKey, JsonPrimitive(true)), setting("invite.charm.left", JsonPrimitive("rose")), setting("invite.charm.right", JsonPrimitive(right)))
        val records = MutableStateFlow(AccountRecordsSnapshot("fixture-account-a", 1, rows("sky"), device = "fixture-phone"))
        val keeps = mutableListOf<AppIcon>()
        try {
            native.choose(AppIcon.Flat)
            compose.setContent { BrowserTheme(BrowserAppearance.LIGHT) { AppIconPicker(native, local, records, { icon, _ -> keeps += icon }) } }
            fun preview(icon: AppIcon) {
                val source = AppIconAccountFrame.from(records.value)
                val visible = AppIcon.entries.filter { source.access.visible(it, local.saved.kept, Instant.now()) }
                val title = compose.onNodeWithTag("settings.appIcon.preview.title").fetchSemanticsNode().config[androidx.compose.ui.semantics.SemanticsProperties.Text].single().text
                val from = visible.indexOfFirst { it.title == title }
                val target = visible.indexOf(icon)
                check(from >= 0 && target >= 0)
                repeat(kotlin.math.abs(target - from)) { compose.onNodeWithTag(if (target > from) "settings.appIcon.next" else "settings.appIcon.previous").performClick() }
                compose.onNodeWithTag("settings.appIcon.preview.title").assertTextEquals(icon.title)
            }
            preview(AppIcon.WaxSeal)
            compose.onNodeWithTag("settings.appIcon.use").assertIsNotEnabled()
            assertEquals(listOf(AppIcon.Flat.variant()), native.selected())
            preview(AppIcon.Ticket)
            compose.onNodeWithTag("settings.appIcon.use").performClick()
            compose.waitUntil(5000) { native.selected() == listOf(AppIcon.Ticket.variant()) }
            compose.onNodeWithText("In Use").assertExists()
            compose.runOnIdle { records.value = records.value.copy(records = rows("sky", ticket = false)) }
            // Friend rewards remain visible as locked choices, like Phone AppIconAccess.visible.
            compose.onNodeWithTag("settings.appIcon.preview.title").assertTextEquals(AppIcon.Ticket.title)
            compose.onNodeWithTag("settings.appIcon.use").assertIsNotEnabled()
            compose.onNodeWithText("Locked").assertExists()
            assertEquals(listOf(AppIcon.Ticket.variant()), native.selected())
            preview(AppIcon.Charm)
            compose.onNodeWithTag("settings.appIcon.use").performClick()
            compose.waitUntil(5000) { native.selected() == listOf(AppIcon.Charm.variant(AppIconCharm.of("rose", "sky"))) }
            compose.runOnIdle { records.value = records.value.copy(records = rows("lilac", ticket = false)) }
            compose.onNodeWithText("Use This Icon").assertExists()
            assertEquals(listOf(AppIcon.Charm.variant(AppIconCharm.of("rose", "sky"))), native.selected())
            compose.runOnIdle { records.value = records.value.copy(account = "fixture-account-b", epoch = 2, records = emptyList()) }
            // Account reset reconstructs the page from the actually installed icon.
            // Charm is always visible, but this account may not select/wear it.
            compose.onNodeWithTag("settings.appIcon.preview.title").assertTextEquals(AppIcon.Charm.title)
            compose.onNodeWithTag("settings.appIcon.use").assertIsNotEnabled()
            compose.onNodeWithText("Locked").assertExists()
            assertEquals(listOf(AppIcon.Charm.variant(AppIconCharm.of("rose", "sky"))), native.selected())
            assertTrue(local.saved.kept.isEmpty()); assertTrue(keeps.isEmpty())
        } finally { native.choose(previous) }
    }

    @Test(timeout = 30_000)
    fun actualPreferenceInstancesMergeAStaleMigrationWithNewlyKeptArtwork() {
        owned()
        val name = "icon-store-fixture-" + java.util.UUID.randomUUID()
        try {
            val migration = AndroidAppIconLocalStore(context, name)
            val picker = AndroidAppIconLocalStore(context, name)
            val captured = migration.read()
            picker.merge(AppIconLocalState(setOf(AppIcon.Pumpkin), migrated = true))
            migration.merge(captured.copy(migrated = true))
            assertEquals(setOf(AppIcon.Pumpkin), AndroidAppIconLocalStore(context, name).read().kept)
            assertTrue(AndroidAppIconLocalStore(context, name).read().migrated)
            picker.merge(AppIconLocalState(setOf(AppIcon.Ghost)))
            assertEquals(setOf(AppIcon.Pumpkin, AppIcon.Ghost), migration.read().kept)
        } finally { context.deleteSharedPreferences(name) }
    }
}
