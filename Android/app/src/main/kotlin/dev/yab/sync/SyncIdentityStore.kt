package dev.yab.sync

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import dev.yab.core.crypto.Seal
import kotlinx.serialization.json.*
import java.io.File
import java.security.KeyStore
import java.util.Base64
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal data class SyncIdentity(val seal: Seal, val device: String, val token: String?)

/** Root and device credentials are encrypted at rest and excluded from Android backup/transfer. */
internal class SyncIdentityStore(context: Context) {
    private val file = AtomicFile(File(context.noBackupFilesDir, "sync-identity.enc"))
    private val alias = "${context.packageName}.sync.identity.v1"
    private val store: KeyStore get() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    private fun key(create: Boolean): SecretKey {
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        check(create) { "The Sync key is unavailable. Rejoin with your Mac or Recovery Key." }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true).setUserAuthenticationRequired(false).build())
            generateKey()
        }
    }
    @Synchronized fun load(): SyncIdentity? {
        if (!file.baseFile.exists()) return null
        val bytes = file.openRead().use { it.readBytes() }
        check(bytes.size in 28..16_384) { "The saved Sync identity is invalid" }
        val plain = Cipher.getInstance("AES/GCM/NoPadding").run {
            init(Cipher.DECRYPT_MODE, key(false), GCMParameterSpec(128, bytes.copyOf(12)))
            updateAAD(alias.toByteArray()); doFinal(bytes, 12, bytes.size - 12)
        }
        try {
            val json = Json.parseToJsonElement(plain.toString(Charsets.UTF_8)).jsonObject
            require(json.getValue("version").jsonPrimitive.int == 1)
            val device = json.getValue("device").jsonPrimitive.content
            require(UUID.fromString(device).toString() == device)
            return SyncIdentity(Seal(Base64.getDecoder().decode(json.getValue("root").jsonPrimitive.content)), device,
                json["token"]?.jsonPrimitive?.contentOrNull)
        } finally { plain.fill(0) }
    }
    @Synchronized fun save(identity: SyncIdentity) {
        val plain = buildJsonObject {
            put("version", 1); put("root", Base64.getEncoder().encodeToString(identity.seal.raw())); put("device", identity.device)
            identity.token?.let { put("token", it) }
        }.toString().toByteArray()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key(true)); updateAAD(alias.toByteArray()) }
        val bytes = try { cipher.iv + cipher.doFinal(plain) } finally { plain.fill(0) }
        val output = file.startWrite()
        try { output.write(bytes); file.finishWrite(output) } catch (error: Exception) { file.failWrite(output); throw error }
        val restored = load()
        check(restored != null && restored.device == identity.device && restored.seal.raw().contentEquals(identity.seal.raw()) && restored.token == identity.token) { "Sync identity could not be verified" }
    }
    @Synchronized fun forget() { file.delete(); store.deleteEntry(alias) }
}
