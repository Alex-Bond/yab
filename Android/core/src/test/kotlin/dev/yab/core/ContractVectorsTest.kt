package dev.yab.core

import dev.yab.core.crypto.*
import dev.yab.core.sync.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.Base64

internal fun vectors(): JsonObject {
    val resource = object {}.javaClass.getResourceAsStream("/vectors-v1.json")
    val text = resource?.bufferedReader()?.use { it.readText() } ?: generateSequence(File(System.getProperty("user.dir"))) { it.parentFile }
        .map { File(it, "SharedContracts/sync/vectors-v1.json") }.first { it.isFile }.readText()
    return Json.parseToJsonElement(text).jsonObject
}
internal fun String.bytes(): ByteArray = chunked(2).map { it.toInt(16).toByte() }.toByteArray()

class ContractVectorsTest {
    @Test fun rootRecoveryAndEncryptedRecordsMatchIndependentVectors() {
        val vector = vectors(); val root = vector.getValue("root").jsonObject
        val seal = Seal(root.getValue("hex").jsonPrimitive.content.bytes())
        assertEquals(root["account"]!!.jsonPrimitive.content, seal.account)
        assertEquals(root["auth"]!!.jsonPrimitive.content, seal.secret)
        assertEquals(root["recovery"]!!.jsonPrimitive.content, seal.recovery)
        assertArrayEquals(seal.raw(), Seal.fromRecovery(seal.recovery.lowercase().replace('-', ' '))!!.raw())
        assertNull(Seal.fromRecovery("AAAA"))
        val record = vector.getValue("record").jsonObject
        val expected = Record.parse(record.getValue("json").jsonPrimitive.content)
        val name = record.getValue("name").jsonPrimitive.content
        assertEquals(name, seal.name(expected.key))
        val box = Base64.getDecoder().decode(record.getValue("sealed").jsonPrimitive.content)
        assertEquals(expected, seal.open(box, name))
        val nonce = "000102030405060708090a0b".bytes()
        assertArrayEquals(box, Crypto.encrypt(root.getValue("recordsKey").jsonPrimitive.content.bytes(), record.getValue("json").jsonPrimitive.content.toByteArray(), name.toByteArray(), nonce))
        val altered = box.copyOf().also { it[it.lastIndex] = (it.last().toInt() xor 1).toByte() }
        assertThrows(Exception::class.java) { seal.open(altered, name) }
        assertThrows(Exception::class.java) { seal.open(box, seal.name(RecordKey("tab", "another"))) }
        assertThrows(Exception::class.java) { Seal.make().open(box, name) }
        assertEquals(expected, seal.open(seal.seal(expected), name))
        val hidden = vector.getValue("secret").jsonObject
        val key = hidden.getValue("key").jsonPrimitive.content.split('/', limit = 2).let { RecordKey(it[0], it[1]) }
        assertArrayEquals(hidden.getValue("text").jsonPrimitive.content.toByteArray(), seal.reveal(hidden.getValue("sealed").jsonPrimitive.content, key))
        assertThrows(Exception::class.java) { seal.reveal(hidden.getValue("sealed").jsonPrimitive.content, RecordKey("login", "other")) }
    }

    @Test fun authenticatedPairingV2MatchesX25519AndPbkdf2Vectors() {
        val vector = vectors(); val p = vector.getValue("pairing").jsonObject
        val code = p.getValue("code").jsonPrimitive.content
        val receiver = Joining(code, p.getValue("receiverPrivate").jsonPrimitive.content.bytes())
        assertEquals(p["box"]!!.jsonPrimitive.content, receiver.box)
        assertEquals(p["posted"]!!.jsonPrimitive.content, receiver.posted)
        assertEquals(p["check"]!!.jsonPrimitive.content, receiver.check)
        assertArrayEquals(p["receiverPublic"]!!.jsonPrimitive.content.bytes(), receiver.publicKey)
        assertArrayEquals(receiver.publicKey, Joining.verified(receiver.posted, "k7qm 4xtd"))
        assertNull(Joining.verified(Base64.getEncoder().encodeToString(receiver.publicKey), code))
        assertNull(Joining.verified(receiver.posted, "ZZZZ-ZZZZ"))
        val raw = vector.getValue("root").jsonObject.getValue("hex").jsonPrimitive.content.bytes()
        val envelope = Base64.getDecoder().decode(p.getValue("envelope").jsonPrimitive.content)
        assertArrayEquals(raw, receiver.open(envelope).raw())
        assertArrayEquals(envelope, Joining.envelope(raw, receiver.publicKey, code,
            p.getValue("senderPrivate").jsonPrimitive.content.bytes(), "000102030405060708090a0b".bytes()))
        assertThrows(Exception::class.java) { Joining.seal(Seal(raw), ByteArray(32), code) }
        assertEquals(code, Joining.code("yab://join/k7qm-4xtd"))
        assertNull(Joining.code("https://site.test/"))
    }

    @Test fun orderKeysMatchFixturesAndStayBetweenNeighbors() {
        for (element in vectors().getValue("order").jsonArray) {
            val fixture = element.jsonObject
            assertEquals(fixture.getValue("key").jsonPrimitive.content, Order.between(
                fixture["after"]?.jsonPrimitive?.contentOrNull, fixture["before"]?.jsonPrimitive?.contentOrNull))
        }
        val keys = Order.spread(1000)
        assertEquals(keys.sorted(), keys); assertEquals(1000, keys.distinct().size); assertTrue(keys.all(Order::valid))
        for (pair in keys.zipWithNext()) assertTrue(Order.between(pair.first, pair.second).let { it > pair.first && it < pair.second })
        val previous = listOf("a", "b", "c").zip(Order.spread(3)).toMap()
        val assigned = Order.assign(listOf("c", "a", "b"), previous)
        assertEquals(previous["a"], assigned["a"]); assertEquals(previous["b"], assigned["b"])
        assertTrue(assigned["c"]!! < assigned["a"]!!)
    }
}
