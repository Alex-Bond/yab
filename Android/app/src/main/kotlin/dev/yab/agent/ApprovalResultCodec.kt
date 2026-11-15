package dev.yab.agent

import dev.yab.core.sync.Record
import kotlinx.serialization.json.*

/** Result has no independent account fields on wire; only a retained answered request supplies its owner. */
object ApprovalResultCodec {
    fun read(record: Record, request: ApprovalRequest): ApprovalResult? = runCatching {
        require(record.collection == "assistantresult" && record.schema == 1 && record.alive() && record.fields.keys == setOf("body") && record.stamps["body"]?.device == request.mac && record.id.equals(request.id, true))
        val text = (record["body"] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: error("Missing result")
        require(text.toByteArray().size <= 4000)
        val body = Json.parseToJsonElement(text).jsonObject
        fun string(key: String): String? = body[key]?.takeUnless { it == JsonNull }?.let { value -> require(value is JsonPrimitive && value.isString); value.content }
        require(string("id").equals(request.id, true))
        val words = string("words"); val order = string("order")
        require((words?.codePointCount(0, words.length) ?: 0) <= 200 && (order?.codePointCount(0, order.length) ?: 0) <= 80)
        val date = body["at"] as? JsonPrimitive ?: error("Missing result date")
        require(!date.isString && date.doubleOrNull?.isFinite() == true)
        ApprovalResult(request.id, request.account, request.mac, request.requestDigest ?: error("Missing answered facts"),
            ApprovalResultPhase.valueOf(string("phase") ?: error("Missing phase")), words, order, date.double)
    }.getOrNull()
}
