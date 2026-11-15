package dev.yab.core.crypto

import java.nio.ByteBuffer
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Locale
import org.bouncycastle.math.ec.rfc7748.X25519

/** Pairing v2 from Sources/SyncKit/Seal.swift. Never accepts an untagged public key. */
class Joining(val code: String = makeCode(), privateKey: ByteArray? = null) {
    private val privateKey = (privateKey ?: Crypto.random(32)).copyOf().also { require(it.size == 32) }
    private val stretch = stretch(code)
    val publicKey: ByteArray get() = ByteArray(32).also { X25519.scalarMultBase(privateKey, 0, it, 0) }
    val posted: String get() = Crypto.b64(publicKey + Crypto.hmac(stretch.mac, "yab sync pub v2".toByteArray() + publicKey))
    val box: String get() = stretch.box
    val check: String get() = check(code, publicKey)
    fun open(envelope: ByteArray): Seal {
        require(envelope.size == 92) { "Invalid pairing envelope" }
        val shared = shared(privateKey, envelope.copyOf(32))
        val key = Crypto.hkdf(shared, "yab sync join v2", salt = stretch.salt)
        shared.fill(0)
        return try { Seal(Crypto.decrypt(key, envelope.copyOfRange(32, envelope.size))) } finally { key.fill(0) }
    }
    override fun toString(): String = "Joining([redacted])"
    companion object {
        private const val alphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
        private val random = SecureRandom()
        private data class Stretch(val box: String, val mac: ByteArray, val salt: ByteArray)
        private fun normalize(code: String) = code.uppercase(Locale.ROOT).filter { it.isLetterOrDigit() }
        fun makeCode(): String = (0 until 8).map { alphabet[random.nextInt(alphabet.length)] }.joinToString("").chunked(4).joinToString("-")
        fun code(scanned: String): String? {
            val text = scanned.trim()
            val body = if (text.startsWith("yab:", ignoreCase = true)) {
                val uri = runCatching { java.net.URI(text) }.getOrNull() ?: return null
                if (!uri.host.equals("join", ignoreCase = true) || !uri.scheme.equals("yab", ignoreCase = true)) return null
                uri.path
            } else { if (text.any { it == ':' || it == '/' || it == '.' }) return null; text }
            val normal = normalize(body)
            return normal.takeIf { it.length == 8 && it.all { c -> c in alphabet } }?.chunked(4)?.joinToString("-")
        }
        fun link(code: String): String = "yab://join/" + (Joining.code(code) ?: code)
        fun box(code: String): String = stretch(code).box
        fun verified(posted: String?, code: String): ByteArray? {
            val data = posted?.let { runCatching { Crypto.unbase64(it) }.getOrNull() } ?: return null
            if (data.size != 64) return null
            val key = data.copyOf(32)
            val expected = Crypto.hmac(stretch(code).mac, "yab sync pub v2".toByteArray() + key)
            return key.takeIf { MessageDigest.isEqual(expected, data.copyOfRange(32, 64)) }
        }
        fun check(code: String, publicKey: ByteArray): String {
            require(publicKey.size == 32)
            val bytes = Crypto.sha256("yab sync check v1\u0000${normalize(code)}\u0000".toByteArray(Charsets.UTF_8) + publicKey)
            val number = ByteBuffer.wrap(bytes).int.toLong() and 0xffff_ffffL
            return "%04d".format(Locale.ROOT, number % 10_000)
        }
        fun seal(seal: Seal, to: ByteArray, code: String): ByteArray = envelope(seal.raw(), to, code, Crypto.random(32), Crypto.random(12))
        /** Fixed inputs are used only by contract-vector tests. Public calls always use fresh randomness. */
        internal fun envelope(root: ByteArray, to: ByteArray, code: String, privateKey: ByteArray, nonce: ByteArray): ByteArray {
            require(root.size == 32 && privateKey.size == 32)
            val public = ByteArray(32).also { X25519.scalarMultBase(privateKey, 0, it, 0) }
            val shared = shared(privateKey, to)
            val key = Crypto.hkdf(shared, "yab sync join v2", salt = stretch(code).salt)
            shared.fill(0)
            return try { public + Crypto.encrypt(key, root, nonce = nonce) } finally { key.fill(0) }
        }
        private fun shared(privateKey: ByteArray, publicKey: ByteArray): ByteArray {
            require(publicKey.size == 32)
            return ByteArray(32).also { require(X25519.calculateAgreement(privateKey, 0, publicKey, 0, it, 0)) { "Invalid X25519 public key" } }
        }
        private fun stretch(code: String): Stretch {
            val normal = normalize(code)
            // Compute only once per Joining; callers deciding a public key may cache their own Joining.
            val master = pbkdf2(normal.toByteArray(Charsets.UTF_8), "yab sync pairing v2".toByteArray(), 300_000)
            return try { Stretch(Crypto.hex(Crypto.hkdf(master, "box")), Crypto.hkdf(master, "pub"), Crypto.hkdf(master, "envelope")) }
                finally { master.fill(0) }
        }
        private fun pbkdf2(password: ByteArray, salt: ByteArray, rounds: Int): ByteArray {
            val mac = javax.crypto.Mac.getInstance("HmacSHA256").apply { init(javax.crypto.spec.SecretKeySpec(password, "HmacSHA256")) }
            var previous = mac.doFinal(salt + byteArrayOf(0, 0, 0, 1))
            val output = previous.copyOf()
            repeat(rounds - 1) { previous = mac.doFinal(previous); for (i in output.indices) output[i] = (output[i].toInt() xor previous[i].toInt()).toByte() }
            previous.fill(0)
            return output
        }
    }
}
