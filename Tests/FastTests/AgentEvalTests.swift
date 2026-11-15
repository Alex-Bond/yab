import WebKit
import XCTest
@testable import Fast

// An agent's own script (eval): what it means comes back, whatever its
// shape, a promise's value awaited, on a page whose policy forbids eval()
// and inline script as x.com's does. In a real page, with WebKit, under the
// guard, as AgentBench runs it.

@MainActor
final class AgentEvalTests: XCTestCase {
    // x.com's script-src (2026-09-28): a nonce, no 'unsafe-eval'.
    private let page = """
    <meta http-equiv="Content-Security-Policy" content="default-src 'self'; script-src 'self' 'nonce-yab' 'unsafe-inline' 'wasm-unsafe-eval'; script-src-attr 'none'">
    <title>Search</title>
    <form id="mail"><textarea>Hi Bob</textarea><button id="send">Send</button></form>
    """

    private var web: PageView!

    override func setUp() async throws {
        web = PageView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        web.loadHTMLString(page, baseURL: URL(string: "https://x.example.test/search"))
        // This page's, not the blank one's before it.
        for _ in 0..<100 {
            if try await web.evaluateJavaScript("document.readyState === 'complete' && document.title") as? String == "Search" { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// As AgentBench runs it: the guard set up, then the script.
    private func eval(_ js: String, patience: Double = 20) async -> Result<Any?, Error> {
        let armed = await withCheckedContinuation { go in AgentPage.arm(web, on: true) { go.resume(returning: $0) } }
        XCTAssertTrue(armed)
        return await withCheckedContinuation { go in AgentPage.eval(web, js, patience: patience) { go.resume(returning: $0) } }
    }

    private func value(_ js: String, line: UInt = #line) async -> Any? {
        switch await eval(js) {
        case .success(let got): return got
        case .failure(let error): XCTFail("\(js): \(AgentPage.Said(error).localizedDescription)", line: line); return nil
        }
    }

    private func failure(_ js: String, patience: Double = 20, line: UInt = #line) async -> String {
        guard case .failure(let error) = await eval(js, patience: patience) else { XCTFail("\(js) didn't fail", line: line); return "" }
        return AgentPage.Said(error).localizedDescription
    }

    func testThePagesPolicyIsInForce() async throws {
        let page = try await web.evaluateJavaScript("(() => { try { eval('1'); return 'ran' } catch (e) { return e.name } })()")
        XCTAssertEqual(page as? String, "EvalError")
    }

    func testAnExpressionsValue() async {
        let sum = await value("1+1")
        XCTAssertEqual(sum as? Int, 2)
        let title = await value("document.title")
        XCTAssertEqual(title as? String, "Search")
    }

    func testAnAsyncIIFEIsAwaited() async {
        let got = await value("(async () => { await new Promise(r => setTimeout(r, 30)); return document.title + '!' })()")
        XCTAssertEqual(got as? String, "Search!")
        let semicolon = await value("(async () => 5)();\n")
        XCTAssertEqual(semicolon as? Int, 5)
    }

    func testAScriptsLastValue() async {
        let got = await value("const a = 2; a * 3")
        XCTAssertEqual(got as? Int, 6)
    }

    func testAwaitAndReturnInAScript() async {
        let got = await value("const t = await Promise.resolve(document.title);\nreturn t.length")
        XCTAssertEqual(got as? Int, 6)
    }

    func testAFunctionIsDeclaredForTheNextScript() async {
        _ = await eval("function twice(x) { return 2 * x }")
        let got = await value("twice(4)")
        XCTAssertEqual(got as? Int, 8)
    }

    func testNothingIsNull() async {
        let got = await value("(async () => {})()")
        XCTAssertTrue(got is NSNull, "\(String(describing: got))")
    }

    func testAFailureSaysWhy() async {
        let thrown = await failure("(async () => { throw new Error('boom') })()")
        XCTAssertTrue(thrown.contains("boom"), thrown)
        // WebKit has no line for a rejection: the words have the script's.
        let there = await failure("(async () => {\n  null.x\n})()")
        XCTAssertTrue(there.hasSuffix("(line 2)"), there)
        let late = await failure("new Promise(() => {})", patience: 0.2)
        XCTAssertTrue(late.contains("hadn't settled after 0 s"), late)
    }

    func testAPressAfterAwaitIsStillHeld() async {
        let got = await value("(async () => { await null; document.querySelector('#send').click(); return 1 })()")
        XCTAssertEqual(got as? Int, 1)
        let held = await withCheckedContinuation { go in AgentPage.held(web, "take") { go.resume(returning: $0) } } as? [String: Any]
        XCTAssertEqual(held?["commit"] as? String, "Send")
        AgentPage.held(web, "drop")
    }

    func testWhichScriptsAreAwaited() {
        XCTAssertNotNil(AgentPage.awaited("1+1"))
        XCTAssertNotNil(AgentPage.awaited("(async () => 1)();"))
        XCTAssertNotNil(AgentPage.awaited("const r = await fetch('/'); return r.status"))
        XCTAssertNil(AgentPage.awaited("const a = 1; a"))
        XCTAssertNil(AgentPage.awaited("function f() {}"))
        XCTAssertNil(AgentPage.awaited("class A {}"))
        XCTAssertNil(AgentPage.awaited("}{"))
    }
}
