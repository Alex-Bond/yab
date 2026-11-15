package dev.yab.core.sync

import dev.yab.core.crypto.Seal
import kotlinx.serialization.json.*
import java.util.UUID

/** SyncWallet-compatible inner encryption: PAN/CVC/address never enter a journal in plaintext. */
object Wallet {
    fun brand(digits: String): String {
        fun starts(low: Int, high: Int, length: Int) = digits.take(length).takeIf { it.length == length }?.toIntOrNull()?.let { it in low..high } == true
        return when {
            digits.startsWith("4") -> "Visa"
            starts(51, 55, 2) || starts(2221, 2720, 4) -> "Mastercard"
            digits.startsWith("34") || digits.startsWith("37") -> "American Express"
            digits.startsWith("6011") || digits.startsWith("65") || starts(644, 649, 3) -> "Discover"
            starts(3528, 3589, 4) -> "JCB"
            digits.startsWith("62") -> "UnionPay"
            digits.startsWith("36") || starts(300, 305, 3) || digits.startsWith("38") -> "Diners Club"
            digits.startsWith("50") || starts(56, 69, 2) -> "Maestro"
            else -> "Card"
        }
    }
    fun luhn(digits: String): Boolean = digits.length in 12..19 && digits.all { it in '0'..'9' } &&
        digits.reversed().mapIndexed { i, c -> val value = c - '0'; if (i % 2 == 1) (value * 2).let { if (it > 9) it - 9 else it } else value }.sum() % 10 == 0
    fun card(id: String, number: String, csc: String, name: String, month: Int, year: Int, seal: Seal): JsonObject {
        val digits = number.filter { it in '0'..'9' }; val code = csc.filter { it in '0'..'9' }
        require(luhn(digits) && month in 1..12 && year >= 2000 && UUID.fromString(id).toString().equals(id, true))
        val secret = buildJsonObject { if (code.length in 3..4) put("csc", code); put("number", digits) }.toString().toByteArray()
        return try { buildJsonObject {
            put("secret", seal.hide(secret, RecordKey("card", id)))
            put("facts", buildJsonObject {
                put("last4", digits.takeLast(4)); put("brand", brand(digits)); put("name", name); put("month", month); put("year", year)
                put("nickname", ""); put("source", "Yab for Android"); put("usedOn", ""); put("issuer", ""); put("level", ""); put("billing", ""); put("code", code.length in 3..4)
            })
        } } finally { secret.fill(0) }
    }
    fun address(id: String, name: String, street: String, city: String, postal: String, seal: Seal): JsonObject {
        require(UUID.fromString(id).toString().equals(id, true) && street.isNotBlank() && city.isNotBlank())
        val secret = buildJsonObject {
            put("id", id); put("name", name); put("organization", ""); put("street", street); put("city", city); put("region", "")
            put("postal", postal); put("country", ""); put("phone", ""); put("email", ""); put("source", "Yab for Android")
        }.toString().toByteArray()
        return try { buildJsonObject { put("secret", seal.hide(secret, RecordKey("address", id))) } } finally { secret.fill(0) }
    }
}
