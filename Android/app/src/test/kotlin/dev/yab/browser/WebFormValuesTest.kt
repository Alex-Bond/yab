package dev.yab.browser

import dev.yab.browser.model.WebFormValues
import dev.yab.browser.model.WebFormValues.Kind.*
import org.junit.Assert.*
import org.junit.Test

class WebFormValuesTest {
    @Test fun isoWeeksUseWeekYearAndRejectNonexistentWeek53() {
        assertNotNull(WebFormValues.parse(WEEK, "2020-W53"))
        assertNull(WebFormValues.parse(WEEK, "2021-W53"))
        assertTrue(WebFormValues.allowed(WEEK, "2021-W01", "2020-W53", "2021-W02", "1", null))
        assertFalse(WebFormValues.allowed(WEEK, "2020-W52", "2020-W53", "2021-W02", "1", null))
    }
    @Test fun leapDayAndMonthRangeAreCalendarValues() {
        assertNull(WebFormValues.parse(DATE, "2025-02-29"))
        assertNotNull(WebFormValues.parse(DATE, "2024-02-29"))
        assertFalse(WebFormValues.allowed(MONTH, "2026-01", "2025-11", "2025-12", null, null))
        assertTrue(WebFormValues.allowed(MONTH, "2026-01", "2025-11", "2026-03", "2", null))
        assertFalse(WebFormValues.allowed(MONTH, "2025-12", "2025-11", "2026-03", "2", null))
    }
    @Test fun timeWrapsMidnightAndHonorsFractionalSteps() {
        assertTrue(WebFormValues.allowed(TIME, "23:30", "22:00", "06:00", "900", null))
        assertTrue(WebFormValues.allowed(TIME, "03:00", "22:00", "06:00", "900", null))
        assertFalse(WebFormValues.allowed(TIME, "12:00", "22:00", "06:00", "900", null))
        assertTrue(WebFormValues.allowed(TIME, "10:00:00.250", "10:00", null, "0.25", null))
        assertFalse(WebFormValues.allowed(TIME, "10:00:00.100", "10:00", null, "0.25", null))
    }
    @Test fun localDateTimeRejectsTimezoneAndDoesNotShiftAtDstBoundary() {
        assertNull(WebFormValues.parse(DATETIME_LOCAL, "2026-03-29T02:30Z"))
        assertEquals("2026-03-29T02:30", WebFormValues.parse(DATETIME_LOCAL, "2026-03-29T02:30")!!.canonical)
        assertTrue(WebFormValues.allowed(DATETIME_LOCAL, "2026-03-29T02:30", "2026-03-29T02:00", "2026-03-29T03:00", "60", null))
        assertFalse(WebFormValues.allowed(DATETIME_LOCAL, "2026-03-29T03:01", "2026-03-29T02:00", "2026-03-29T03:00", "60", null))
    }
}
