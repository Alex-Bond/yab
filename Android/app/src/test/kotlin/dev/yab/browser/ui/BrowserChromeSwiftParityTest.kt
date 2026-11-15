package dev.yab.browser.ui

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/** Expectations come from the current Phone statements, executed by chrome-label-oracle.py. */
class BrowserChromeSwiftParityTest {
    private val vectors by lazy {
        checkNotNull(javaClass.getResourceAsStream("/chrome-label/current-ios-vectors.json"))
            .bufferedReader().use { Json.parseToJsonElement(it.readText()).jsonObject }
    }

    @Test fun currentSwiftCanonicalAddressDisplayMatchesIncludingPortsAndIpv6() {
        val rows = vectors.getValue("addresses").jsonArray
        assertEquals(13, rows.size)
        rows.forEach { value ->
            val row = value.jsonObject
            val url = row.getValue("url").jsonPrimitive.content
            assertEquals(url, row.getValue("shown").jsonPrimitive.content, browserChromeAddress(url))
        }
    }

    @Test fun currentSwiftWholeLabelLayoutMatchesEveryScalarInputAtThreeDensities() {
        val rows = vectors.getValue("geometry").jsonArray
        assertEquals(35, rows.size)
        rows.forEachIndexed { index, value ->
            val row = value.jsonObject
            for (density in listOf(1.0, 2.625, 3.0)) {
                val pose = BrowserChromeLabelPose(row.getValue("measured").jsonPrimitive.double * density,
                    row.getValue("width").jsonPrimitive.double * density, density)
                assertEquals("$index overflow at $density", row.getValue("overflow").jsonPrimitive.boolean, pose.overflow)
                assertEquals("$index natural at $density", row.getValue("natural").jsonPrimitive.double * density, pose.natural, 1e-8)
                assertEquals("$index left at $density", row.getValue("left").jsonPrimitive.double * density, pose.left, 1e-8)
                assertEquals("$index draw width at $density", row.getValue("drawWidth").jsonPrimitive.double * density, pose.natural, 1e-8)
            }
        }
    }
}
