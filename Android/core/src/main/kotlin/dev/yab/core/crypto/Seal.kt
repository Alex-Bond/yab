package dev.yab.core.crypto

import dev.yab.core.sync.Record
import dev.yab.core.sync.RecordKey
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

internal object Crypto {
    private val random = SecureRandom()
    fun random(size: Int): ByteArray = ByteArray(size).also(random::nextBytes)
    fun sha256(data: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(data)
    fun hmac(key: ByteArray, data: ByteArray): ByteArray = Mac.getInstance("HmacSHA256").run {
        init(SecretKeySpec(key, "HmacSHA256")); doFinal(data)
    }
    fun hkdf(key: ByteArray, info: String, size: Int = 32, salt: ByteArray = ByteArray(32)): ByteArray {
        require(size in 1..8160)
        val prk = hmac(salt, key)
        var previous = byteArrayOf(); var output = byteArrayOf(); var block = 1
        while (output.size < size) { previous = hmac(prk, previous + info.toByteArray(Charsets.UTF_8) + block.toByte()); output += previous; block++ }
        prk.fill(0)
        return output.copyOf(size)
    }
    fun encrypt(key: ByteArray, plaintext: ByteArray, aad: ByteArray = byteArrayOf(), nonce: ByteArray = random(12)): ByteArray {
        require(nonce.size == 12)
        return Cipher.getInstance("AES/GCM/NoPadding").run {
            init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce)); updateAAD(aad)
            nonce + doFinal(plaintext)
        }
    }
    fun decrypt(key: ByteArray, box: ByteArray, aad: ByteArray = byteArrayOf()): ByteArray {
        require(box.size >= 28) { "Invalid sealed box" }
        return Cipher.getInstance("AES/GCM/NoPadding").run {
            init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, box.copyOfRange(0, 12))); updateAAD(aad)
            doFinal(box, 12, box.size - 12)
        }
    }
    fun b64(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)
    fun unbase64(text: String): ByteArray = Base64.getDecoder().decode(text)
    fun url64(bytes: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
    fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it.toInt() and 255) }
}

/** Root key material stays local. Only derived authentication secrets reach the server. */
class Seal(raw: ByteArray) {
    private val key = raw.copyOf().also { require(it.size == 32) }
    private val records = Crypto.hkdf(key, "yab sync records v1")
    private val names = Crypto.hkdf(key, "yab sync names v1")
    val account: String get() = Crypto.url64(Crypto.hkdf(key, "yab sync account v1", 16))
    val secret: String get() = Crypto.url64(Crypto.hkdf(key, "yab sync auth v1"))
    fun raw(): ByteArray = key.copyOf()
    fun name(record: RecordKey): String = Crypto.url64(Crypto.hmac(names, "${record.collection}\u0000${record.id}".toByteArray(Charsets.UTF_8)))
    fun seal(record: Record): ByteArray = Crypto.encrypt(records, record.toJson().toString().toByteArray(Charsets.UTF_8), name(record.key).toByteArray(Charsets.UTF_8))
    fun open(box: ByteArray, name: String): Record {
        val record = Record.parse(String(Crypto.decrypt(records, box, name.toByteArray(Charsets.UTF_8)), Charsets.UTF_8))
        require(MessageDigest.isEqual(name(record.key).toByteArray(Charsets.UTF_8), name.toByteArray(Charsets.UTF_8))) { "Invalid record name" }
        return record
    }
    fun hide(plaintext: ByteArray, record: RecordKey): String = Crypto.b64(Crypto.encrypt(Crypto.hkdf(key, "yab sync secrets v1"), plaintext, record.toString().toByteArray(Charsets.UTF_8)))
    fun reveal(text: String, record: RecordKey): ByteArray = Crypto.decrypt(Crypto.hkdf(key, "yab sync secrets v1"), Crypto.unbase64(text), record.toString().toByteArray(Charsets.UTF_8))
    val recovery: String get() = Base32.encode(key + Crypto.sha256(key).copyOf(2)).chunked(4).joinToString("-")
    override fun toString(): String = "Seal([redacted])"
    companion object {
        fun make(): Seal = Seal(Crypto.random(32))
        fun fromRecovery(text: String): Seal? {
            val bytes = Base32.decode(text) ?: return null
            if (bytes.size != 34) return null
            val raw = bytes.copyOf(32)
            if (!MessageDigest.isEqual(Crypto.sha256(raw).copyOf(2), bytes.copyOfRange(32, 34))) return null
            return Seal(raw)
        }
    }
}

private object Base32 {
    const val alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
    fun encode(bytes: ByteArray): String = buildString {
        var buffer = 0; var bits = 0
        for (byte in bytes) {
            buffer = (buffer shl 8) or (byte.toInt() and 255); bits += 8
            while (bits >= 5) { append(alphabet[(buffer ushr (bits - 5)) and 31]); bits -= 5 }
        }
        if (bits > 0) append(alphabet[(buffer shl (5 - bits)) and 31])
    }
    fun decode(text: String): ByteArray? {
        val output = java.io.ByteArrayOutputStream(); var buffer = 0; var bits = 0
        for (letter in text.uppercase(java.util.Locale.ROOT)) {
            if (letter == ' ' || letter == '-' || letter == '\n') continue
            val c = when (letter) { '0' -> 'O'; '1' -> 'I'; '8' -> 'B'; else -> letter }
            val value = alphabet.indexOf(c); if (value < 0) return null
            buffer = (buffer shl 5) or value; bits += 5
            if (bits >= 8) { output.write((buffer ushr (bits - 8)) and 255); bits -= 8 }
            buffer = buffer and ((1 shl bits) - 1)
        }
        return output.toByteArray()
    }
}
