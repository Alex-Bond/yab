package dev.yab.notifications

import org.junit.Assert.*
import org.junit.Test

class NotificationPolicyTest {
    @Test fun pushPayloadCannotSupplyItsOwnReadableNotificationText() {
        val envelope = PushEnvelope.read(mapOf("v" to "1", "kind" to "approval", "approval" to "id", "title" to "Untrusted amount", "summary" to "Untrusted recipient"))!!
        val words = NotificationPolicy.words(envelope, null, null, null)!!
        assertEquals("Yab", words.title); assertEquals("Needs your answer", words.body); assertFalse(words.validated)
        assertEquals("Real request", NotificationPolicy.words(envelope, "id", "Real request", "Locally validated")!!.title)
        assertFalse(NotificationPolicy.words(envelope, "another-request", "Wrong request", "Wrong account")!!.validated)
    }
    @Test fun withdrawalAndSyncNeverRingAndMalformedRoutingIsRefused() {
        assertNull(NotificationPolicy.words(PushEnvelope.read(mapOf("v" to "1", "kind" to "withdraw", "approval" to "id"))!!, "id", "Title", "Body"))
        assertNull(PushEnvelope.read(mapOf("v" to "1", "kind" to "approval", "approval" to "../../approve")))
        assertNull(PushEnvelope.read(mapOf("v" to "99", "kind" to "approval", "approval" to "id")))
    }
    @Test fun deduplicationCannotCrossAccountAndExpiresAfterTwoDays() {
        val first = NotificationPolicy.ledgerKey("account-a", "id")
        val second = NotificationPolicy.ledgerKey("account-b", "id")
        val seen = mapOf(first to 1000L)
        assertTrue(NotificationPolicy.alreadyAnnounced(first, seen, 2000))
        assertFalse(NotificationPolicy.alreadyAnnounced(second, seen, 2000))
        assertFalse(NotificationPolicy.alreadyAnnounced(first, seen, 172_802_000))
    }
}
