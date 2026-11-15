import Foundation
import Testing
@testable import Fast

@MainActor
struct RichMemoCacheTests {
    @Test func aLongConversationKeepsItsCompletedBlocksWarm() {
        var cache = RichTextCache()
        var builds = 0
        for _ in 0..<3 {
            for line in 0..<750 {
                let words = "Line \(line): the document is ready."
                let value = cache.value(words) { builds += 1; return AttributedString(words) }
                #expect(String(value.characters) == words)
            }
        }
        #expect(builds == 750)
        #expect(cache.count == 750)
        #expect(cache.estimatedCost <= cache.costLimit)
    }

    @Test func frequentlyUsedBlocksSurviveCapacityPressure() {
        var cache = RichTextCache(costLimit: 100_000, countLimit: 2)
        var builds = 0
        for words in ["a", "b", "a", "c", "a"] {
            _ = cache.value(words) { builds += 1; return AttributedString(words) }
        }
        #expect(builds == 3)
        #expect(cache.count == 2)
        _ = cache.value("b") { builds += 1; return AttributedString("b") }
        #expect(builds == 4)
        #expect(cache.count == 2)
    }

    @Test func oversizedTextDoesNotFlushTheWorkingSet() {
        var cache = RichTextCache(costLimit: 1024)
        var builds = 0
        _ = cache.value("kept") { builds += 1; return AttributedString("kept") }
        let large = String(repeating: "字🙂", count: 1000)
        for _ in 0..<2 {
            let value = cache.value(large) { builds += 1; return AttributedString(large) }
            #expect(String(value.characters) == large)
        }
        _ = cache.value("kept") { builds += 1; return AttributedString("kept") }
        #expect(builds == 3)
        #expect(cache.count == 1)
        #expect(cache.estimatedCost <= cache.costLimit)
    }

    @Test func growingUnicodePrefixesStayWithinBothLimits() {
        var cache = RichTextCache(costLimit: 4096, countLimit: 8)
        for length in 1...1000 {
            let words = String(repeating: "字🙂", count: length)
            let value = cache.value(words) { AttributedString(words) }
            #expect(String(value.characters) == words)
            #expect(cache.count <= 8)
            #expect(cache.estimatedCost <= 4096)
        }
    }
}
