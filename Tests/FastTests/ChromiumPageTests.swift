import AppKit
import Testing
import YabCoreClient
@testable import Fast

@Suite(.serialized)
@MainActor
struct ChromiumPageTests {
    @Test func undoReturnsFromNonEditingPagesButKeepsNativeTextEditing() {
        #expect(ChromiumPage.offersCommandToPage("z", typing: false))
        #expect(!ChromiumPage.offersCommandToPage("z", typing: true))
        for letter in ["a", "c", "v", "x", "w", "t", "n", "q"] {
            #expect(!ChromiumPage.offersCommandToPage(letter, typing: false))
        }
        #expect(ChromiumPage.offersCommandToPage("f", typing: false))
    }

    private final class FlippedContent: NSView { override var isFlipped: Bool { true } }

    @Test func forceClickUsesTheStageEdgeAndAgentInputCannotOpenPeek() {
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab)
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        var presses: [CGFloat] = [], points: [CGPoint] = []
        tab.onPress = { _, amount in presses.append(amount) }
        tab.onForceClick = { _, point in points.append(point) }
        let point = CGPoint(x: 120, y: 45)
        page.receivePressure(stage: 1, amount: 0.6, point: point)
        page.receivePressure(stage: 2, amount: 1, point: point)
        page.receivePressure(stage: 2, amount: 1, point: point)
        page.receivePressure(stage: 0, amount: 0, point: point)
        #expect(presses == [0.6, 0])
        #expect(points == [point], "A held Force Click opens only one Peek")
        let acting = PageView.agentActing
        PageView.agentActing = true
        defer { PageView.agentActing = acting }
        page.receivePressure(stage: 1, amount: 0.9, point: point)
        page.receivePressure(stage: 2, amount: 1, point: point)
        page.receivePressure(stage: 0, amount: 0, point: point)
        #expect(presses == [0.6, 0] && points == [point])
        #expect(page.remoteID == nil)
    }

    @Test func hoverBelongsToTheHitPageRatherThanItsTrackingRectangle() {
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        defer { page.removeFromSuperview(); page.retire(call: false, pictureInPicture: false); tab.close(); window.close() }
        window.isReleasedWhenClosed = false
        window.contentView = FlippedContent(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let content = window.contentView!
        page.frame = content.bounds
        content.addSubview(page)
        let overlay = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        content.addSubview(overlay)
        #expect(!page.ownsHover(at: NSPoint(x: 100, y: 350)))
        #expect(page.ownsHover(at: NSPoint(x: 100, y: 50)))
        #expect(page.ownsHover(at: NSPoint(x: 300, y: 100)))
        overlay.isHidden = true
        #expect(page.ownsHover(at: NSPoint(x: 100, y: 100)))
        page.isHidden = true
        #expect(!page.ownsHover(at: NSPoint(x: 100, y: 100)))
        page.receiveTooltip("late page tooltip")
        #expect(page.tipText.isEmpty)
    }

    @Test func ordinaryFactoryStaysWebKitWithoutSwitch() {
        guard ProcessInfo.processInfo.environment["YAB_ENGINE"] == nil else { return }
        #expect(PageEngineFactory.standard.kinds == (PageEngineFactory.chromiumAvailable ? [.webKit, .chromium] : [.webKit]))
        let tab = Tab(shy: true)
        defer { tab.close() }
        #expect(tab.engineKind == (PageEngineFactory.requestedEngine ?? .webKit))
    }

    @Test func constructionAndRetirementNeedNoHelper() {
        _ = NSApplication.shared
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab)
        #expect(page.remoteID == nil)
        #expect(page.contextID == 0)
        #expect(page.engine == .chromium)
        page.retire(call: false, pictureInPicture: false)
        #expect(page.remoteID == nil)
        #expect(page.contextID == 0)
        tab.close()
    }

    @Test func rejectsForeignFramesBeforeLaunchingHelper() async {
        _ = NSApplication.shared
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab)
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        do {
            _ = try await page.evaluate(.expression("42"), in: .page,
                                       frame: PageFrame(isMain: false, url: nil, token: NSObject()), gesture: false)
            Issue.record("A foreign frame was accepted")
        } catch { #expect(error is PageEngineError) }
        #expect(page.remoteID == nil)
    }

    @Test func passiveWorkCannotCreateABlankDocumentAfterHelperLoss() async {
        _ = NSApplication.shared
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab)
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        page.remoteFocused = true
        page.helperExited()
        #expect(page.remoteFocused == nil, "A replacement helper must receive the selected page's focus again")
        do {
            _ = try await page.endpoint()
            Issue.record("Passive work recreated an endpoint after helper loss")
        } catch YabCoreError.disconnected {
            // The loss guard must run before any attempt to launch a helper.
        } catch { Issue.record("Wrong passive recovery error: \(error)") }
        #expect(page.remoteID == nil)
        #expect(page.contextID == 0)
    }

    @Test func aWebKitLinkReferrerDoesNotFailBeforeTheHelperStarts() {
        _ = NSApplication.shared
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab)
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        var request = URLRequest(url: URL(string: "https://navigation.test/next")!)
        request.setValue("https://navigation.test/before", forHTTPHeaderField: "Referer")
        page.navigate(to: request)
        #expect(page.diagnosticFailure == nil)
        #expect(page.remoteID == nil)
    }

    @Test(arguments: [false, true])
    func nativeDocumentCloseClosesItsSmallWindow(kept: Bool) throws {
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        let factory = PageEngineFactory(kinds: [.chromium]) { tab, _ in ChromiumPage(tab: tab) }
        let tab = Tab(shy: true, engine: .chromium, factory: factory)
        tab.restore(url: URL(string: "https://close.example/small")!, title: "Small")
        browser.prepare(tab)
        browser.outside.append(tab)
        let page = try #require(tab.page as? ChromiumPage)
        let remote = "small-close-" + UUID().uuidString
        page.adoptRemote(remote)
        LinkWindow.present(tab, for: browser)
        let link = try #require(LinkWindow.owning(page: page))
        defer {
            link.window.close()
            page.retire(call: false, pictureInPicture: false)
            ChromiumProcess.shared.detach(remote)
            browser.letGo()
        }
        // A foreign endpoint must not close this window.
        page.receive(YabCoreEvent(name: "tab.closed", params: ["tab": .string("foreign")]))
        #expect(LinkWindow.owning(page: page) === link)
        if kept {
            link.keep()
            #expect(browser.tabs.contains(where: { $0 === tab }))
        }
        page.receive(YabCoreEvent(name: "tab.closed", params: ["tab": .string(remote)]))
        #expect(LinkWindow.owning(page: page) == nil, "Native document close must close its Small Window shell")
        #expect(!link.window.isVisible)
        #expect(!browser.outside.contains(where: { $0 === tab }))
        #expect(!browser.tabs.contains(where: { $0 === tab }), "A kept page must also leave its receiving row")
    }

    @Test func nativeCloseWithoutOwnedApprovalCancelsLeaveWaitOnce() {
        _ = NSApplication.shared
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab)
        let remote = "close-" + UUID().uuidString
        page.adoptRemote(remote)
        let id = ObjectIdentifier(page)
        defer {
            Leaving.waits.removeValue(forKey: id)
            page.retire(call: false, pictureInPicture: false)
            ChromiumProcess.shared.detach(remote)
            tab.close()
        }
        var answers: [Bool] = []
        Leaving.waits[id] = Leaving.Wait { answers.append($0) }
        page.receive(YabCoreEvent(name: "tab.closed", params: ["tab": .string("stale-tab")]))
        #expect(answers.isEmpty)
        page.receive(YabCoreEvent(name: "tab.closed", params: ["tab": .string(remote)]))
        #expect(answers == [false], "Endpoint death without an owned native approval cannot authorize the remaining batch")
        #expect(Leaving.waits[id] == nil)
        #expect(page.remoteID == nil)
        page.receive(YabCoreEvent(name: "tab.closed", params: ["tab": .string(remote)]))
        #expect(answers == [false], "A duplicate native close cannot complete the same quit twice")
    }

    @Test func nativeCloseForAnAskedBatchLeavesTabDisposalToTheBatch() throws {
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        let factory = PageEngineFactory(kinds: [.chromium]) { tab, _ in ChromiumPage(tab: tab) }
        let tab = Tab(shy: true, engine: .chromium, factory: factory)
        tab.restore(url: URL(string: "https://close.example/unsent")!, title: "Unsent")
        browser.prepare(tab)
        browser.lay([tab])
        browser.activeID = tab.id
        let page = try #require(tab.page as? ChromiumPage)
        let remote = "batch-" + UUID().uuidString
        page.adoptRemote(remote)
        let id = ObjectIdentifier(page)
        let entry = ChromiumCloseBatch.Entry(tab: tab, page: page, remote: remote)
        entry.request = "batch-request"; entry.document = "original-document"; entry.token = "native-token"
        entry.committing = true
        ChromiumCloseBatch.active[id] = entry
        defer {
            ChromiumCloseBatch.active[id] = nil
            Leaving.waits.removeValue(forKey: id)
            page.retire(call: false, pictureInPicture: false)
            ChromiumProcess.shared.detach(remote)
            browser.letGo()
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
        }
        var answers: [Bool] = []
        Leaving.waits[id] = Leaving.Wait { answers.append($0) }
        let final: [String: JSONValue] = ["tab": .string(remote), "owner": .string(entry.owner),
            "version": .number(1), "request": .string("batch-request"), "document": .string("original-document"),
            "token": .string("native-token"), "final": .bool(true), "phase": .string("closed"), "closed": .bool(true)]
        var foreign = final; foreign["token"] = .string("foreign-token")
        page.receive(YabCoreEvent(name: "tab.closePreflight", params: foreign))
        #expect(!entry.closedConfirmed && answers.isEmpty)
        page.receive(YabCoreEvent(name: "tab.closePreflight", params: final))
        #expect(entry.closedConfirmed && answers.isEmpty, "One native final cannot finish an entire committing batch")
        // The production tab.closed event carries only the authenticated endpoint;
        // owner/request/document/token belong to the separate final receipt above.
        page.receive(YabCoreEvent(name: "tab.closed", params: ["tab": .string(remote)]))
        #expect(answers.isEmpty)
        #expect(page.remoteID == nil)
        #expect(!tab.gone && browser.tabs.contains { $0 === tab },
                "The committing batch owns removal after all exact original documents finish")
        Leaving.finish(page, true) // Controller-order fixture: the aggregate batch now completed.
        #expect(answers == [true])
        Leaving.finish(page, true)
        #expect(answers == [true], "An aggregate completion resolves its wait once")
    }
}
