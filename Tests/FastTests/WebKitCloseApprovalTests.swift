import AppKit
import Testing
import WebKit
@testable import Fast

/// Determines whether WK's original _tryClose can be reused as an approval
/// before an engine switch. No Browser.close callback and no DOM input events.
@MainActor
@Suite(.serialized)
struct WebKitCloseApprovalTests {
    private static var traceInstalled = false
    private func installTraceIfRequested() {
        guard EvalTrace.on, !Self.traceInstalled else { return }
        Self.traceInstalled = true
        EvalTrace.install()
    }
    @MainActor private final class Read {
        var pending: CheckedContinuation<Any, Error>?
        init(_ pending: CheckedContinuation<Any, Error>) { self.pending = pending }
        func finish(_ value: Any?, _ error: Error?) {
            guard let continuation = pending else { return }
            pending = nil
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume(returning: value ?? NSNull()) }
        }
    }
    private func read(_ web: WKWebView, _ script: String) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            let reply = Read(continuation)
            // Public evaluateJavaScript grants a gesture even for a read, which
            // would fabricate the sticky activation this native-input fixture measures.
            web.evaluate(.expression(script), in: .page, frame: nil, gesture: false) { result in
                switch result {
                case .success(let value): reply.finish(value, nil)
                case .failure(let error): reply.finish(nil, error)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                reply.finish(nil, NSError(domain: "WKApprovalFixture", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Original WK document did not answer: " + script]))
            }
        }
    }

    /// Read the original native document UUID through WK's frame-tree SPI.
    /// A UUID observation is not a reservation or a beforeunload approval token.
    private func document(_ web: WKWebView) async throws -> String {
        let frames = NSSelectorFromString("_frames:")
        let document = NSSelectorFromString("_documentIdentifier")
        try #require(web.responds(to: frames), "Native WK frame-tree observation must be available")
        let value: Any = try await withCheckedThrowingContinuation { continuation in
            let reply = Read(continuation)
            let block: @convention(block) (NSObject?) -> Void = { node in
                MainActor.assumeIsolated {
                    guard let frame = node?.value(forKey: "info") as? WKFrameInfo,
                          frame.isMainFrame, frame.responds(to: document),
                          let uuid = frame.perform(document)?.takeUnretainedValue() as? NSUUID else {
                        reply.finish(nil, NSError(domain: "WKApprovalFixture", code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Native main-document UUID unavailable"]))
                        return
                    }
                    reply.finish(uuid.uuidString, nil)
                }
            }
            _ = web.perform(frames, with: block)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                reply.finish(nil, NSError(domain: "WKApprovalFixture", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Native WK frame-tree observation timed out"]))
            }
        }
        return try #require(value as? String)
    }

    /// Controller plumbing only. The real WK test below must separately prove
    /// that its private native callback reaches this same original wait.
    @Test func stayCardSettlesItsOriginalWaitAndNativeReplyOnce() throws {
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        let tab = Tab(engine: .webKit, factory: .webKitOnly)
        browser.prepare(tab); browser.lay([tab]); browser.activeID = tab.id
        let web = try #require(tab.page.webKit)
        let id = ObjectIdentifier(web)
        defer {
            browser.dropAsks(tab); Leaving.waits[id] = nil
            tab.close(); browser.letGo()
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
        }
        var heard: [Bool] = [], nativeReplies: [Bool] = []
        let wait = Leaving.Wait { heard.append($0) }
        Leaving.waits[id] = wait
        Leaving.asked(web, by: browser, host: "wk-approval.test") { nativeReplies.append($0) }
        try #require(tab.asks.count == 1 && tab.asks.first?.kind == .leave)
        #expect(wait.asking && heard.isEmpty && nativeReplies.isEmpty)
        browser.answer(tab, .no)
        #expect(heard == [false] && nativeReplies == [false])
        #expect(Leaving.waits[id] == nil && tab.asks.isEmpty)
        #expect(!tab.gone && tab.builtPage === web)
        browser.answer(tab, .no)
        #expect(heard == [false] && nativeReplies == [false])
    }

    /// Test-only native UIDelegate interception. It forwards the REAL native
    /// beforeunload to Browser's actual PageAsk, records the user's intent and
    /// answers the ORIGINAL WK completion false. No approval token is minted.
    @MainActor private final class NativeIntentObserver: NSObject, WKUIDelegate {
        let browser: Browser
        let original: WebKitPageEvents
        let expectedWeb: WKWebView
        let onNativeAnswer: (Bool) -> Void
        var userAnswers: [Bool] = [], nativeAnswers: [Bool] = [], nativeDocuments: [String] = []
        var nativeCloseCallbacks = 0
        init(browser: Browser, web: WKWebView, original: WebKitPageEvents, onNativeAnswer: @escaping (Bool) -> Void) {
            self.browser = browser; expectedWeb = web; self.original = original; self.onNativeAnswer = onNativeAnswer
            super.init()
        }
        override func responds(to selector: Selector!) -> Bool { super.responds(to: selector) || original.responds(to: selector) }
        override func forwardingTarget(for selector: Selector!) -> Any? {
            original.responds(to: selector) ? original : super.forwardingTarget(for: selector)
        }
        @objc(_webView:runBeforeUnloadConfirmPanelWithMessage:initiatedByFrame:completionHandler:)
        func _webView(_ web: WKWebView, runBeforeUnloadConfirmPanelWithMessage message: String,
                      initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            let selector = NSSelectorFromString("_documentIdentifier")
            guard web === expectedWeb, frame.isMainFrame, frame.responds(to: selector),
                  let uuid = frame.perform(selector)?.takeUnretainedValue() as? NSUUID else {
                Issue.record("Original native beforeunload frame UUID unavailable"); completionHandler(false); return
            }
            nativeDocuments.append(uuid.uuidString)
            browser._webView(web, runBeforeUnloadConfirmPanelWithMessage: message, initiatedByFrame: frame) { [weak self] userLeave in
                guard let self else { completionHandler(false); return }
                guard self.nativeAnswers.isEmpty else { Issue.record("Duplicate native prompt answer"); return }
                self.userAnswers.append(userLeave)
                self.nativeAnswers.append(false)
                completionHandler(false) // The actual original WebKit beforeunload is canceled.
                self.onNativeAnswer(false) // Observation of THAT native decision, never user approval.
            }
        }
        func webViewDidClose(_ web: WKWebView) {
            nativeCloseCallbacks += 1
            original.webViewDidClose(web) // Keep actual adapter behavior even on an unexpected close.
        }
    }

    @Test(arguments: [false, true])
    func originalDocumentSurvivesDirectNativeStayAndLeaveApproval(_ leave: Bool) async throws {
        try await exerciseOriginalDocument(leave: leave, recordLeaveButStayNative: false)
    }
    @Test func actualNativeLeaveIntentWithNativeStayPreservesOriginalUndoAndDocument() async throws {
        try await exerciseOriginalDocument(leave: true, recordLeaveButStayNative: true)
    }
    private func exerciseOriginalDocument(leave: Bool, recordLeaveButStayNative: Bool) async throws {
        _ = NSApplication.shared
        installTraceIfRequested()
        let browser = Browser(windowID: UUID())
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let tab = Tab(configuration: configuration, engine: .webKit, factory: .webKitOnly)
        browser.prepare(tab); browser.lay([tab]); browser.activeID = tab.id
        let web = try #require(tab.page.webKit)
        // This experiment measures native _tryClose + Browser's actual UI
        // callbacks/Asks/Leaving, not Browser's finished-page automation. That
        // pipeline can grant activation by script and offer Developer Mode on
        // .test hosts before our trusted keys. Keep the original UI adapter and
        // its Browser listener, removing only navigation and state callbacks.
        web.navigationDelegate = nil
        web.stateEvents = nil
        try #require(web.events === browser && web.uiDelegate === web.navigationEvents,
                     "Original Browser UI callbacks and private native beforeunload forwarding stay installed")
        let quiet = NSSelectorFromString("_evaluateJavaScript:asAsyncFunction:withSourceURL:withArguments:forceUserGesture:inFrame:inWorld:completionHandler:")
        try #require(web.responds(to: quiet) && ProcessInfo.processInfo.environment["YAB_QUIET_SCRIPTS"] != "0",
                     "Quiet reads need the actual forceUserGesture:false SPI, without its public-API fallback")
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 620, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = web
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer {
            browser.dropAsks(tab)
            Leaving.waits.removeValue(forKey: ObjectIdentifier(web))
            window.orderOut(nil); window.contentView = nil
            tab.close(); browser.letGo()
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
        }
        web.loadHTMLString("""
            <!doctype html><meta charset="utf-8"><title>WK approval document</title>
            <textarea id="draft" autofocus></textarea>
            <script>
            window.originalIdentity = 'original-wk-' + Math.random();
            window.beforeCalls = 0; window.unloadCalls = 0; window.trustedInputs = 0;
            draft.addEventListener('input', e => { if (e.isTrusted) trustedInputs++; });
            addEventListener('beforeunload', e => { beforeCalls++; e.preventDefault(); e.returnValue = ''; });
            addEventListener('unload', () => { unloadCalls++; });
            </script>
            """, baseURL: URL(string: "https://wk-approval.test/")!)
        var ready = false
        for _ in 0..<200 {
            ready = (try? await read(web, "document.readyState === 'complete' && !!document.querySelector('#draft')")) as? Bool == true
            if ready { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(ready, "The original WK document loads")
        let initialActivation = try #require(try await read(web, "navigator.userActivation.hasBeenActive") as? Bool)
        let trustedInputsBefore = try #require(try await read(web, "trustedInputs") as? Int)
        let baseline: [String: Any] = ["leave": leave, "initialActivation": initialActivation,
            "trustedInputs": trustedInputsBefore, "quietSPI": web.responds(to: quiet),
            "quietScriptsEnv": ProcessInfo.processInfo.environment["YAB_QUIET_SCRIPTS"] ?? "unset",
            "navigationAutomation": false, "navigationDelegateDetached": web.navigationDelegate == nil,
            "stateListenerDetached": web.stateEvents == nil, "originalBrowserUI": web.events === browser && web.uiDelegate === web.navigationEvents,
            "earlyCards": tab.asks.map { ["kind": String(describing: $0.kind), "host": $0.host] }]
        print("WK_APPROVAL_BASELINE " + String(decoding: try JSONSerialization.data(withJSONObject: baseline, options: [.sortedKeys]), as: UTF8.self))
        #expect(!initialActivation, "The actual original WK document must be unactivated before native keys")
        #expect(trustedInputsBefore == 0)
        _ = try await read(web, "document.querySelector('#draft').focus()")
        try #require(window.makeFirstResponder(web), "The actual WK view receives native keys")
        for character in "unsaved" {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: String(character), charactersIgnoringModifiers: String(character),
                    isARepeat: false, keyCode: Bench.keyCode(for: character)))
                if type == .keyDown { web.keyDown(with: event) } else { web.keyUp(with: event) }
            }
        }
        var activated = false
        for _ in 0..<200 {
            activated = (try? await read(web, "draft.value === 'unsaved' && trustedInputs > 0 && navigator.userActivation.hasBeenActive")) as? Bool == true
            if activated { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(activated, "Native AppKit input must establish trusted input and sticky activation")
        let identity = try #require(try await read(web, "originalIdentity") as? String)
        let timeOrigin = try #require(try await read(web, "performance.timeOrigin") as? Double)
        let nativeDocument = try await document(web)
        let undoBefore = web.undoManager?.canUndo == true
        try #require(tab.asks.isEmpty, "No earlier card may consume this fixture's native answer")
        var approval: Bool?
        var answers: [Bool] = []
        let expectedNativeDecision = recordLeaveButStayNative ? false : leave
        var observer: NativeIntentObserver?
        if recordLeaveButStayNative {
            try #require(undoBefore, "This experiment needs a real original undo stack")
            observer = NativeIntentObserver(browser: browser, web: web, original: web.navigationEvents) { value in
                approval = value; answers.append(value)
            }
            web.uiDelegate = observer
            // Ask ORIGINAL native WK directly. No Leaving.Wait timeout or
            // synthetic finish can supply this experiment's observed decision.
            let selector = NSSelectorFromString("_tryClose")
            try #require(web.responds(to: selector), "Native _tryClose must exist; no fallback approval")
            typealias NativeTryClose = @convention(c) (AnyObject, Selector) -> Bool
            let originalTryClose = unsafeBitCast(web.method(for: selector), to: NativeTryClose.self)
            try #require(!originalTryClose(web, selector), "Real original listener must take the native asynchronous beforeunload path")
        } else {
            Leaving.ask(web) { approval = $0; answers.append($0) }
        }
        for _ in 0..<200 {
            if tab.asks.contains(where: { if case .leave = $0.kind { return true }; return false }) { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(tab.asks.contains(where: { if case .leave = $0.kind { return true }; return false }),
                     "The original WK handler must present Browser's real PageAsk")
        let card = try #require(tab.asks.first)
        try #require(card.kind == .leave && tab.asks.count == 1 && card.stage == .asking,
                     "The native Leave card must be the actual Browser.answer target")
        let wait = Leaving.waits[ObjectIdentifier(web)]
        if recordLeaveButStayNative {
            #expect(wait == nil, "Direct native observation has no synthetic wait or patience fallback")
        } else {
            let originalWait = try #require(wait, "The original WK close still owns its wait")
            #expect(originalWait.asking && !originalWait.dropped)
        }
        #expect(approval == nil, "No approval before the actual card is answered")
        browser.answer(tab, leave ? .yes(nil) : .no)
        for _ in 0..<200 where approval == nil { try await Task.sleep(for: .milliseconds(25)) }
        // Preserve evidence if native Stay does not resolve. This is a failure,
        // not permission to synthesize the answer or classify it as retained.
        let decision: [String: Any] = ["leave": leave, "answers": answers,
            "waitStillOwned": wait.map { Leaving.waits[ObjectIdentifier(web)] === $0 } ?? false,
            "waitAsking": wait?.asking ?? false, "cardStillPresent": tab.asks.contains { $0.id == card.id }]
        print("WK_APPROVAL_DECISION " + String(decoding: try JSONSerialization.data(withJSONObject: decision, options: [.sortedKeys]), as: UTF8.self))
        try #require(approval == expectedNativeDecision && answers == [expectedNativeDecision], "The actual selected native decision is observed exactly once")
        if let observer {
            #expect(observer.userAnswers == [true] && observer.nativeAnswers == [false])
            #expect(observer.nativeDocuments == [nativeDocument], "Native original beforeunload supplies the exact observed WK document UUID")
            #expect(observer.nativeCloseCallbacks == 0, "Native false cannot clear undo through closePage/webViewDidClose")
        }
        #expect(!tab.gone && tab.builtPage === web, "The fixture never calls Browser.close")
        #expect(tab.asks.isEmpty)
        // The same object alone is insufficient: read the live original document
        // after native WK's decision, without reload or replacing its contents.
        #expect(try await read(web, "originalIdentity") as? String == identity)
        #expect(try await read(web, "performance.timeOrigin") as? Double == timeOrigin)
        #expect(try await read(web, "draft.value") as? String == "unsaved")
        #expect(try await read(web, "beforeCalls") as? Int == 1)
        #expect(try await read(web, "unloadCalls") as? Int == 0)
        let nativeDocumentAfter = try await document(web)
        #expect(nativeDocumentAfter == nativeDocument, "The native WK document UUID must remain original")
        let undoAfter = web.undoManager?.canUndo == true
        var undoChangedDraft = false
        var redoRestoredDraft = false
        if undoAfter {
            web.undoManager?.undo()
            for _ in 0..<120 {
                undoChangedDraft = (try await read(web, "draft.value") as? String) != "unsaved"
                if undoChangedDraft { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            if web.undoManager?.canRedo == true {
                web.undoManager?.redo()
                for _ in 0..<120 {
                    redoRestoredDraft = (try await read(web, "draft.value") as? String) == "unsaved"
                    if redoRestoredDraft { break }
                    try await Task.sleep(for: .milliseconds(25))
                }
            }
        }
        if recordLeaveButStayNative {
            try #require(undoAfter && undoChangedDraft && redoRestoredDraft,
                         "User Leave/native false must preserve real original Undo and Redo, not just DOM text")
        }
        // Observation only: native Leave's UI close callback clears AppKit undo
        // commands in current WebKit. Preserved DOM alone is not reusable switch
        // authority. A missing original undo stack is explicitly observable too.
        let observed: [String: Any] = ["leave": leave, "nativeDocumentBefore": nativeDocument,
            "nativeDocumentAfter": nativeDocumentAfter, "recordLeaveButStayNative": recordLeaveButStayNative,
            "userAnswers": observer?.userAnswers ?? [], "nativeAnswers": observer?.nativeAnswers ?? [],
            "nativeBeforeunloadDocuments": observer?.nativeDocuments ?? [], "undoBefore": undoBefore,
            "undoAfter": undoAfter, "undoChangedDraft": undoChangedDraft,
            "redoRestoredDraft": redoRestoredDraft, "navigationAutomation": false, "acceptedSwitchAuthority": false]
        print("WK_APPROVAL_OBSERVATION " + String(decoding: try JSONSerialization.data(withJSONObject: observed, options: [.sortedKeys]), as: UTF8.self))
    }
}
