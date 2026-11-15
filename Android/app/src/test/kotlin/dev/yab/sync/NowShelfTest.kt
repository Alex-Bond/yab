package dev.yab.sync

import dev.yab.core.sync.Clock
import dev.yab.core.sync.Record
import dev.yab.core.sync.Stamp
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files
import java.util.UUID

class NowShelfTest {
    private val clock = Clock("mac", now = { 1_700_000_000_000 })
    private fun record(id: String, order: Int = 0, web: String? = "https://mail.google.com/mail/u/0/#all/$id",
                       message: String? = "<$id@example.test>"): Record = Record("now", id).updated(buildJsonObject {
        put("device", "mac"); put("title", "Mail $id"); put("detail", "Read this message")
        put("who", "Sender"); put("host", "mail.google.com"); put("order", order)
        web?.let { put("web", it) }; message?.let { put("message", it) }
    }, clock)
    private fun rows(vararg records: Record) = NowShelfCodec.rows(records.toList(), setOf("mac"))
    private fun snapshot(rows: List<NowMailRow>) = NowShelfSnapshot(account = "account", device = "android",
        epoch = UUID.randomUUID().toString(), rows = rows)

    @Test fun genuineMailIsSortedAndBoundedWhileForeignOrModifiedOwnershipIsRefused() {
        val genuine = listOf(record("d", 3), record("b", 1), record("a", 1), record("c", 2))
        assertEquals(listOf("a", "b", "c"), NowShelfCodec.rows(genuine, setOf("mac")).map { it.id })
        val good = record("secure")
        val forged = good.copy(stamps = good.stamps + ("web" to Stamp(2_000_000_000_000, device = "other")))
        val unstamped = good.copy(stamps = good.stamps - "title")
        val deleted = good.removed(Stamp(2_000_000_000_000, device = "mac"))
        assertTrue(rows(forged, unstamped, deleted, good.copy(schema = 2), good.copy(collection = "task")).isEmpty())
        assertTrue("A revoked or unrecognized Mac is not a source", NowShelfCodec.rows(listOf(good), emptySet()).isEmpty())
        val malformed = good.copy(fields = JsonObject(good.fields + ("order" to JsonPrimitive("1"))))
        assertTrue(rows(malformed).isEmpty())
    }

    @Test fun widgetLinksAreAccountScopedAndNeverSupplyTheDestination() {
        val current = rows(record("thread+ /?", web = "https://mail.google.com/mail/u/0/#all/thread"))
        val saved = snapshot(current)
        val address = saved.link(current.single())
        val link = NowShelfCodec.parse(address)!!
        assertEquals("thread+ /?", link.id)
        assertEquals(current.single().web, NowShelfCodec.resolve(link, saved, "account", "android", current))
        assertNull(NowShelfCodec.resolve(link, saved, "another-account", "android", current))
        assertNull(NowShelfCodec.resolve(link, saved, "account", "another-device", current))
        assertNull(NowShelfCodec.resolve(link.copy(owner = "other-mac"), saved, "account", "android", current))
        assertNull(NowShelfCodec.resolve(link.copy(epoch = UUID.randomUUID().toString()), saved, "account", "android", current))
        assertNull(NowShelfCodec.parse("$address&web=https%3A%2F%2Fevil.test"))
        assertNull(NowShelfCodec.parse("$address&id=duplicate"))
        assertNull(NowShelfCodec.parse(address.replace("yab://now?", "yab://now/extra?")))
        assertNull(NowShelfCodec.parse(address.replace("yab://now?", "https://now?")))
        assertNull(NowShelfCodec.parse(address.replace("owner=mac", "owner=%00mac")))
    }

    @Test fun changedRemovedOrNewGenerationRowsCannotReuseAnOldTap() {
        val original = record("thread")
        val shown = rows(original)
        val saved = snapshot(shown)
        val link = NowShelfCodec.parse(saved.link(shown.single()))!!
        val changed = original.updated(JsonObject(original.visible + ("web" to JsonPrimitive("https://mail.google.com/mail/u/0/#all/changed"))), clock)
        val latest = rows(changed)
        assertNotEquals(shown.single().fingerprint, latest.single().fingerprint)
        assertNull(NowShelfCodec.resolve(link, saved, "account", "android", latest))
        assertNull(NowShelfCodec.resolve(link, saved, "account", "android", emptyList()))
        assertNull(NowShelfCodec.resolve(link, saved.copy(epoch = UUID.randomUUID().toString()), "account", "android", shown))
    }

    @Test fun messageOnlyRowsStayHonestAndUnsafeWebDestinationsAreRejected() {
        val messageOnly = rows(record("message-only", web = null))
        assertEquals("<message-only@example.test>", messageOnly.single().message)
        val saved = snapshot(messageOnly)
        assertNull("Android cannot resolve a generic RFC Message-ID into a mail app thread",
            NowShelfCodec.resolve(NowShelfCodec.parse(saved.link(messageOnly.single()))!!, saved, "account", "android", messageOnly))
        for (unsafe in listOf("javascript:alert(1)", "file:///data/private", "intent://mail/#Intent;end", "https://user:secret@mail.test/thread", "https://mail.test/\nthread")) {
            assertNull(unsafe, NowShelfCodec.safeWeb(unsafe))
            assertTrue(unsafe, rows(record("unsafe", web = unsafe)).isEmpty())
        }
        assertEquals("https://mail.test/thread#message", NowShelfCodec.safeWeb("https://mail.test/thread#message"))
        val typedWrong = record("malformed").let { it.copy(fields = JsonObject(it.fields + ("message" to JsonPrimitive(true)))) }
        assertTrue(rows(typedWrong).isEmpty())
    }

    @Test fun durableShelfRetainsSameAccountGenerationAndRotatesAfterClearOrAccountSwitch() {
        val directory = Files.createTempDirectory("now-shelf-test").toFile()
        try {
            val file = directory.resolve(NowShelfStore.FILE_NAME)
            val initialRows = rows(record("mail"))
            val first = NowShelfStore(file)
            assertNull(first.read()); assertTrue(first.write("account", "android", initialRows))
            val saved = first.read()!!
            val reopened = NowShelfStore(file)
            assertEquals(saved, reopened.read())
            assertFalse("Unchanged facts must not churn widget updates or tap generations", reopened.write("account", "android", initialRows))
            assertTrue(reopened.write("account", "android", rows(record("new-mail"))))
            assertEquals(saved.epoch, reopened.read()!!.epoch)
            assertTrue(reopened.write("another-account", "android", initialRows))
            assertNotEquals(saved.epoch, reopened.read()!!.epoch)
            assertTrue(reopened.clear()); assertFalse(reopened.clear()); assertNull(reopened.read())
            assertTrue(reopened.write("account", "android", initialRows))
            assertNotEquals(saved.epoch, reopened.read()!!.epoch)
            file.writeText("{\"format\":1,\"account\":\"account\"}")
            assertNull("A partial/corrupt write must not display another saved shelf", reopened.read())
            file.writeBytes(ByteArray(65_537))
            assertNull(reopened.read())
        } finally { directory.deleteRecursively() }
    }
}
