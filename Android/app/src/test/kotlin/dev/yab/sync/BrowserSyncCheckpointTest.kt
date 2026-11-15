package dev.yab.sync

import dev.yab.browser.model.*
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files

class BrowserSyncCheckpointTest {
    private fun snapshot(name: String) = BrowserSnapshot(spaces = listOf(BrowserSpace("space", name)), selectedSpaceId = "space")
    @Test fun interruptedBrowserDiskWriteRecoversCommittedTargetInsteadOfRevertingSync() {
        val before = snapshot("Before"); val target = snapshot("From Mac")
        val checkpoint = BrowserSyncCheckpoint(account = "account", device = "android", target = target,
            knownLocalHashes = listOf(BrowserSnapshotHash.of(before), BrowserSnapshotHash.of(target)), localSearch = false)
        assertEquals(target, checkpoint.restore(before))
        assertEquals(target, checkpoint.restore(target))
        val newLocalEdit = snapshot("Edited after restart")
        assertEquals(newLocalEdit, checkpoint.restore(newLocalEdit))
    }
    @Test fun checkpointPersistsExplicitSearchChoiceAndRefusesOtherAccountOrDevice() {
        val directory = Files.createTempDirectory("browser-checkpoint").toFile(); val file = directory.resolve("checkpoint.json")
        try {
            val target = snapshot("Personal").copy(settings = BrowserSettings(searchEngine = SearchEngine.KAGI))
            val checkpoint = BrowserSyncCheckpoint(account = "one", device = "android", target = target,
                knownLocalHashes = listOf(BrowserSnapshotHash.of(target)), localSearch = true)
            BrowserSyncCheckpointStore(file, "one", "android").save(checkpoint)
            assertEquals(checkpoint, BrowserSyncCheckpointStore(file, "one", "android").load())
            assertTrue(BrowserSyncCheckpointStore(file, "one", "android").load()!!.localSearch)
            assertThrows(IllegalArgumentException::class.java) { BrowserSyncCheckpointStore(file, "two", "android").load() }
            assertThrows(IllegalArgumentException::class.java) { BrowserSyncCheckpointStore(file, "one", "other-device").load() }
            val privateSnapshot = target.copy(spaces = listOf(BrowserSpace("private", "Private", isPrivate = true)))
            assertThrows(IllegalArgumentException::class.java) { BrowserSyncCheckpointStore(file, "one", "android").save(checkpoint.copy(target = privateSnapshot)) }
        } finally { directory.deleteRecursively() }
    }
}
