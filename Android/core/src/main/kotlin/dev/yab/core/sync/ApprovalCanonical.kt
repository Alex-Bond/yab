package dev.yab.core.sync

import kotlinx.serialization.json.*
import java.math.BigDecimal
import java.security.MessageDigest

/** The Codable facts covered by the existing Swift approval digests.
 * Unknown properties and optional nulls must disappear, including inside a detail.
 * Numeric tokens from the Swift canonical body are retained rather than converted
 * through Double.toString(), which uses a different exponent spelling on the JVM.
 */
object ApprovalCanonical {
    private enum class Type { STRING, NUMBER, INT, BOOL, PERSON, FILE, MAIL, CARD, PLACE, PAY, STRINGS, PEOPLE, FILES, MAILS, CARDS, PLACES }
    private data class Field(val type: Type, val optional: Boolean = false)
    private fun field(type: Type) = Field(type)
    private fun optional(type: Type) = Field(type, true)
    private val request = mapOf("id" to field(Type.STRING), "account" to field(Type.STRING), "mac" to field(Type.STRING),
        "assistant" to field(Type.STRING), "session" to field(Type.STRING), "tab" to field(Type.STRING), "permit" to field(Type.STRING),
        "title" to field(Type.STRING), "lines" to field(Type.STRINGS), "issued" to field(Type.NUMBER), "expires" to field(Type.NUMBER), "choices" to optional(Type.STRINGS))
    private val person = mapOf("name" to field(Type.STRING), "address" to optional(Type.STRING))
    private val file = mapOf("id" to field(Type.STRING), "name" to field(Type.STRING), "bytes" to optional(Type.INT), "kind" to field(Type.STRING),
        "pages" to optional(Type.INT), "width" to optional(Type.INT), "height" to optional(Type.INT), "previews" to field(Type.INT))
    private val mail = mapOf("id" to field(Type.STRING), "from" to optional(Type.PERSON), "to" to field(Type.PEOPLE), "cc" to field(Type.PEOPLE),
        "bcc" to optional(Type.PEOPLE), "subject" to field(Type.STRING), "body" to field(Type.STRING), "files" to field(Type.FILES), "date" to optional(Type.NUMBER))
    private val card = mapOf("id" to field(Type.STRING), "brand" to field(Type.STRING), "last4" to field(Type.STRING), "name" to field(Type.STRING))
    private val place = mapOf("id" to field(Type.STRING), "line" to field(Type.STRING), "who" to field(Type.STRING))
    private val pay = mapOf("site" to field(Type.STRING), "item" to field(Type.STRING), "amount" to field(Type.STRING), "delivery" to field(Type.STRING),
        "cards" to field(Type.CARDS), "places" to field(Type.PLACES), "card" to optional(Type.STRING), "place" to optional(Type.STRING),
        "takesCard" to field(Type.BOOL), "takesPlace" to field(Type.BOOL))
    private val detail = mapOf("id" to field(Type.STRING), "verb" to optional(Type.STRING), "mails" to optional(Type.MAILS), "files" to optional(Type.FILES),
        "pay" to optional(Type.PAY), "text" to optional(Type.STRING), "person" to optional(Type.PERSON))

    fun requestBody(body: JsonObject): String = objectBody(body, request)
    fun detailBody(body: JsonObject): String = objectBody(body, detail)
    fun requestDigest(body: JsonObject): String = digest("yab assistant approval v1\n" + requestBody(body))
    fun detailDigest(body: JsonObject): String = digest("yab assistant detail v1\n" + detailBody(body))
    private fun digest(value: String): String = MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it.toInt() and 255) }
    private fun objectBody(body: JsonObject, fields: Map<String, Field>): String = fields.toSortedMap().mapNotNull { (name, field) ->
        val value = body[name]
        if (field.optional && (value == null || value == JsonNull)) null
        else { require(value != null && value != JsonNull) { "Missing approval field $name" }; JsonPrimitive(name).toString() + ":" + valueBody(value, field.type) }
    }.joinToString(",", "{", "}")
    private fun valueBody(value: JsonElement, type: Type): String = when (type) {
        Type.STRING -> { require(value is JsonPrimitive && value.isString); value.toString() }
        Type.BOOL -> { require(value is JsonPrimitive && !value.isString && value.booleanOrNull != null); value.toString() }
        Type.NUMBER -> {
            require(value is JsonPrimitive && !value.isString && value.doubleOrNull?.isFinite() == true)
            // Codable omits the redundant fractional zero on an integral Double.
            value.content.replace(Regex("\\.0+(?=([eE]|$))"), "")
        }
        Type.INT -> {
            require(value is JsonPrimitive && !value.isString)
            BigDecimal(value.content).toBigIntegerExact().longValueExact().toString()
        }
        Type.PERSON -> objectBody(value.jsonObject, person)
        Type.FILE -> objectBody(value.jsonObject, file)
        Type.MAIL -> objectBody(value.jsonObject, mail)
        Type.CARD -> objectBody(value.jsonObject, card)
        Type.PLACE -> objectBody(value.jsonObject, place)
        Type.PAY -> objectBody(value.jsonObject, pay)
        else -> {
            val elementType = when (type) { Type.STRINGS -> Type.STRING; Type.PEOPLE -> Type.PERSON; Type.FILES -> Type.FILE; Type.MAILS -> Type.MAIL; Type.CARDS -> Type.CARD; Type.PLACES -> Type.PLACE; else -> error("Invalid approval array") }
            value.jsonArray.joinToString(",", "[", "]") { valueBody(it, elementType) }
        }
    }
}
