package dev.yab.shield

import java.io.File
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

class ShieldFiltersTest {
    @Test fun badfilterAndUnsupportedOptionsNeverTurnIntoBroaderRules() {
        val rules = ShieldFilters.convert(listOf("||ads.example^\n||kept.example^\n/ads/${'$'}redirect=noopjs\n||ads.example^${'$'}badfilter"))
        assertEquals(1, rules.blocks.size); assertEquals(3, rules.skipped)
        assertEquals(ShieldFilters.onSite("kept.example"), rules.blocks.single().filter)
    }
    @Test fun genericExceptionDoesNotBecomeANetworkAllowAndElemhideIsSiteBound() {
        val rules = ShieldFilters.convert(listOf("##.ad\nsite.example##.own\n@@||site.example^${'$'}elemhide\n@@||other.example^${'$'}generichide"))
        assertEquals(0, rules.exceptions.size); assertEquals(2, rules.unhide.size)
        assertTrue(rules.blocks.isEmpty()); assertEquals(1, rules.generic.size)
    }
    @Test fun repeatedOrdinaryAndImportantBlocksKeepIndependentPrecedenceInEitherListOrder() {
        val ordinary="||ads.example^${'$'}script"
        val important="||ads.example^${'$'}script,important"
        val exception="@@||ads.example^${'$'}script"
        for (ordered in listOf(listOf(ordinary,exception,important),listOf(important,exception,ordinary))) {
            val rules=ShieldFilters.convert(listOf(ordered.joinToString("\n"),(ordered+ordered).joinToString("\n")))
            assertEquals(1,rules.blocks.size);assertEquals(1,rules.important.size);assertEquals(1,rules.exceptions.size)
            assertEquals(rules.blocks.single(),rules.important.single())
            assertEquals("allow",rules.exceptions.single().action)
            assertEquals(listOf("script"),rules.important.single().types)
        }
    }
    @Test fun elemhideStillRemovesOwnHidingAfterAnIdenticalGenericExceptionWasAlreadySeen() {
        val generic="@@||site.example^${'$'}generichide"
        val all="@@||site.example^${'$'}elemhide"
        for (ordered in listOf(listOf(generic,all),listOf(all,generic))) {
            val rules=ShieldFilters.convert(listOf("##.generic\nsite.example##.own\nother.example##.other",(ordered+ordered).joinToString("\n")))
            assertEquals(1,rules.unhide.size);assertTrue(rules.exceptions.isEmpty())
            assertEquals(listOf("site.example"),rules.unhide.single().ifDomain)
            assertEquals(listOf(".other"),rules.blocks.map { it.selector })
            assertEquals(listOf("other.example"),rules.hidingSites)
            assertEquals(listOf(".generic"),rules.generic.map { it.selector })
        }
    }
    @Test fun badfilterStillWithdrawsOnlyItsOriginalPrecedenceRule() {
        val ordinary="||ads.example^${'$'}script"
        val important="||ads.example^${'$'}script,important"
        val ordinaryOff=ShieldFilters.convert(listOf("$ordinary\n$important\n$ordinary,badfilter"))
        assertTrue(ordinaryOff.blocks.isEmpty());assertEquals(1,ordinaryOff.important.size)
        val importantOff=ShieldFilters.convert(listOf("$ordinary\n$important\n$important,badfilter"))
        assertEquals(1,importantOff.blocks.size);assertTrue(importantOff.important.isEmpty())
    }
    @Test fun documentRulesDistinguishTopPageChildFramesAndSubresources() {
        // Slash-delimited /regex/ is deliberately unsupported by the production Swift converter.
        // The native Swift page/iframe regression uses /adv/* for a supported path filter.
        val rules = ShieldFilters.convert(listOf("/adv/*\n/frame/*${'$'}subdocument\n@@||spared.example^${'$'}document"))
        assertEquals(3, rules.blocks.size)
        assertEquals(0, rules.skipped)
        val path = rules.blocks.filter { it.filter == ShieldFilters.urlFilter("/adv/*") }
        assertEquals(2, path.size)
        val resources = path.single { "document" !in it.types }
        assertTrue(resources.types.containsAll(listOf("script", "image", "popup")))
        assertNull(resources.context)
        assertEquals("child-frame", path.single { it.types == listOf("document") }.context)
        val child = rules.blocks.single { it.filter == ShieldFilters.urlFilter("/frame/*") }
        assertEquals(listOf("document"), child.types)
        assertEquals("child-frame", child.context)
        assertEquals(listOf("spared.example"), rules.exceptions.single().ifDomain)
        assertTrue(rules.exceptions.single().types.isEmpty())
        assertEquals(".*", rules.exceptions.single().filter)
        assertNull(rules.exceptions.single().context)
        val unsupported = ShieldFilters.convert(listOf("/adv/\n/frame/${'$'}subdocument"))
        assertTrue(unsupported.blocks.isEmpty())
        assertEquals(2, unsupported.skipped)
    }
    @Test fun bundledAmazonCartExceptionsStayLimitedToAmazonSites() {
        val asset = listOf(File("src/main/assets/web_extensions/shield/base.txt"), File("app/src/main/assets/web_extensions/shield/base.txt"))
            .first(File::isFile)
        val rules = ShieldFilters.convert(listOf(asset.readText())).exceptions.filter { "unagi" in it.filter }
        // Each of the two hosts has separate resource and child-frame rules.
        assertEquals(4, rules.size)
        for (host in listOf("unagi-eu.amazon.com", "unagi.amazon.com")) {
            val matching = rules.filter { it.filter == ShieldFilters.onSite(host) }
            assertEquals(2, matching.size)
            assertEquals(setOf(null, "child-frame"), matching.map { it.context }.toSet())
        }
        val sites = setOf("amazon.com", "amazon.co.uk", "amazon.de", "amazon.fr", "amazon.it", "amazon.es", "amazon.ca", "amazon.co.jp", "amazon.in", "amazon.com.au")
        rules.forEach { assertEquals(sites, it.ifDomain.toSet()); assertTrue(it.unlessDomain.isEmpty()) }
    }
    @Test fun independentSharedSwiftConverterAndCatalogMatch() {
        val path = System.getenv("YAB_SHIELD_ORACLE")
        assumeTrue("Run Android/scripts/shield-oracle.sh and export YAB_SHIELD_ORACLE for the cross-platform oracle", path != null)
        val oracle = Json.parseToJsonElement(File(path!!).readText()).jsonObject
        assertEquals(ShieldFilters.SCHEMA, oracle.getValue("schema").jsonPrimitive.int)
        assertEquals(JsonArray(ShieldLists.sources.map { source -> buildJsonObject { put("name", source.name); put("url", source.url); put("least", source.least) } }), oracle["sources"])
        val asset = listOf(File("src/main/assets/web_extensions/shield/base.txt"), File("app/src/main/assets/web_extensions/shield/base.txt"))
            .firstOrNull(File::isFile) ?: error("Shield base asset is missing")
        assertEquals(oracle.getValue("base").jsonPrimitive.content, asset.readText())
        for (fixture in oracle.getValue("cases").jsonArray) {
            val item = fixture.jsonObject
            val rules = ShieldFilters.convert(item.getValue("texts").jsonArray.map { it.jsonPrimitive.content })
            val result = buildJsonObject {
                put("blocks", JsonArray(rules.blocks.map(::webKit))); put("exceptions", JsonArray(rules.exceptions.map(::webKit)))
                put("important", JsonArray(rules.important.map(::webKit))); put("generic", JsonArray(rules.generic.map(::webKit)))
                put("unhide", JsonArray(rules.unhide.map(::webKit))); put("skipped", rules.skipped); put("hidingSites", JsonArray(rules.hidingSites.map(::JsonPrimitive)))
            }
            assertEquals(item.getValue("name").jsonPrimitive.content, item["result"], result)
        }
    }
    private fun webKit(rule: ShieldRule) = buildJsonObject {
        put("trigger", buildJsonObject {
            put("url-filter", rule.filter); if (rule.caseSensitive) put("url-filter-is-case-sensitive", true)
            if (rule.types.isNotEmpty()) put("resource-type", JsonArray(rule.types.map(::JsonPrimitive)))
            rule.party?.let { put("load-type", JsonArray(listOf(JsonPrimitive(it)))) }
            rule.context?.let { put("load-context", JsonArray(listOf(JsonPrimitive(it)))) }
            if (rule.ifDomain.isNotEmpty()) put("if-domain", JsonArray(rule.ifDomain.map { JsonPrimitive("*$it") }))
            if (rule.unlessDomain.isNotEmpty()) put("unless-domain", JsonArray(rule.unlessDomain.map { JsonPrimitive("*$it") }))
        })
        put("action", buildJsonObject {
            put("type", when (rule.action) { "block" -> "block"; "allow" -> "ignore-previous-rules"; else -> "css-display-none" })
            if (rule.action == "hide") put("selector", rule.selector)
        })
    }
}

class ShieldPolicyTest {
    @Test fun macImportsAreReadOnlyDefaultsAndGlobalOffDominatesSiteChoices() = runTest {
        val store = ShieldPolicyStore()
        store.importMac(true, listOf("WWW.EXAMPLE.COM"))
        assertFalse(store.state.value.enabled("example.com", false))
        store.setSite("example.com", false, true)
        assertTrue(store.state.value.enabled("example.com", false))
        assertFalse(store.state.value.enabled("example.com", true))
        store.importMac(false, emptyList()); assertFalse(store.state.value.enabled("example.com", false))
        store.setGlobal(true); assertTrue(store.state.value.global)
        store.importMac(null, null); assertTrue(store.state.value.enabled("example.com", false))
    }
    @Test fun privateSiteChoiceNeverReachesDiskOrAnotherStore() = runTest {
        val directory = java.nio.file.Files.createTempDirectory("shield-policy").toFile()
        try {
            val file = File(directory, "policy.json"); val store = ShieldPolicyStore(file)
            store.setSite("public.example", false, false); val before = file.readBytes()
            store.setSite("secret.example", true, false)
            assertArrayEquals(before, file.readBytes()); assertFalse(file.readText().contains("secret"))
            val recreated = ShieldPolicyStore(file)
            assertFalse(recreated.state.value.enabled("public.example", false)); assertTrue(recreated.state.value.enabled("secret.example", true))
            assertTrue(recreated.state.value.enabled("public.example", true))
        } finally { directory.deleteRecursively() }
    }
}
