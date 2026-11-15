package dev.yab.nativefeatures

import org.junit.Assert.*
import org.junit.Test

class CaptureLeaseTest {
    @Test fun retiredSensorCallbackCannotBorrowAReplacementOwnerOrSameIdReopen() {
        val lease = CaptureLease()
        val first = lease.begin("private-tab")
        assertTrue(lease.current(first, "private-tab"))
        assertFalse(lease.current(first, "public-tab"))
        lease.retire()
        assertFalse(lease.current(first, "private-tab"))
        val reopened = lease.begin("private-tab")
        assertTrue(lease.current(reopened, "private-tab"))
        assertFalse(lease.current(first, "private-tab"))
    }
    @Test fun privateVoiceNeverUsesAnOrdinaryRemoteCapableRecognizer() {
        assertFalse(VoicePrivacy.canStart(true, 29, false))
        assertFalse(VoicePrivacy.canStart(true, 31, false))
        assertTrue(VoicePrivacy.canStart(true, 31, true))
        assertTrue(VoicePrivacy.canStart(false, 29, false))
    }
}
