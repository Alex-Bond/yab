package dev.yab.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DownloadNamesTest {
    @Test fun filenamesKeepANameWithoutPathOrHeaderControls() {
        assertEquals("invoice.pdf", DownloadNames.filename("https://example.com/opaque", "attachment; filename=\"../../invoice.pdf\""))
        assertEquals("report.pdf", DownloadNames.filename("https://example.com/report.pdf?secret=123", null))
        assertEquals("download", DownloadNames.filename("blob:https://example.com/id", null))
        assertEquals("photo.jpg", DownloadNames.filename("https://example.com/file", "attachment; filename=\"photo\r\n.jpg\""))
    }
    @Test fun extendedUtf8FilenameWinsWithoutTreatingPlusAsFormSpaceAndAmbiguityFallsBack() {
        assertEquals("отчёт+.pdf", DownloadNames.filename("https://example.test/fallback.pdf", "attachment; filename=old.pdf; filename*=UTF-8'ru'%D0%BE%D1%82%D1%87%D1%91%D1%82+.pdf"))
        assertEquals("a;b.pdf", DownloadNames.filename("https://example.test/fallback.pdf", "attachment; filename=\"a;b.pdf\""))
        assertEquals("fallback.pdf", DownloadNames.filename("https://example.test/fallback.pdf", "attachment; filename=a.pdf; FILENAME=b.pdf"))
        assertEquals("fallback.pdf", DownloadNames.filename("https://example.test/fallback.pdf", "attachment; filename*=UTF-8''a.pdf; filename*=UTF-8''b.pdf"))
        assertEquals("old.pdf", DownloadNames.filename("https://example.test/fallback.pdf", "attachment; filename=old.pdf; filename*=UTF-8''bad%ZZ.pdf"))
        assertEquals("fallback.pdf", DownloadNames.filename("https://example.test/fallback.pdf", "attachment; filename*=UTF-8''%C0%AFhidden.pdf"))
        assertEquals("safe.txt", DownloadNames.filename("https://example.test/fallback.pdf", "attachment; filename*=UTF-8''..%2F..%2Fsafe.txt"))
    }
    @Test fun unicodeNamesStayWithinTheFilesystemByteLimitWithoutSplittingSurrogates() {
        val cjk = DownloadNames.sanitize("界".repeat(120))
        assertEquals(85, cjk.length)
        assertEquals(255, cjk.toByteArray(Charsets.UTF_8).size)
        val emoji = DownloadNames.sanitize("😀".repeat(120))
        assertEquals(63, emoji.codePointCount(0, emoji.length))
        assertTrue(emoji.toByteArray(Charsets.UTF_8).size <= 255)
        assertTrue(Character.isLowSurrogate(emoji.last()))
        assertEquals("normal.txt", DownloadNames.sanitize("\uD800normal.txt"))
        assertEquals("download", DownloadNames.sanitize(".."))
    }

    @Test fun characterLimitKeepsTheCombiningMarkWithItsLastBaseCharacter() {
        val name = "a".repeat(119) + "e\u0301"
        assertEquals(name, DownloadNames.sanitize(name + "tail"))
    }

    @Test fun characterLimitKeepsTheWholeZeroWidthJoinerFamily() {
        val family = "👨‍👩‍👧‍👦"
        val name = "a".repeat(119) + family
        assertEquals(name, DownloadNames.sanitize(name + "tail"))
    }

    @Test fun byteLimitRejectsTheWholeFamilyInsteadOfKeepingAManAndJoiner() {
        val family = "👨‍👩‍👧‍👦"
        val prefix = "界".repeat(80) + "a".repeat(8)
        assertEquals(248, prefix.toByteArray(Charsets.UTF_8).size)
        assertEquals(prefix, DownloadNames.sanitize(prefix + family))
        val exact = "界".repeat(75) + "a".repeat(5) + family
        assertEquals(255, exact.toByteArray(Charsets.UTF_8).size)
        assertEquals(exact, DownloadNames.sanitize(exact + "tail"))
    }

    @Test fun anOversizedFirstGraphemeUsesTheExistingFallbackWithoutKeepingItsMarks() {
        val huge = "e" + "\u0301".repeat(130)
        assertTrue(huge.toByteArray(Charsets.UTF_8).size > 255)
        assertEquals("download", DownloadNames.sanitize(huge + ".txt"))
        assertEquals("safe", DownloadNames.sanitize("safe" + huge))
    }
}
