package dev.yab.sync

import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import kotlinx.serialization.json.*

/** A local preference within one account's no-backup directory, never a shared setting. */
internal class MacRouteStore(private val file: File, private val account: String) {
    fun read(): String? = runCatching {
        if (!file.exists()) return null
        require(file.length() <= 4096)
        val value = Json.parseToJsonElement(file.readText()).jsonObject
        require(value["account"]?.jsonPrimitive?.content == account)
        (value["chosen"] as? JsonPrimitive)?.takeIf { it.isString }?.content?.takeIf { it.isNotBlank() }
    }.getOrNull()
    fun save(chosen: String?) {
        if (chosen == null) { check(!file.exists() || file.delete()) { "The Mac choice could not be cleared" }; return }
        val parent = file.absoluteFile.parentFile; check(parent.isDirectory || parent.mkdirs())
        val temporary = File.createTempFile(".mac-route-", ".tmp", parent)
        try {
            val body = buildJsonObject { put("account", account); put("chosen", chosen) }.toString().toByteArray()
            FileOutputStream(temporary).use { it.write(body); it.fd.sync() }
            Files.move(temporary.toPath(), file.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        } finally { temporary.delete() }
    }
}
