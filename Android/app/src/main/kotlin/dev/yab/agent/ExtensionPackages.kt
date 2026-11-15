package dev.yab.agent

import java.io.ByteArrayInputStream
import java.io.InputStream
import java.util.zip.ZipInputStream
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/** Preflight only. GeckoView, not this parser, establishes an XPI's signature and installability. */
object ExtensionPackages {
    enum class Format { MOZILLA_XPI_CANDIDATE, CHROME_CRX, UNSUPPORTED }
    data class Inspection(val format: Format, val name: String? = null, val version: String? = null, val reason: String)
    fun inspect(bytes: ByteArray): Inspection {
        if (bytes.size >= 4 && bytes.copyOfRange(0, 4).contentEquals(byteArrayOf(67, 114, 50, 52))) return Inspection(
            Format.CHROME_CRX, reason = "Chrome Web Store CRX packages require a Chromium extension runtime. GeckoView installs Mozilla-signed XPI packages."
        )
        if (bytes.size < 4 || bytes[0] != 80.toByte() || bytes[1] != 75.toByte()) return Inspection(Format.UNSUPPORTED, reason = "Choose a Mozilla-signed .xpi extension")
        return try {
            ZipInputStream(ByteArrayInputStream(bytes)).use { zip ->
                var entries = 0
                var decoded = 0L
                while (true) {
                    val entry = zip.nextEntry ?: break
                    require(++entries <= 5000) { "Too many package entries" }
                    require(!entry.name.startsWith("/") && entry.name.split('/').none { it == ".." }) { "Invalid package path" }
                    if (entry.name == "manifest.json") {
                        val manifest = Json.parseToJsonElement(zip.readBounded(512 * 1024).toString(Charsets.UTF_8)).jsonObject
                        return Inspection(Format.MOZILLA_XPI_CANDIDATE, manifest["name"]?.jsonPrimitive?.content, manifest["version"]?.jsonPrimitive?.content,
                            "The browser will validate the Mozilla signature and requested permissions before installation.")
                    }
                    val buffer = ByteArray(8192)
                    while (true) {
                        val count = zip.read(buffer)
                        if (count == -1) break
                        decoded += count
                        require(decoded <= 64L * 1024 * 1024) { "Expanded package is too large" }
                    }
                    zip.closeEntry()
                }
                Inspection(Format.UNSUPPORTED, reason = "The extension has no manifest.json")
            }
        } catch (_: Exception) { Inspection(Format.UNSUPPORTED, reason = "The extension package could not be read safely") }
    }
    fun InputStream.readBounded(limit: Int): ByteArray {
        val output = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (true) {
            val read = read(buffer)
            if (read == -1) return output.toByteArray()
            require(output.size().toLong() + read <= limit) { "The package is too large" }
            output.write(buffer, 0, read)
        }
    }
}
