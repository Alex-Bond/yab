package dev.yab.nativefeatures

import org.junit.Assert.*
import org.junit.Test

class TranslationBatchingTest {
    @Test fun longPageNodesAreBatchedWithoutLosingTheOriginalTail() {
        val original = listOf(TranslationSegment("a", "abcde".repeat(1100)), TranslationSegment("b", "Tail"))
        val pieces = TranslationBatching.pieces(original)
        assertTrue(pieces.all { it.text.length <= 2500 })
        assertEquals(original, TranslationBatching.combine(pieces, pieces.map { it.text }))
    }
    @Test(expected = IllegalArgumentException::class) fun duplicateDomNodeIdentitiesAreRefused() {
        TranslationBatching.pieces(listOf(TranslationSegment("a", "one"), TranslationSegment("a", "two")))
    }
    @Test(expected = IllegalArgumentException::class) fun partialOutputCannotBeAppliedToTheWrongNodes() {
        TranslationBatching.combine(listOf(TranslationBatching.Piece("a", "one")), emptyList())
    }
}
