package dev.yab.agent

import org.junit.Assert.*
import org.junit.Test

class ApprovalContentParityTest {
    private val request = ApprovalRequest("question", "account", "mac", 1, 90_000, "Claude", "Mail?", "Summary",
        kind = ApprovalKind.MAIL_SEARCH, permit = "mail.read", place = "chat:owned", lines = listOf("Trip planning", "once for this chat"))

    @Test fun mailConsentRetainsFirstOperationAndWholeChatScopeWithoutChangingApprovedFacts() {
        val read = request.copy(text = "Opens “Train tickets”\nOnly the linked account.")
        val before = read.fingerprint()
        val content = checkNotNull(ApprovalContent(read).consent)
        assertEquals("Let Claude read your mail?", content.question)
        assertEquals("In “Trip planning”", content.context)
        assertEquals("Train tickets", content.first)
        assertTrue(content.opens)
        assertEquals("And any mail after it, until this chat ends.", content.lifetime)
        assertEquals("Only the linked account.", content.terms)
        assertEquals(before, read.fingerprint())
        val search = checkNotNull(ApprovalContent(request.copy(text = "Looks for “Yab 0.32”")).consent)
        assertFalse(search.opens)
        assertEquals("Yab 0.32", search.first)
        assertEquals("And any search after it, until this chat ends.", search.lifetime)
        val unquoted = checkNotNull(ApprovalContent(request.copy(text = "Opens unquoted mail")).consent)
        assertEquals("Let Claude read your mail?", unquoted.question)
        assertFalse(unquoted.opens)
        assertEquals("And any search after it, until this chat ends.", unquoted.lifetime)
        val legacy = checkNotNull(ApprovalContent(request.copy(text = null)).consent)
        assertNull(legacy.first)
        assertEquals("Every search in this chat, until it ends.", legacy.lifetime)
    }

    @Test fun olderMacBatchIsAReadOnlyProjectionWithEveryRecipientAndBodyKeptSeparate() {
        val lines = listOf("mail.example", "To Anna; bob@example.test", "1. To anna@example.test · Cc copy@example.test · Subject one\nHello Anna\nFirst body\n2. To bob@example.test · Bcc blind@example.test · Subject two\nSecond body")
        val original = request.copy(kind = ApprovalKind.LINES, permit = "mail.send", lines = lines, text = null, mails = emptyList())
        val fingerprint = original.fingerprint()
        val projected = ApprovalContent(original)
        assertEquals(ApprovalKind.MAIL_BATCH, projected.kind)
        assertTrue(projected.legacyBatch)
        assertEquals(2, projected.mails.size)
        assertEquals("Send All 2", projected.verb)
        assertEquals("Send both drafts", ApprovalContent(original.copy(sourceVerb = "Send both drafts")).verb)
        assertEquals(listOf("Anna · anna@example.test"), projected.mails[0].to)
        assertEquals(listOf("copy@example.test"), projected.mails[0].cc)
        assertEquals("Subject one", projected.mails[0].subject)
        assertEquals("Hello Anna\nFirst body", projected.mails[0].body)
        assertEquals(listOf("blind@example.test"), projected.mails[1].bcc)
        assertEquals("Second body", projected.mails[1].body)
        assertTrue(original.mails.isEmpty())
        assertEquals(lines, original.lines)
        assertEquals(fingerprint, original.fingerprint())
        assertTrue(ApprovalContent.legacyMails(listOf("1. To a@example.test\nOnly one")).isEmpty())
        assertTrue(ApprovalContent.legacyMails(listOf("1. To a@example.test\n3. To other@example.test")).isEmpty())
        assertTrue(ApprovalContent.legacyMails(listOf("1. To a@example.test\n" + "x".repeat(2001))).isEmpty())
        val typed = original.copy(mails = listOf(ApprovalMail("Actual", listOf("To"), "Typed detail", "Full")))
        assertEquals(typed.mails, ApprovalContent(typed).mails)
        assertTrue(ApprovalContent(original.copy(payment = ApprovalPayment("site", "item", "$1"))).mails.isEmpty())
    }

    @Test fun fifoUsesActualIssuedSecondsThenIdentityInsteadOfExpiryOrInputOrder() {
        val older = request.copy(id = "older", expiresAt = 86_400_000, sourceIssuedAt = 10.0001)
        val newer = request.copy(id = "newer", expiresAt = 900_000, sourceIssuedAt = 10.0002)
        val firstTie = request.copy(id = "a", sourceIssuedAt = 11.0)
        val lastTie = request.copy(id = "z", sourceIssuedAt = 11.0)
        assertEquals(listOf(older, newer, firstTie, lastTie), ApprovalContent.order(listOf(lastTie, newer, firstTie, older)))
        val malformed = request.copy(id = "malformed", issuedAt = null, sourceIssuedAt = Double.NaN)
        assertEquals(malformed, ApprovalContent.order(listOf(malformed, older)).last())
    }
}
