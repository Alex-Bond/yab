import AppKit
import Testing
import WebKit
@testable import Fast

@MainActor
@Suite(.serialized)
struct PageEngineTests {
    @Test func worldsAndArgumentsReachTheEngine() async throws {
        let view = PageView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), configuration: WKWebViewConfiguration())
        let page: any PageHandle = view
        page.navigate(html: "<p>engine seam</p>", base: URL(string: "https://seam.test/"))
        for _ in 0..<200 where page.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        let value = try await page.call("globalThis.seamValue = text; return count + 1",
                                        arguments: ["text": "kept", "count": 41], in: .named("seam-test"))
        #expect((value as? NSNumber)?.intValue == 42)
        let kept = try await page.run("globalThis.seamValue", in: .named("seam-test"), gesture: false)
        #expect(kept as? String == "kept")
        let isolated = try await page.run("typeof globalThis.seamValue", in: .page)
        #expect(isolated as? String == "undefined")
        do {
            _ = try await page.call("throw new Error('seam failure')", in: .client)
            Issue.record("a JavaScript exception must reach the caller")
        } catch { }
    }

    /// Bench's ordinary eval used WebKit's callback without an explicit
    /// world. The seam must keep both its JSON values and its failures.
    @Test func pageCallbacksKeepLegacyResults() async throws {
        let view = PageView(frame: .zero, configuration: WKWebViewConfiguration())
        let page: any PageHandle = view
        for script in ["42", "'words'", "null", "undefined", "({ count: 2, rows: [true, null] })", "throw new Error('callback failure')"] {
            let before: Result<Any?, Error> = await withCheckedContinuation { answer in
                view.evaluateJavaScript(script) { value, error in
                    if let error { answer.resume(returning: .failure(error)) }
                    else { answer.resume(returning: .success(value)) }
                }
            }
            let after: Result<Any?, Error> = await withCheckedContinuation { answer in
                page.run(script) { answer.resume(returning: $0) }
            }
            switch (before, after) {
            case (.success(let old), .success(let new)):
                let oldJSON = try JSONSerialization.data(withJSONObject: ["value": Bench.plain(old)], options: .sortedKeys)
                let newJSON = try JSONSerialization.data(withJSONObject: ["value": Bench.plain(new)], options: .sortedKeys)
                #expect(oldJSON == newJSON)
            case (.failure(let old), .failure(let new)):
                #expect((old as NSError).domain == (new as NSError).domain)
                #expect((old as NSError).code == (new as NSError).code)
                #expect((old as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
                        == (new as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String)
            default: Issue.record("the seam changed the result of \(script)")
            }
        }
    }

    @Test func callbackFunctionsUseInstalledConsumerWorlds() async throws {
        let view = PageView(frame: .zero, configuration: WKWebViewConfiguration())
        let page: any PageHandle = view
        let worlds: [(PageWorld, WKContentWorld)] = [(.yab, Web.world), (.named("yab-agent"), AgentPage.world),
                                                   (.named("yab-dark"), DarkPages.world), (.named("float"), Isolate.world), (.client, .defaultClient)]
        for (world, installed) in worlds {
            _ = try await view.callAsyncJavaScript("globalThis.consumerValue = 7; return true", arguments: [:], in: nil, contentWorld: installed)
            let result: Result<Any?, Error> = await withCheckedContinuation { answer in
                page.call("return await Promise.resolve(consumerValue + extra)", arguments: ["extra": 5], in: world) {
                    answer.resume(returning: $0)
                }
            }
            #expect(try result.get() as? Int == 12)
        }
        #expect(try await page.run("typeof consumerValue") as? String == "undefined")
    }

    /// Sheets exports run in the client world with that page's fetch.
    /// A local transport fixture keeps this independent of Google/network.
    @Test func sheetReaderUsesThePagesClientWorld() async throws {
        let view = PageView(frame: .zero, configuration: WKWebViewConfiguration())
        let page: any PageHandle = view
        page.navigate(html: "<title>Sheet seam</title>", base: URL(string: "https://docs.google.com/spreadsheets/d/seam/edit#gid=0"))
        for _ in 0..<100 {
            if (try? await page.run("document.title")) as? String == "Sheet seam" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(try await page.run("document.title") as? String == "Sheet seam")
        _ = try await page.call("""
        globalThis.sheetFixture = true;
        globalThis.fetch = async path => ({
          ok: true,
          headers: { get: () => 'text/csv' },
          text: async () => path.endsWith('/htmlview') ? '' : 'Name,Count\\nKept,42'
        });
        return true;
        """, in: .client)
        let text = await PageWords.sheet(page)
        #expect(text?.contains("Tab \"0\" (the one open)") == true)
        #expect(text?.contains("Name,Count\nKept,42") == true)
        #expect(try await page.run("typeof sheetFixture", in: .page) as? String == "undefined")
    }

    @Test func foreignFramesFailInsteadOfRunningInTheMainFrame() async {
        let view = PageView(frame: .zero, configuration: WKWebViewConfiguration())
        let page: any PageHandle = view
        let frame = PageFrame(isMain: false, url: nil, token: NSObject())
        do {
            _ = try await page.run("globalThis.mustNotRun = true", frame: frame)
            Issue.record("a foreign frame must not become the main frame")
        } catch {
            #expect(error is PageEngineError)
        }
    }

    /// Cross-origin children and a nested child must keep their target,
    /// world and agent announcement when crossing the seam.
    @Test func discoveredFramesKeepTheirDocumentsAndAgentWorld() async throws {
        func document(_ body: String) -> String {
            "data:text/html;base64," + Data(body.utf8).base64EncodedString()
        }
        let nested = document("<p>nested seam</p>")
        let first = document("<p>first seam</p><iframe src='\(nested)'></iframe>")
        let second = document("<p>second seam</p>")
        let config = WKWebViewConfiguration()
        config.userContentController.add(FrameRelay.shared, contentWorld: AgentPage.world, name: FrameRelay.name)
        config.userContentController.addUserScript(WKUserScript(source: AgentPage.frameScript, injectionTime: .atDocumentEnd,
                                                               forMainFrameOnly: false, in: AgentPage.world))
        let view = PageView(frame: CGRect(x: 0, y: 0, width: 640, height: 480), configuration: config)
        let page: any PageHandle = view
        let key = ObjectIdentifier(page)
        defer { AgentPage.frames[key] = nil }
        page.navigate(html: "<title>Frame seam</title><iframe src='\(first)'></iframe><iframe src='\(second)'></iframe>",
                      base: URL(string: "https://seam.test/"))
        // Frame discovery is used after a document is ready in production.
        // Wait for the children to announce themselves before querying the
        // private WebKit frame tree, which may not answer before load.
        for _ in 0..<200 where AgentPage.frames[key]?.count != 3 {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(AgentPage.frames[key]?.count == 3)
        let found: [PageFrame]? = await withCheckedContinuation { answer in
            var replied = false
            page.childFrames { frames in
                guard !replied else { return }
                replied = true
                answer.resume(returning: frames)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                guard !replied else { return }
                replied = true
                answer.resume(returning: nil)
            }
        }
        let frames = try #require(found, "the engine must answer frame discovery")
        #expect(frames.count == 3)
        let expected = [first, nested, second]
        #expect(frames.map { $0.url?.absoluteString ?? "" } == expected)
        for (index, frame) in frames.enumerated() {
            #expect(!frame.isMain)
            let before = try await view.callAsyncJavaScript("return document.body.innerText.trim()", arguments: [:],
                                                            in: frame.webKit, contentWorld: AgentPage.world)
            let after = try await page.call("globalThis.frameValue = extra; return document.body.innerText.trim()",
                                             arguments: ["extra": index], in: .named("yab-agent"), frame: frame)
            #expect(before as? String == after as? String)
            #expect(try await page.run("frameValue", in: .named("yab-agent"), frame: frame, gesture: false) as? Int == index)
            #expect(try await page.run("typeof frameValue", frame: frame) as? String == "undefined")
        }
        #expect(try await page.run("typeof frameValue", in: .named("yab-agent")) as? String == "undefined")
        // Read the same children through AgentPage rather than its relay.
        AgentPage.frames[key] = nil
        await withCheckedContinuation { answer in AgentPage.discover(page) { answer.resume() } }
        let announced = AgentPage.frames[key] ?? []
        #expect(Set(announced.map(\.href)) == Set(expected))
        for frame in announced {
            let found = try #require(AgentPage.frame(in: page, src: frame.href, w: frame.w, h: frame.h))
            #expect(found.token === frame.info.token)
        }
        // A valid frame from a different WebKit view is still foreign.
        let other: any PageHandle = PageView(frame: .zero, configuration: WKWebViewConfiguration())
        let target = try #require(frames.first)
        for gesture in [true, false] {
            let result: Result<Any?, Error> = await withCheckedContinuation { answer in
                other.call("globalThis.mustNotRun = true; return true", in: .named("yab-agent"), frame: target, gesture: gesture) {
                    answer.resume(returning: $0)
                }
            }
            if case .failure(let error) = result { #expect(error is PageEngineError) }
            else { Issue.record("another view's frame must be rejected") }
        }
        #expect(try await other.run("typeof mustNotRun", in: .named("yab-agent")) as? String == "undefined")
    }

    /// Native input crosses the handle into a real document. A page sees
    /// trusted presses, while Yab must not mistake them for the person
    /// taking the wheel from the agent.
    @Test func nativeInputReachesTheDocumentWithoutTakingTheWheel() async throws {
        let view = PageView(frame: CGRect(x: 0, y: 0, width: 640, height: 480), configuration: WKWebViewConfiguration())
        let page: any PageHandle = view
        #expect(!AgentPage.click(page, x: 20, y: 20))
        #expect(!AgentPage.hover(page, x: 20, y: 20))
        let absent = await withCheckedContinuation { answer in
            AgentPage.drag(page, from: .zero, to: CGPoint(x: 40, y: 40)) { answer.resume(returning: $0) }
        }
        #expect(!absent)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        let before = PageView.person
        var person = false
        PageView.person = { web in if web === view { person = true } else { before?(web) } }
        defer { PageView.person = before; window.close() }
        page.navigate(html: """
        <style>body{margin:0}button,input{display:block;width:200px;height:60px;box-sizing:border-box}</style>
        <button id=press>Press</button><input id=words>
        <script>
        window.presses = 0; window.drags = 0; window.ups = 0; window.dragging = false;
        press.addEventListener('click', e => { if(e.isTrusted) presses++; });
        // Direct NSEvents don't change the system pointer's button mask.
        // Count movement between this document's down and up instead.
        document.addEventListener('mousedown', () => { dragging = true; });
        document.addEventListener('mouseup', () => { dragging = false; });
        document.addEventListener('mousemove', () => { if(dragging) drags++; });
        document.addEventListener('keyup', e => { if(e.isTrusted) ups++; });
        </script>
        """, base: URL(string: "https://input.seam.test/"))
        for _ in 0..<200 {
            if (try? await page.run("document.readyState === 'complete' && typeof presses === 'number'")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        window.orderFront(nil)
        // Let the native content view finish its first layout before input.
        try await Task.sleep(for: .milliseconds(100))
        page.pageZoom = 1.5
        try await Task.sleep(for: .milliseconds(100))
        #expect(AgentPage.click(page, x: 50, y: 30))
        for _ in 0..<100 {
            if (try? await page.run("presses")) as? Int == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try await page.run("presses") as? Int == 1)
        #expect(AgentPage.hover(page, x: 60, y: 30))
        let dragged = await withCheckedContinuation { answer in
            AgentPage.drag(page, from: CGPoint(x: 50, y: 150), to: CGPoint(x: 120, y: 180)) { answer.resume(returning: $0) }
        }
        #expect(dragged)
        _ = try await page.run("document.querySelector('#words').focus()")
        AgentPage.insert(page, "cat")
        #expect(AgentPage.press(page, "Backspace") == nil)
        for _ in 0..<100 {
            if (try? await page.run("ups")) as? Int == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try await page.run("document.querySelector('#words').value") as? String == "ca")
        #expect(try await page.run("ups") as? Int == 1)
        #expect(try await page.run("drags > 0") as? Bool == true)
        #expect(!person)
        #expect(!PageView.agentActing)
    }

    @Test func snapshotDefaultsAndExplicitGeometryArePreserved() throws {
        #expect(PageShot().configuration == nil)
        let rect = CGRect(x: 12, y: 24, width: 320, height: 640)
        let config = try #require(PageShot(rect: rect, width: 160, afterUpdates: false).configuration)
        #expect(config.rect == rect)
        #expect(config.snapshotWidth?.doubleValue == 160)
        #expect(!config.afterScreenUpdates)
    }
}
