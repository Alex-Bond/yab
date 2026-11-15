package dev.yab.browser

import android.media.MediaCodecList
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** App-owned typed codec metadata only. No encoding, OS logs, UI dump or performance claim. */
class MotionCodecCapabilitiesTest {
    @Test fun boundedAvcMetadataReportsExactIosViewportAtSixtyFramesPerSecond() {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        val records = JSONArray()
        var complete = true
        val infos = MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos
        if (infos.size > 256) complete = false
        for (info in infos.take(256)) {
            if (!info.isEncoder || info.supportedTypes.none { it.equals("video/avc", ignoreCase = true) }) continue
            if (records.length() >= 32) { complete = false; break }
            val name = info.name
            if (!name.matches(Regex("[A-Za-z0-9._-]{1,200}"))) { complete = false; continue }
            val record = JSONObject().put("name", name)
            records.put(record)
            try {
                val video = requireNotNull(info.getCapabilitiesForType("video/avc").videoCapabilities)
                record.put("widthAlignment", video.widthAlignment).put("heightAlignment", video.heightAlignment)
                val supported = try { video.areSizeAndRateSupported(1206, 2622, 60.0) } catch (_: IllegalArgumentException) { false }
                record.put("supports1206x2622At60", supported).put("query", "COMPLETE")
            } catch (_: Exception) {
                complete = false
                record.put("query", "UNAVAILABLE")
            }
        }
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val folder = File(context.getExternalFilesDir(null), "instrumentation/motion-codecs").apply { check(isDirectory || mkdirs()) }
        File(folder, "avc-1206x2622-60.json").writeText(JSONObject().put("schemaVersion", 1)
            .put("api", "MediaCodecList.ALL_CODECS filtered to AVC encoders, and VideoCapabilities")
            .put("widthPx", 1206).put("heightPx", 2622).put("requestedFps", 60)
            .put("enumerationComplete", complete).put("encoders", records)
            .put("encodingAttempted", false).put("fullResolutionCaptureVerified", false)
            .put("frameCadenceVerified", false).put("physicalDeviceSmoothnessVerified", false)
            .put("rawOsDataCollected", false).toString(2))
        assertTrue("The bounded AVC metadata projection could not complete", complete)
        assertTrue("No AVC encoder is visible to the owned application", records.length() > 0)
        // A complete query may legitimately report no supporting encoder. That
        // remains a capability finding, never a full-resolution recording pass.
    }
}
