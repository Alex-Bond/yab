package dev.yab.browser

import dev.yab.browser.field.*
import java.time.Instant
import java.time.ZoneId
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class FieldCalculatorTest {
    @Test fun everyAnswerMatchesTheActualCurrentSwiftOracle() {
        val source = System.getenv("YAB_FIELD_CALCULATOR_ORACLE")?.let { java.io.File(it).readText() }
            ?: requireNotNull(javaClass.getResourceAsStream("/field-calculator/swift-oracle.json")).bufferedReader().use { it.readText() }
        val oracle = Json.parseToJsonElement(source).jsonObject
        val now = Instant.ofEpochSecond(oracle.getValue("nowEpochSeconds").jsonPrimitive.double.toLong())
        val rates = FieldRatesSnapshot(oracle.getValue("rates").jsonObject.mapValues { it.value.jsonPrimitive.double }, now)
        val zone = ZoneId.of(oracle.getValue("zone").jsonPrimitive.content)
        val mismatches = mutableListOf<String>()
        for (vector in oracle.getValue("vectors").jsonArray) {
            val words = vector.jsonObject.getValue("words").jsonPrimitive.content
            val expected = vector.jsonObject.getValue("answer")
            val actual = FieldCalculator.answer(words, now, rates, zone, "USD")
            if (expected == JsonNull) { if (actual != null) mismatches += "$words expected no answer, received $actual" }
            else {
                if (actual == null) { mismatches += "$words expected answer, received null"; continue }
                val value = expected.jsonObject
                for ((key, received) in listOf("question" to actual.question, "questionNote" to actual.questionNote,
                    "result" to actual.result, "resultNote" to actual.resultNote, "copy" to actual.copy)) {
                    val wanted = value.getValue(key).jsonPrimitive.content
                    if (wanted != received) mismatches += "$words $key expected <$wanted> received <$received>"
                }
            }
        }
        assertTrue(mismatches.joinToString("\n"), mismatches.isEmpty())
    }

    @Test fun incompleteLocalMathDoesNotBecomeAnAddressOrNetworkSuggestion() {
        for (words in listOf("2", "2400*", "(2+", "sqrt(", "2x", "2400*12", "20% of 80", "5 km to mi", "time in tokyo", "days until christmas"))
            assertTrue(words, FieldCalculator.keepsLocal(words))
        for (words in listOf("https://example.com/2+2", "127.0.0.1", "localhost:3000", "weather lisbon", "iphone 15 to 16"))
            assertFalse(words, FieldCalculator.keepsLocal(words))
        for (words in listOf("2", " (2+3)", "-2*3", "1.5", "100%")) assertTrue(words, FieldCalculator.mathKeys(words))
        for (words in listOf("", "sqrt(2)", "2 km", "12 dollars", "site.com")) assertFalse(words, FieldCalculator.mathKeys(words))
    }

    @Test fun reverseKeepsVisibleUnitBaseAndCurrencyClipboardSemantics() {
        val now = Instant.parse("2026-09-25T11:00:00Z")
        val rates = FieldRatesSnapshot(mapOf("EUR" to 0.9), now)
        for ((words, expected) in listOf("5 km to mi" to "5 km", "0xff in decimal" to "0xFF", "255 in hex" to "255", "100 dollars in euros" to "100")) {
            val original = requireNotNull(FieldCalculator.answer(words, now, rates))
            val reverse = requireNotNull(FieldCalculator.reverse(original, words, rates))
            assertEquals(original.result, reverse.question); assertEquals(original.question, reverse.result)
            assertEquals(words, expected, reverse.copy)
        }
        assertNull(FieldCalculator.reverse(requireNotNull(FieldCalculator.answer("2+2")), "2+2", rates))
    }

    @Test fun pendingRatesCannotCopyAndTimeDateReturnStillSearches() {
        val pending = requireNotNull(FieldCalculator.answer("100 dollars to euros"))
        assertEquals("Getting rates", pending.resultNote); assertEquals("", pending.copy); assertFalse(pending.takesReturn)
        assertNull(FieldCalculator.reverse(pending, "100 dollars to euros", FieldRatesSnapshot()))
        val failed = requireNotNull(FieldCalculator.answer("100 dollars to euros", rates = FieldRatesSnapshot(failed = true)))
        assertEquals("Rates unavailable", failed.resultNote); assertFalse(failed.takesReturn)
        for (words in listOf("time in tokyo", "3pm london in sf", "days until christmas", "in 3 weeks")) {
            val answer = requireNotNull(FieldCalculator.answer(words))
            assertTrue(answer.copy.isNotEmpty()); assertFalse(words, answer.takesReturn)
        }
    }

    @Test fun explicitHexColorsNormalizeTheirQuestionAndCopyAndShowExactDecimalRgb() {
        val cases = listOf(
            Triple("#A78BFA", "#A78BFA", "RGB 167, 139, 250"),
            Triple("#a78bfa", "#A78BFA", "RGB 167, 139, 250"),
            Triple(" #a78bfa ", "#A78BFA", "RGB 167, 139, 250"),
            Triple("#abc", "#AABBCC", "RGB 170, 187, 204"),
            Triple("#fff", "#FFFFFF", "RGB 255, 255, 255"),
            Triple("#000000", "#000000", "RGB 0, 0, 0"),
            Triple("#f0A", "#FF00AA", "RGB 255, 0, 170"),
        )
        for ((words, hex, rgb) in cases) {
            assertEquals(words, FieldAnswer(hex, "HEX", rgb, "RGB", hex, FieldAnswer.Kind.COLOR), FieldCalculator.answer(words))
        }
    }

    @Test fun hexReadingRejectsNonAsciiWrongLengthsBareWordsAndAddressFragments() {
        for (words in listOf("#", "#12", "#1234", "#12345g", "#a78bfa text", "#12345678", "a78bfa",
            "#１２３", "#ＡＢＣ", "#١٢٣", "＃abc", "#ab c", "#a\nbc", "##abc", "#fff?x",
            "https://example.test/#abc", "example.test/#fff")) {
            assertNull(words, FieldCalculator.answer(words))
            assertFalse(words, FieldCalculator.keepsLocal(words))
        }
    }

    @Test fun hexReturnLocalAndHorizontalTrimStaySeparateFromExistingReadings() {
        for (space in listOf(" ", "\t", "\u00A0", "\u2003", "\u3000")) {
            val words = space + "#abc" + space
            val answer = requireNotNull(FieldCalculator.answer(words, rates = FieldRatesSnapshot(failed = true)))
            assertEquals("#AABBCC", answer.copy)
            assertTrue(answer.takesReturn)
            assertTrue(FieldCalculator.keepsLocal(words))
            assertNull(FieldCalculator.reverse(answer, words, FieldRatesSnapshot()))
            assertFalse(FieldCalculator.mathKeys(words))
        }
        for (newline in listOf("\n", "\r", "\r\n", "\u000B", "\u000C", "\u0085", "\u2028", "\u2029")) {
            assertNull(FieldCalculator.answer(newline + "#abc"))
            assertNull(FieldCalculator.answer("#abc" + newline))
        }
        // Existing math/unit normalization and the hexadecimal-number reading stay intact.
        assertEquals("4", requireNotNull(FieldCalculator.answer("\n2+2\n")).copy)
        assertEquals("3.1069 mi", requireNotNull(FieldCalculator.answer("\n5 km to mi\n")).copy)
        assertEquals(FieldAnswer.Kind.BASE, requireNotNull(FieldCalculator.answer("255 in hex")).kind)
        assertEquals("0xFF", requireNotNull(FieldCalculator.answer("255 in hex")).copy)
        assertEquals("255", requireNotNull(FieldCalculator.answer("0xff")).copy)
        assertEquals(FieldAnswer.Kind.BASE, requireNotNull(FieldCalculator.answer("0xA78BFA")).kind)
        assertEquals("10980346", requireNotNull(FieldCalculator.answer("0xA78BFA")).copy)
    }

    @Test fun currentPhoneCurrencyNamesAndLowercaseCodesUseTheirExactCurrencies() {
        val now = Instant.parse("2026-09-25T11:00:00Z")
        val rates = FieldRatesSnapshot(mapOf("ETH" to 0.0005, "USDT" to 1.0, "USDC" to 1.0, "LKR" to 300.0), now)
        for ((words, name, copy) in listOf(
            Triple("1 ethereum to usd", "Ethereum", "2000"),
            Triple("1 Ethereums to usd", "Ethereum", "2000"),
            Triple("1 tether to usd", "Tether", "1"),
            Triple("1 tethers to usd", "Tether", "1"),
            Triple("1 usd coin to usd", "USD Coin", "1"),
            Triple("1 USD coins to usd", "USD Coin", "1"),
            Triple("300 sri lankan rupee to usd", "Sri Lankan Rupee", "1"),
            Triple("300 Sri Lankan rupees to usd", "Sri Lankan Rupee", "1"),
            Triple("300 lkr to usd", "Sri Lankan Rupee", "1"),
        )) {
            val answer = requireNotNull(FieldCalculator.answer(words, now, rates, homeCurrency = "USD"))
            assertEquals(words, FieldAnswer.Kind.MONEY, answer.kind)
            assertEquals(words, name, answer.questionNote)
            assertEquals(words, copy, answer.copy)
            if (name == "Sri Lankan Rupee") {
                assertEquals(words, "LKR 300.00", answer.question)
                assertEquals(words, "$1.00", answer.result)
            }
            assertTrue(words, answer.takesReturn)
            assertTrue(words, FieldCalculator.keepsLocal(words, now, rates))
        }
        val toRupees = requireNotNull(FieldCalculator.answer("1 usd to lkr", now, rates, homeCurrency = "USD"))
        assertEquals("LKR 300.00", toRupees.result)
        assertEquals("300", toRupees.copy)
    }

    @Test fun satoshiRatesAreDerivedOnlyFromBitcoinAndIgnoreAnySeparateSatQuote() {
        val rates = FieldRatesSnapshot(mapOf("BTC" to 0.00001, "SAT" to 7.0))
        assertTrue(rates.knows("SAT"))
        assertEquals(1.0, requireNotNull(rates.convert(100_000_000.0, "SAT", "BTC")), 0.000000001)
        assertEquals(100_000_000.0, requireNotNull(rates.convert(1.0, "BTC", "SAT")), 2 * Math.ulp(100_000_000.0))
        assertEquals(1.0, requireNotNull(rates.convert(1000.0, "SAT", "USD")), 0.000000001)
        assertEquals(1000.0, requireNotNull(rates.convert(1.0, "USD", "SAT")), 0.000000001)

        val separateQuoteOnly = FieldRatesSnapshot(mapOf("SAT" to 7.0))
        assertFalse(separateQuoteOnly.knows("SAT"))
        assertNull(separateQuoteOnly.convert(1000.0, "SAT", "USD"))
        assertNull(separateQuoteOnly.convert(1.0, "USD", "SAT"))
        val pending = requireNotNull(FieldCalculator.answer("1000 satoshis to usd", rates = separateQuoteOnly))
        assertEquals("Getting rates", pending.resultNote)
        assertEquals("", pending.copy)
        assertFalse(pending.takesReturn)
        assertNull(FieldCalculator.reverse(pending, "1000 satoshis to usd", separateQuoteOnly))
    }

    @Test fun satsDisplayAndReversePreserveExactMoneyClipboardSemantics() {
        val now = Instant.parse("2026-09-25T11:00:00Z")
        val rates = FieldRatesSnapshot(mapOf("BTC" to 0.00001), now)
        for (name in listOf("satoshi", "satoshis", "sat", "sats", "SAT")) {
            val words = "1000 $name to usd"
            val answer = requireNotNull(FieldCalculator.answer(words, now, rates))
            assertEquals(words, "1,000 sats", answer.question)
            assertEquals(words, "Bitcoin satoshis", answer.questionNote)
            assertEquals(words, "$1.00", answer.result)
            assertEquals(words, "1", answer.copy)
            val reverse = requireNotNull(FieldCalculator.reverse(answer, words, rates))
            assertEquals(words, answer.result, reverse.question)
            assertEquals(words, answer.question, reverse.result)
            assertEquals(words, "1000", reverse.copy)
        }
        val toSats = requireNotNull(FieldCalculator.answer("1 usd to sats", now, rates))
        assertEquals("1,000 sats", toSats.result)
        assertEquals("Bitcoin satoshis", toSats.resultNote)
        assertEquals("1000", toSats.copy)
        val fractional = requireNotNull(FieldCalculator.answer("0.00000001 sats to usd", now, rates))
        assertEquals("0.00000001 sats", fractional.question)
    }

    @Test fun moneyConversionRejectsNonfiniteOrNonpositiveRatesBeforeArithmetic() {
        for (invalid in listOf(Double.NaN, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY, 0.0, -1.0)) {
            val ordinary = FieldRatesSnapshot(mapOf("EUR" to invalid))
            assertNull(ordinary.convert(1.0, "EUR", "USD"))
            assertNull(ordinary.convert(1.0, "USD", "EUR"))
            val bitcoin = FieldRatesSnapshot(mapOf("BTC" to invalid, "SAT" to 1000.0))
            assertNull(bitcoin.convert(1000.0, "SAT", "USD"))
            assertNull(bitcoin.convert(1.0, "USD", "SAT"))
        }
        val overflowingSatoshiRate = FieldRatesSnapshot(mapOf("BTC" to Double.MAX_VALUE))
        assertNull(overflowingSatoshiRate.convert(1.0, "SAT", "USD"))
        assertNull(overflowingSatoshiRate.convert(1.0, "USD", "SAT"))
    }

    @Test fun moneyConversionRequiresFiniteResultWithoutChangingZeroOrSignedAmounts() {
        val rates = FieldRatesSnapshot(mapOf("BTC" to 0.00001))
        for (invalid in listOf(Double.NaN, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY, Double.MAX_VALUE))
            assertNull(rates.convert(invalid, "USD", "SAT"))
        assertEquals(0.0, requireNotNull(rates.convert(0.0, "SAT", "USD")), 0.0)
        assertEquals(-1.0, requireNotNull(rates.convert(-1000.0, "SAT", "USD")), 0.000000001)
    }
}
