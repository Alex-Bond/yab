package dev.yab.agent

/** Presentation only. The original request/detail and their transport digests are never rewritten. */
internal data class ApprovalMailConsent(val question: String, val context: String, val first: String?,
    val opens: Boolean, val lifetime: String?, val terms: String?)

internal class ApprovalContent(val request: ApprovalRequest) {
    val mails = request.mails.ifEmpty { if (request.payment == null) legacyMails(request.lines) else emptyList() }
    val legacyBatch = request.mails.isEmpty() && mails.isNotEmpty()
    val kind = if (legacyBatch) ApprovalKind.MAIL_BATCH else request.kind
    val verb = if (legacyBatch) request.sourceVerb ?: "Send All ${mails.size}" else request.verb
    val lines = if (legacyBatch) request.lines.filterNot { it.startsWith("1. To ") } else request.lines
    val consent: ApprovalMailConsent? = if (kind == ApprovalKind.MAIL_SEARCH) {
        val said = request.text.orEmpty().split('\n')
        val first = said.first().trim().takeIf(String::isNotEmpty)
        val opens = first?.startsWith("Opens") == true
        var quoted = false
        val words = first?.let { line ->
            val start = line.indexOf('“'); val end = line.lastIndexOf('”')
            if (start >= 0 && end > start + 1) { quoted = true; line.substring(start + 1, end) } else line
        }
        val firstOpens = opens && quoted
        val terms = said.drop(1).joinToString("\n").trim().takeIf(String::isNotEmpty)
        val chat = request.place?.startsWith("chat:") == true
        val title = request.lines.firstOrNull()?.takeUnless { it == "once for this chat" }
        ApprovalMailConsent("Let ${request.asker} ${if (opens) "read" else "search"} your mail?",
            if (chat) title?.let { "In “$it”" } ?: "In this chat" else "On your Mac", words, firstOpens,
            if (words != null) "And any ${if (firstOpens) "mail" else "search"} after it, until this chat ends."
            else if (terms == null) "Every search in this chat, until it ends." else null, terms)
    } else null

    companion object {
        /** The same bounded older-Mac batch format used by Phone ApprovalContent.batch. */
        fun legacyMails(lines: List<String>): List<ApprovalMail> {
            if (lines.size > 20 || lines.any { it.toByteArray().size > 2000 }) return emptyList()
            val text = lines.firstOrNull { it.startsWith("1. To ") } ?: return emptyList()
            val result = mutableListOf<ApprovalMail>()
            var header: String? = null
            val body = mutableListOf<String>()
            fun close() {
                val head = header ?: return
                var to = emptyList<String>(); var cc = emptyList<String>(); var bcc = emptyList<String>(); var subject = ""
                for (part in head.split(" · ")) {
                    fun people(prefix: String) = part.removePrefix("$prefix ").split(',').map(String::trim)
                    when {
                        part.startsWith("To ") -> to = people("To")
                        part.startsWith("Cc ") -> cc = people("Cc")
                        part.startsWith("Bcc ") -> bcc = people("Bcc")
                        subject.isEmpty() && !part.startsWith("Files ") && !part.startsWith("Sends ") -> subject = part
                    }
                }
                result += ApprovalMail("", to, subject, body.joinToString("\n").trim(), cc, bcc)
            }
            for (line in text.split('\n')) {
                val number = result.size + if (header == null) 1 else 2
                val prefix = "$number. To "
                if (line.startsWith(prefix)) {
                    close(); header = line.substring(prefix.length - 3); body.clear()
                } else body += line
            }
            close()
            if (result.size !in 2..20 || result.any { it.to.isEmpty() || it.to.any(String::isBlank) }) return emptyList()
            val names = lines.firstOrNull { it.startsWith("To ") }?.removePrefix("To ")?.split("; ")
            if (names != null && names.size == result.size) for ((index, name) in names.withIndex()) {
                if (name.isNotEmpty() && '@' !in name) result[index] = result[index].copy(
                    to = listOf("$name · ${result[index].to.first()}") + result[index].to.drop(1))
            }
            if (text.length >= 600) result[result.lastIndex] = result.last().copy(body = result.last().body + "…")
            return result
        }

        fun order(requests: Collection<ApprovalRequest>): List<ApprovalRequest> = requests.sortedWith(
            compareBy<ApprovalRequest> { it.sourceIssuedAt?.takeIf(Double::isFinite) ?: it.issuedAt?.div(1000.0) ?: Double.MAX_VALUE }.thenBy { it.id })
    }
}

/** Only picks still permitted by the fresh payment facts may seed a retry. */
internal fun ApprovalPicks.forRetry(payment: ApprovalPayment): ApprovalPicks = ApprovalPicks(
    card = card?.takeIf { payment.takesCard && payment.cards.any { card -> card.id == it } }
        ?: payment.card?.takeIf { payment.takesCard },
    place = place?.takeIf { payment.takesPlace && payment.places.any { place -> place.id == it } }
        ?: payment.place?.takeIf { payment.takesPlace },
    newCard = newCard?.takeIf { payment.takesCard && runCatching { ApprovalPicks(newCard = it).validate(payment) }.isSuccess },
    newPlace = newPlace?.takeIf { payment.takesPlace && runCatching { ApprovalPicks(newPlace = it).validate(payment) }.isSuccess },
).let { if (it.newCard != null) it.copy(card = null) else it }.let { if (it.newPlace != null) it.copy(place = null) else it }
