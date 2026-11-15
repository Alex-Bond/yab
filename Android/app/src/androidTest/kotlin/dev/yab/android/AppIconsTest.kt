package dev.yab.android

import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Real PackageManager state and actual launcher entrance, on the disposable device. */
@RunWith(AndroidJUnit4::class)
class AppIconsTest {
    @Test(timeout = 60_000)
    fun alternativeHasOneWorkingLauncherAndKeepsBrowserIntent() {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val manager = AppIcons(context)
        val previous = manager.selected().singleOrNull() ?: AppIcon.Flat.variant()
        try {
            manager.choose(AppIcon.Opal)
            val query = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER).setPackage(context.packageName)
            val entrances = context.packageManager.queryIntentActivities(query, 0)
            assertEquals(1, entrances.size)
            assertEquals(AppIcon.Opal.component(context).className, entrances.single().activityInfo.name)
            assertEquals(MainActivity::class.java.name, entrances.single().activityInfo.targetActivity)
            assertEquals(R.drawable.app_icon_opal, entrances.single().activityInfo.icon)
            val launch = query.setComponent(AppIcon.Opal.component(context)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            ActivityScenario.launch<MainActivity>(launch).use { activity ->
                activity.onActivity { assertFalse(it.isFinishing) }
            }
            val web = Intent(Intent.ACTION_VIEW, Uri.parse("https://example.com/")).addCategory(Intent.CATEGORY_BROWSABLE).setPackage(context.packageName)
            val browsers = context.packageManager.queryIntentActivities(web, PackageManager.MATCH_DEFAULT_ONLY)
            assertEquals(listOf(MainActivity::class.java.name), browsers.map { it.activityInfo.name }.distinct())
        } finally {
            manager.choose(previous)
        }
    }
}
