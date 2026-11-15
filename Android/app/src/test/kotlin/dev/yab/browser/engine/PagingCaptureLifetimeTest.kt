package dev.yab.browser.engine

import org.junit.Assert.*
import org.junit.Test

class PagingCaptureLifetimeTest {
    @Test fun fullResolutionAllocationRejectsInvalidOrOverBudgetSurfacesWithoutIntegerOverflow() {
        assertTrue(PagingCaptureLifetime.permits(2048, 2048))
        assertTrue(PagingCaptureLifetime.permits(1080, 2400))
        assertFalse(PagingCaptureLifetime.permits(2048, 2049))
        assertFalse(PagingCaptureLifetime.permits(0, 2400))
        assertFalse(PagingCaptureLifetime.permits(-1, 1))
        assertFalse(PagingCaptureLifetime.permits(Int.MAX_VALUE, Int.MAX_VALUE))
        assertFalse(PagingCaptureLifetime.permits(8193, 1))
    }

    @Test fun aRevokedNativeCaptureCannotReviveAfterAnOwnerReturns() {
        val owner = PagingCaptureLifetime()
        val pending = owner.begin()
        assertTrue(owner.current(pending))
        owner.invalidate()
        assertFalse(owner.current(pending))
        val replacement = owner.begin()
        assertTrue(owner.current(replacement))
        assertFalse(owner.current(pending))
        owner.invalidate()
        assertFalse(owner.current(replacement))
    }

    @Test fun aSecondCaptureSupersedesTheFirstBeforeEitherNativeCallback() {
        val owner = PagingCaptureLifetime()
        val first = owner.begin()
        val second = owner.begin()
        assertFalse(owner.current(first))
        assertTrue(owner.current(second))
    }

    @Test fun cancellingAUiLeaseDoesNotPermitAnotherNativeAllocationUntilTheOldCallbackFinishes() {
        val owner = PagingCaptureLifetime()
        assertTrue(owner.tryBeginNative())
        val first = owner.begin()
        owner.invalidate()
        assertFalse(owner.current(first))
        assertFalse(owner.tryBeginNative())
        owner.nativeFinished()
        assertTrue(owner.tryBeginNative())
    }
}
