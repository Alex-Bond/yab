package dev.yab.chromium

import dev.yab.browser.model.BrowserTab
import dev.yab.browser.model.WebsiteProfile
import dev.yab.sync.AccountRecordsSnapshot
import dev.yab.sync.SyncIdentityLease
import dev.yab.sync.nativeAccountOwnerCurrent
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException
import java.nio.file.Files
import java.security.MessageDigest
import java.util.function.BooleanSupplier

class ChromeOwnerProducerTest {
    private class Bytes : ChromeRegistryBytes {
        var value: ByteArray? = null
        var failWrite = false
        var afterWrite: (() -> Unit)? = null
        override fun read() = value?.copyOf()
        override fun replace(expectedSHA256: String?, bytes: ByteArray) {
            if (failWrite) throw IOException("owned fixture disk failure")
            check(value?.let { MessageDigest.getInstance("SHA-256").digest(it).joinToString("") { part -> "%02x".format(part) } } == expectedSHA256)
            value = bytes.copyOf(); afterWrite?.invoke()
        }
        override fun close() = Unit
    }
    private class Port(var saved: ChromeOwnerIdentity? = null) : ChromeBootstrapPort {
        var freshCalls = 0; var savedCalls = 0; var revoked = false; var released = false
        override fun activateSavedOwner(accountUUID: String, expectedOwnerEpochUUID: String, lease: BooleanSupplier): Boolean {
            savedCalls++
            return lease.getAsBoolean() && saved?.let { it.accountUUID == accountUUID && it.ownerEpochUUID == expectedOwnerEpochUUID } == true
        }
        override fun startNewOwner(accountUUID: String, ownerEpochUUID: String, lease: BooleanSupplier) {
            check(lease.getAsBoolean()); freshCalls++
        }
        override fun revokeOwner() { revoked = true }
        override fun releaseAfterTeardown() { check(revoked); released = true }
    }
    private val account = ChromeOwnerSource.Paired("opaque/non-uuid/account-A")
    private fun ownership(source: ChromeOwnerSource = account, epoch: Long = 4) = when (source) {
        ChromeOwnerSource.StandaloneLocal -> ChromeSyncOwnership(null, null, epoch, true)
        is ChromeOwnerSource.Paired -> ChromeSyncOwnership(source.account, "device-fixture", epoch, true)
    }
    private fun tab(id: String, privateMode: Boolean = false) = BrowserTab(id, isPrivate = privateMode, createdAt = 1)

    @Test fun durableOpaqueMappingsRestoreAcrossRegistryReopenWithoutUsingDeviceOrSyncEpochAsIdentity() {
        val directory = Files.createTempDirectory("chrome-native-identities-").toFile()
        val file = directory.resolve("identities.json")
        try {
            val (first, row) = ChromeIdentityRegistry(FileChromeRegistryBytes(file)).use { registry ->
                val first = registry.beginNewOwner(account)
                val row = registry.publicIdentity(first, "shared", "opaque-tab:1")
                assertEquals(row, registry.publicIdentity(first, "shared", "opaque-tab:1"))
                first to row
            }
            ChromeIdentityRegistry(FileChromeRegistryBytes(file)).use { registry ->
                assertEquals(first, registry.savedOwner(account))
                assertEquals(row, registry.publicIdentity(first, "shared", "opaque-tab:1"))
                val isolated = registry.publicIdentity(first, "space-opaque-id", "opaque-tab:2")
                assertNotEquals(row.namespaceUUID, isolated.namespaceUUID)
                val newGeneration = registry.beginNewOwner(account)
                assertEquals(first.accountUUID, newGeneration.accountUUID)
                assertNotEquals(first.ownerEpochUUID, newGeneration.ownerEpochUUID)
                assertEquals(row, registry.publicIdentity(newGeneration, "shared", "opaque-tab:1"))
                assertThrows(IllegalStateException::class.java) { registry.publicIdentity(first, "shared", "opaque-tab:3") }
            }
            assertFalse(file.readText().contains("device-fixture"))
        } finally { directory.deleteRecursively() }
    }

    @Test fun standaloneTagCannotCollideWithAnOpaquePairedAccountOrReuseItsWebsiteJar() {
        ChromeIdentityRegistry(Bytes()).use { registry ->
            val local = registry.beginNewOwner(ChromeOwnerSource.StandaloneLocal)
            val paired = registry.beginNewOwner(ChromeOwnerSource.Paired("standalone"))
            assertNotEquals(local.accountUUID, paired.accountUUID)
            val one = registry.publicIdentity(local, "shared", "same-tab")
            val two = registry.publicIdentity(paired, "shared", "same-tab")
            assertNotEquals(one.namespaceUUID, two.namespaceUUID); assertNotEquals(one.tabUUID, two.tabUUID)
        }
    }

    @Test fun checksumCorruptionUnknownFormatAndOversizeArePreservedAndNeverBecomeNewOwners() {
        val storage = Bytes()
        ChromeIdentityRegistry(storage).use { it.beginNewOwner(account) }
        val valid = storage.value!!.copyOf()
        for (broken in listOf(valid.copyOf().apply { this[lastIndex / 2] = (this[lastIndex / 2].toInt() xor 1).toByte() },
            valid.toString(Charsets.UTF_8).replace("\"format\":1", "\"format\":99").toByteArray(), ByteArray(2 * 1024 * 1024 + 1))) {
            storage.value = broken
            assertThrows(Exception::class.java) { ChromeIdentityRegistry(storage) }
            assertArrayEquals(broken, storage.value)
        }
    }

    @Test fun oneRegistryWriterAndExternalByteChangeFailClosed() {
        val directory = Files.createTempDirectory("chrome-owner-lock-").toFile(); val file = directory.resolve("identities.json")
        try {
            ChromeIdentityRegistry(FileChromeRegistryBytes(file)).use { registry ->
                registry.beginNewOwner(account)
                assertThrows(Exception::class.java) { FileChromeRegistryBytes(file) }
                file.writeText("foreign-corruption")
                assertThrows(IllegalStateException::class.java) { registry.savedOwner(account) }
                assertEquals("foreign-corruption", file.readText())
            }
        } finally { directory.deleteRecursively() }
    }

    @Test fun failedPersistenceCannotIssueActivationOrDiscardPriorSavedIdentity() {
        val storage = Bytes(); val registry = ChromeIdentityRegistry(storage)
        val old = registry.beginNewOwner(account); val original = storage.value!!.copyOf()
        storage.failWrite = true
        val producer = ChromeOwnerProducer(registry) { ownership() }
        assertThrows(IOException::class.java) { producer.prepareNew(account) }
        assertArrayEquals(original, storage.value); assertEquals(old, registry.savedOwner(account))
        val saved = producer.prepareSaved(account)!!
        assertEquals(old, saved.identity); producer.cancelPrepared(saved); registry.close()
    }

    @Test fun savedBootstrapRequiresExactDurableEpochAndDoesNotAutomaticallyStartNewOwner() {
        val registry = ChromeIdentityRegistry(Bytes()); val original = registry.beginNewOwner(account)
        val producer = ChromeOwnerProducer(registry) { ownership() }
        val prepared = producer.prepareSaved(account)!!
        val wrongGeneration = registry.beginNewOwner(account)
        val port = Port(wrongGeneration)
        assertFalse(producer.activate(prepared, port))
        assertEquals(1, port.savedCalls); assertEquals(0, port.freshCalls)
        assertFalse(prepared.lease.getAsBoolean()); assertEquals(original.accountUUID, wrongGeneration.accountUUID)
        registry.close()
    }

    @Test fun accountDeviceEpochAndRemovalLeasesAreStickyAndRevokeBeforeReplacement() {
        val registry = ChromeIdentityRegistry(Bytes()); var current = ownership()
        val producer = ChromeOwnerProducer(registry) { current }
        val owner = producer.prepareNew(account); val port = Port()
        assertTrue(producer.activate(owner, port))
        assertThrows(IllegalStateException::class.java) { producer.prepareNew(account) }
        current = current.copy(epoch = current.epoch + 1)
        producer.ownershipChanged(); assertTrue(port.revoked); assertFalse(owner.lease.getAsBoolean())
        current = ownership(); assertFalse(owner.lease.getAsBoolean())
        producer.releaseAfterTeardown(owner); assertTrue(port.released)
        for (replacement in listOf(ownership().copy(device = "another-device"), ownership().copy(account = "B"), ownership().copy(available = false))) {
            current = ownership(); val next = producer.prepareSaved(account)!!; assertTrue(producer.activate(next, Port(next.identity)))
            current = replacement; assertFalse(next.lease.getAsBoolean())
            producer.revoke(next); producer.releaseAfterTeardown(next)
        }
        registry.close()
    }

    @Test fun standaloneCannotActivateDuringPairedSessionOrWhenAtomicSourceIsUnavailable() {
        val registry = ChromeIdentityRegistry(Bytes()); var current = ownership()
        val producer = ChromeOwnerProducer(registry) { current }
        assertThrows(IllegalStateException::class.java) { producer.prepareNew(ChromeOwnerSource.StandaloneLocal) }
        current = ownership(ChromeOwnerSource.StandaloneLocal).copy(available = false)
        assertThrows(IllegalStateException::class.java) { producer.prepareNew(ChromeOwnerSource.StandaloneLocal) }
        current = ownership(ChromeOwnerSource.StandaloneLocal)
        val owner = producer.prepareNew(ChromeOwnerSource.StandaloneLocal)
        assertTrue(producer.activate(owner, Port())); current = ownership()
        assertFalse(owner.lease.getAsBoolean()); producer.revoke(owner); producer.releaseAfterTeardown(owner)
        registry.close()
    }

    @Test fun accountChangeDuringIOCannotReachBootstrapAndLeavesNoPreparedTicket() {
        val storage = Bytes(); val registry = ChromeIdentityRegistry(storage); var current = ownership()
        val producer = ChromeOwnerProducer(registry) { current }
        storage.afterWrite = { current = current.copy(epoch = current.epoch + 1) }
        assertThrows(IllegalStateException::class.java) { producer.prepareNew(account) }
        storage.afterWrite = null
        val saved = producer.prepareSaved(account)!!; val port = Port(saved.identity)
        assertTrue(producer.activate(saved, port)); producer.revoke(saved); producer.releaseAfterTeardown(saved)
        registry.close()
    }

    @Test fun privateIDsNeverReachDiskAndAreFreshAfterActualPrivateDisposal() {
        val storage = Bytes(); val registry = ChromeIdentityRegistry(storage)
        val producer = ChromeOwnerProducer(registry) { ownership() }
        val owner = producer.prepareNew(account); assertTrue(producer.activate(owner, Port()))
        val before = storage.value!!.copyOf()
        val privateTab = tab("PRIVATE-TAB-SENTINEL", true); val privateProfile = WebsiteProfile("PRIVATE-PROFILE-SENTINEL", true)
        val first = producer.tab(owner, privateTab, privateProfile, BooleanSupplier { true })
        assertTrue(first.identity.privateMode && first.identity.inMemory && first.lease.getAsBoolean())
        assertEquals(first.identity, producer.tab(owner, privateTab, privateProfile, BooleanSupplier { true }).identity)
        assertArrayEquals(before, storage.value)
        assertFalse(storage.value!!.toString(Charsets.UTF_8).contains("PRIVATE-"))
        producer.privateTabsDisposed(owner)
        assertFalse(first.lease.getAsBoolean())
        val second = producer.tab(owner, privateTab, privateProfile, BooleanSupplier { true })
        assertNotEquals(first.identity.tabUUID, second.identity.tabUUID); assertNotEquals(first.identity.namespaceUUID, second.identity.namespaceUUID)
        assertArrayEquals(before, storage.value)
        assertThrows(IllegalArgumentException::class.java) { producer.tab(owner, privateTab, WebsiteProfile("shared"), BooleanSupplier { true }) }
        producer.revoke(owner); producer.releaseAfterTeardown(owner); registry.close()
    }

    @Test fun tabSourceChangedDuringMappingCannotProduceLiveNativeIdentity() {
        val storage = Bytes(); val registry = ChromeIdentityRegistry(storage)
        val producer = ChromeOwnerProducer(registry) { ownership() }; val owner = producer.prepareNew(account)
        assertTrue(producer.activate(owner, Port())); var current = true
        storage.afterWrite = { current = false }
        assertThrows(IllegalStateException::class.java) { producer.tab(owner, tab("public-row"), WebsiteProfile("shared"), BooleanSupplier { current }) }
        storage.afterWrite = null; current = true
        val mapped = producer.tab(owner, tab("public-row"), WebsiteProfile("shared"), BooleanSupplier { current })
        assertTrue(mapped.lease.getAsBoolean()); current = false; assertFalse(mapped.lease.getAsBoolean())
        current = true; assertFalse(mapped.lease.getAsBoolean())
        producer.revoke(owner); producer.releaseAfterTeardown(owner); registry.close()
    }

    @Test fun atomicAccountPublicationRequiresImmediateIdentityAndCloseGateBeforeNativeUse() {
        val image = AccountRecordsSnapshot(account = "A", device = "device-A", epoch = 9, phase = "live")
        val lease = SyncIdentityLease("A", "device-A", 9)
        assertTrue(nativeAccountOwnerCurrent(image, image, lease, 9, false))
        // Network disconnection alone is not an account switch or permission to use another jar.
        assertTrue(nativeAccountOwnerCurrent(image, image.copy(phase = "waiting"), lease, 9, false))
        for (changed in listOf(image.copy(account = "B"), image.copy(device = "device-B"), image.copy(epoch = 10), image.copy(removed = true))) {
            assertFalse(nativeAccountOwnerCurrent(image, changed, lease, 9, false))
        }
        assertFalse(nativeAccountOwnerCurrent(image, image, lease.copy(device = "device-B"), 9, false))
        assertFalse(nativeAccountOwnerCurrent(image, image, lease.copy(epoch = 10), 9, false))
        assertFalse(nativeAccountOwnerCurrent(image, image, null, 9, false))
        assertFalse(nativeAccountOwnerCurrent(image, image, lease, 9, true))
        val standalone = AccountRecordsSnapshot(epoch = 11)
        assertTrue(nativeAccountOwnerCurrent(standalone, standalone, null, 11, false))
        assertFalse(nativeAccountOwnerCurrent(standalone, standalone, null, 11, true))
        assertFalse(nativeAccountOwnerCurrent(standalone, standalone, lease, 11, false))
        assertFalse(nativeAccountOwnerCurrent(standalone, standalone, null, 12, false))
    }
}
