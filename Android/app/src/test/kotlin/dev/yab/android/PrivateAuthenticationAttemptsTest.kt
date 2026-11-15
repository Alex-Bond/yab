package dev.yab.android

import org.junit.Assert.*
import org.junit.Test

class PrivateAuthenticationAttemptsTest {
    private val owner = PrivateAuthenticationAttempts.Owner("account", "phone", 7, false)

    @Test fun actualResultMayBeDeliveredOnlyOnceEvenWhenItWasADenial() {
        val authority = PrivateAuthenticationAttempts()
        val attempt = requireNotNull(authority.begin(owner))
        assertTrue(authority.consume(attempt, owner))
        assertFalse(authority.consume(attempt, owner))
    }

    @Test fun supersedingPromptCannotBeConsumedByThePreviousCallback() {
        val authority = PrivateAuthenticationAttempts()
        val first = requireNotNull(authority.begin(owner))
        val second = requireNotNull(authority.begin(owner))
        assertFalse(authority.consume(first, owner))
        assertTrue(authority.consume(second, owner))
    }

    @Test fun BackgroundAndReturnToIdenticalAccountCannotReviveAnOldPrompt() {
        val authority = PrivateAuthenticationAttempts()
        val attempt = requireNotNull(authority.begin(owner))
        authority.invalidate()
        assertFalse(authority.consume(attempt, owner))
        assertTrue(authority.consume(requireNotNull(authority.begin(owner)), owner))
    }

    @Test fun accountDeviceEpochAndRemovalEachRevokeWithoutRetargeting() {
        for (changed in listOf(owner.copy(account = "other"), owner.copy(device = "other"),
            owner.copy(epoch = 9), owner.copy(removed = true))) {
            val authority = PrivateAuthenticationAttempts()
            val attempt = requireNotNull(authority.begin(owner))
            assertFalse(authority.consume(attempt, changed))
            assertFalse(authority.consume(attempt, owner))
        }
    }

    @Test fun removedAccountCannotStartAuthenticationAndRevokesTheOldAttempt() {
        val authority = PrivateAuthenticationAttempts()
        val attempt = requireNotNull(authority.begin(owner))
        assertNull(authority.begin(owner.copy(removed = true)))
        assertFalse(authority.consume(attempt, owner))
        val local = PrivateAuthenticationAttempts.Owner(null, null, 0, false)
        assertTrue(authority.consume(requireNotNull(authority.begin(local)), local))
    }
}
