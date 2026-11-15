import Foundation
import Testing
@testable import Fast

/// An answer's body read into words off the main thread (AgentRead.read,
/// docs/main-thread-budget.md), the same words as when it was read there.
struct AgentReadTextTests {
    @Test func aPageIsReadIntoItsWords() {
        let html = Data("<html><head><title>x</title><script>var a = 1</script></head><body><p>Hello</p><p>there</p></body></html>".utf8)
        let read = AgentRead.read(html, type: "text/html; charset=utf-8", keepHTML: false)
        #expect(read.text == "Hello\nthere")
        #expect(!read.cut)
    }

    @Test func markupIsKeptWhenAskedFor() {
        let html = Data("<p>Hello</p>".utf8)
        #expect(AgentRead.read(html, type: "text/html", keepHTML: true).text == "<p>Hello</p>")
        #expect(AgentRead.read(Data("{\"a\":1}".utf8), type: "application/json", keepHTML: false).text == "{\"a\":1}")
    }

    @Test func aLongAnswerIsCutAtTheLimit() {
        let long = Data(String(repeating: "a", count: AgentRead.limit + 10).utf8)
        let read = AgentRead.read(long, type: "text/plain", keepHTML: false)
        #expect(read.cut)
        #expect(read.text.count == AgentRead.limit)
    }

    @Test func readingOffTheMainThreadGivesTheSameWords() async {
        let html = Data((0..<2000).map { "<div><b>Row \($0)</b> &amp; more</div>" }.joined().utf8)
        let here = AgentRead.read(html, type: "text/html", keepHTML: false)
        let there = await Task.detached { AgentRead.read(html, type: "text/html", keepHTML: false) }.value
        #expect(here == there)
    }
}
