package dev.yab.core

import dev.yab.core.sync.ApprovalCanonical
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File

class ApprovalCanonicalTest {
    private fun cases(): JsonArray {
        val resource = javaClass.getResourceAsStream("/approval-vectors-v1.json")
        val contents = resource?.bufferedReader()?.use { it.readText() } ?: generateSequence(File(System.getProperty("user.dir"))) { it.parentFile }
            .map { File(it, "SharedContracts/sync/approval-vectors-v1.json") }.first { it.isFile }.readText()
        return Json.parseToJsonElement(contents).jsonObject.getValue("cases").jsonArray
    }
    @Test fun requestAndDetailBytesMatchActualSwiftCodableDigestVectors() {
        for (element in cases()) {
            val vector = element.jsonObject
            val body = Json.parseToJsonElement(vector.getValue("input").jsonPrimitive.content).jsonObject
            val request = vector.getValue("type").jsonPrimitive.content == "request"
            val name = vector.getValue("name").jsonPrimitive.content
            assertEquals("$name canonical bytes", vector.getValue("canonical").jsonPrimitive.content,
                if (request) ApprovalCanonical.requestBody(body) else ApprovalCanonical.detailBody(body))
            assertEquals("$name SHA-256", vector.getValue("digest").jsonPrimitive.content,
                if (request) ApprovalCanonical.requestDigest(body) else ApprovalCanonical.detailDigest(body))
        }
    }
    @Test fun seenChangesNoFactsButAnyKnownNestedPaymentOrBccChangeInvalidatesYes() {
        val request = Json.parseToJsonElement(cases()[0].jsonObject.getValue("input").jsonPrimitive.content).jsonObject
        val changedSeen = JsonObject(request + ("seen" to buildJsonObject { put("device", "test-mac"); put("at", 1700000020) }))
        assertEquals(ApprovalCanonical.requestDigest(request), ApprovalCanonical.requestDigest(changedSeen))
        val detail = Json.parseToJsonElement(cases()[2].jsonObject.getValue("input").jsonPrimitive.content).jsonObject
        val original = ApprovalCanonical.detailDigest(detail)
        val pay = detail.getValue("pay").jsonObject
        assertNotEquals(original, ApprovalCanonical.detailDigest(JsonObject(detail + ("pay" to JsonObject(pay + ("amount" to JsonPrimitive("$420.10")))))))
        val mails = detail.getValue("mails").jsonArray
        val first = mails.first().jsonObject
        val changedBcc = JsonArray(listOf(JsonObject(first + ("bcc" to buildJsonArray { add(buildJsonObject { put("name", "Attacker"); put("address", "elsewhere@example.test") }) }))))
        assertNotEquals(original, ApprovalCanonical.detailDigest(JsonObject(detail + ("mails" to changedBcc))))
    }
    @Test fun malformedKnownTypesNeverProduceAnApprovalDigest() {
        val request = Json.parseToJsonElement(cases()[0].jsonObject.getValue("input").jsonPrimitive.content).jsonObject
        assertThrows(IllegalArgumentException::class.java) { ApprovalCanonical.requestDigest(JsonObject(request + ("issued" to JsonPrimitive("1700000000")))) }
        val detail = Json.parseToJsonElement(cases()[2].jsonObject.getValue("input").jsonPrimitive.content).jsonObject
        val mail = detail.getValue("mails").jsonArray.first().jsonObject
        val file = mail.getValue("files").jsonArray.first().jsonObject
        val invalidFile = JsonObject(file + ("previews" to JsonPrimitive(1.5)))
        val invalidMail = JsonObject(mail + ("files" to JsonArray(listOf(invalidFile))))
        assertThrows(ArithmeticException::class.java) { ApprovalCanonical.detailDigest(JsonObject(detail + ("mails" to JsonArray(listOf(invalidMail))))) }
    }
}
