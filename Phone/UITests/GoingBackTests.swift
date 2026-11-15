import Network
import XCTest

/// Going back, touched as a person would, over an owned loopback site: the
/// first page of a tab a link opened pulled back to its opener, quietly, ‹
/// held for the tab's pages and All History, ‹ dimmed with nothing behind;
/// and a close from the spaces with no toast, in a test world.
/// WebKit's own swipe through a tab's pages has no test here: XCTest's
/// synthesized finger takes it to the end and it settles back, in Safari
/// over the same pages as in Yab (farm jobs 9dc6213ce1bb43ca, 15ba9fd941614bbb).
final class GoingBackTests: XCTestCase {
    private var site: GoingBackSite!
    private var folder: URL!
    private var journal: URL!
    private var swipeJournal: URL!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        folder = URL(fileURLWithPath: "/tmp/yab-going-back-\(UUID().uuidString)")
        journal = URL(fileURLWithPath: "/tmp").appendingPathComponent("yab-haptics-\(UUID().uuidString).log")
        swipeJournal = URL(fileURLWithPath: "/tmp").appendingPathComponent("yab-swipes-\(UUID().uuidString).log")
        site = try GoingBackSite()
        let ready = expectation(description: "going back site ready")
        site.ready = { ready.fulfill() }
        site.start()
        wait(for: [ready], timeout: 10)
    }

    override func tearDownWithError() throws {
        app?.terminate()
        site?.stop()
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.removeItem(at: journal)
        try? FileManager.default.removeItem(at: swipeJournal)
    }

    // MARK: - a tab a link opened

    func testAFirstPageGoesBackToItsOpenerQuietly() throws {
        launch("/one", shows: "Page one")
        let page = app.webViews.firstMatch
        let one = site.url("/one").absoluteString, child = site.url("/child").absoluteString
        let childNext = site.url("/child-next").absoluteString
        let openerID = try XCTUnwrap(savedTab()?["id"] as? String)
        follow(page.links["Open the child in a new tab"])
        XCTAssertTrue(page.staticTexts["Child page"].waitForExistence(timeout: 15))
        XCTAssertTrue(wait { self.savedTab()?["url"] as? String == child })
        let childID = try XCTUnwrap(savedTab()?["id"] as? String)
        XCTAssertNotEqual(childID, openerID, "the link opened a tab of its own")
        let back = app.buttons["chrome.back"]
        XCTAssertTrue(wait { back.isEnabled }, "at its first page ‹ goes to the opener")

        // A page further in, ‹ goes back through the tab's own pages first.
        follow(page.links["Next child page"])
        XCTAssertTrue(page.staticTexts["Child next"].waitForExistence(timeout: 15))
        XCTAssertTrue(wait { self.savedTab()?["url"] as? String == childNext })
        back.tap()
        XCTAssertTrue(page.staticTexts["Child page"].waitForExistence(timeout: 10))
        XCTAssertTrue(wait { self.savedTab()?["id"] as? String == childID && self.savedTab()?["url"] as? String == child })
        XCTAssertTrue(wait { (try? self.navigation(childID)) == [child, childNext, "index=0"] })
        _ = try navigation(childID)

        // At its first page the left edge pulls it back to its opener.
        edgeSwipe()
        XCTAssertTrue(wait { self.savedTab()?["id"] as? String == openerID && self.savedTab()?["url"] as? String == one })
        XCTAssertTrue(page.staticTexts["Page one"].waitForExistence(timeout: 10))
        XCTAssertTrue(wait { !self.todayIDs().contains(childID) }, "the tab closed")
        felt("soft back to opener")
        XCTAssertFalse(app.buttons["chrome.toast.undo"].waitForExistence(timeout: 1), "a close says nothing")
        XCTAssertFalse(app.staticTexts["Closed 127.0.0.1"].exists)
        record("Closed quietly after the pull")

        // ‹ does what the edge does.
        follow(page.links["Open the child in a new tab"])
        XCTAssertTrue(page.staticTexts["Child page"].waitForExistence(timeout: 15))
        let again = try XCTUnwrap(savedTab()?["id"] as? String)
        XCTAssertTrue(wait { back.isEnabled })
        back.tap()
        XCTAssertTrue(wait { self.savedTab()?["id"] as? String == openerID && !self.todayIDs().contains(again) })
        XCTAssertFalse(app.buttons["chrome.toast.undo"].exists)
        record("Closed quietly after ‹")
    }

    // MARK: - a swipe from anywhere (#324)

    func testASwipeAcrossThePageGoesBackAndForwardButCarouselsKeepTheirs() throws {
        launch("/one", shows: "Page one")
        let page = app.webViews.firstMatch
        let one = site.url("/one").absoluteString, carousel = site.url("/carousel").absoluteString
        follow(page.links["To the carousel"])
        XCTAssertTrue(page.staticTexts["Strip at start"].waitForExistence(timeout: 15))
        XCTAssertTrue(wait { self.savedTab()?["url"] as? String == carousel })
        let id = try XCTUnwrap(savedTab()?["id"] as? String)
        record("Carousel page")

        // The native scroller moves both ways; at its start nothing goes back.
        let card = page.staticTexts["Card 1"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        swipe(at: card, by: -220)
        XCTAssertTrue(page.staticTexts["Strip moved"].waitForExistence(timeout: 5), "the strip scrolled")
        swipe(at: card, by: 200, from: 120)
        XCTAssertTrue(page.staticTexts["Strip at start"].waitForExistence(timeout: 5), "a right swipe scrolls the strip back, not the page")
        XCTAssertEqual(savedTab()?["url"] as? String, carousel)

        // The script's carousel keeps sideways moves (touch-action: pan-y).
        let slide = page.staticTexts["Slide 2"]
        XCTAssertTrue(slide.exists)
        swipe(at: slide, by: 200, from: 80)
        XCTAssertTrue(page.staticTexts["Slide 1"].waitForExistence(timeout: 5), "the carousel took the swipe")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(savedTab()?["url"] as? String, carousel, "and the page stayed")
        XCTAssertFalse(swipes.contains { $0.hasPrefix("began") }, "no swipe began over the scrollers: \(swipes)")
        record("Carousels kept their swipes")

        // Across the page's heading, away from the edges, WebKit's swipe back
        // begins. A simulated finger can't finish WebKit's swipe (it tracks and
        // settles back, from the edge too; AGENTS.md), so the journal tells.
        let heading = page.staticTexts["Carousel"]
        XCTAssertTrue(heading.exists)
        swipe(at: heading, by: 230, from: 90)
        XCTAssertTrue(wait { self.swipes.contains { $0.hasPrefix("began back") } }, "a swipe right mid-page begins WebKit's swipe back: \(swipes)")
        record("Back from mid-page")

        // With a page ahead, a swipe left mid-page begins the swipe forward.
        app.buttons["chrome.back"].tap()
        XCTAssertTrue(page.staticTexts["Page one"].waitForExistence(timeout: 10))
        XCTAssertTrue(wait { self.savedTab()?["id"] as? String == id && self.savedTab()?["url"] as? String == one })
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        swipe(at: page.staticTexts["Page one"], by: -230, from: 320)
        XCTAssertTrue(wait { self.swipes.contains { $0.hasPrefix("began forward") } }, "a swipe left mid-page begins WebKit's swipe forward: \(swipes)")
        record("Forward from mid-page")

    }

    /// A real <video controls>: a drag along its progress bar scrubs and no
    /// back swipe begins; across the page above it, one still does.
    func testDraggingAVideosProgressBarScrubsButMidPageStillGoesBack() throws {
        launch("/one", shows: "Page one")
        let page = app.webViews.firstMatch
        let video = site.url("/video").absoluteString
        follow(page.links["To the video"])
        XCTAssertTrue(page.staticTexts["Video"].waitForExistence(timeout: 15))
        XCTAssertTrue(wait { self.savedTab()?["url"] as? String == video })
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        record("Video page")

        // The clip sits 45% down, 220 points tall; its bar is along the bottom.
        let window = app.windows.firstMatch
        let barY = page.frame.minY + page.frame.height * 0.45 + 220 - 24
        let start = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 110, dy: barY))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 200, dy: 0)),
                    withVelocity: .fast, thenHoldForDuration: 0)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertFalse(swipes.contains { $0.hasPrefix("began") }, "no back swipe began on the video's bar: \(swipes)")
        XCTAssertEqual(savedTab()?["url"] as? String, video, "and the page stayed")
        record("Scrubbed the video")

        let heading = page.staticTexts["Video"]
        swipe(at: heading, by: 230, from: 90)
        XCTAssertTrue(wait { self.swipes.contains { $0.hasPrefix("began back") } }, "a swipe mid-page still begins the swipe back: \(swipes)")
    }

    /// The content swipes that began and ended since launch: "began back at 120"…
    private var swipes: [String] {
        guard let text = try? String(contentsOf: swipeJournal, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    /// Hold still after crossing half the page, then release without a flick.
    func testSlowBackAndForwardPastHalfCompleteAfterHoldingStill() throws {
        launch("/one", shows: "Page one")
        let page = app.webViews.firstMatch
        follow(page.links["To page two"])
        XCTAssertTrue(page.staticTexts["Page two"].waitForExistence(timeout: 15))
        let one = site.url("/one").absoluteString, two = site.url("/two").absoluteString
        XCTAssertTrue(wait { self.savedTab()?["url"] as? String == two })

        func drag(_ from: CGFloat, _ to: CGFloat) {
            let y = app.frame.height * 0.35
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: from, dy: y))
                .press(forDuration: 0.1,
                       thenDragTo: app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: to, dy: y)),
                       withVelocity: .slow, thenHoldForDuration: 0.8)
        }
        let width = app.frame.width
        drag(5, width * 0.78)
        XCTAssertTrue(wait { self.savedTab()?["url"] as? String == one }, "a slow edge swipe past half must go back after a stationary release: \(swipes)")
        record("Slow back completed")
        drag(width - 5, width * 0.22)
        XCTAssertTrue(wait { self.savedTab()?["url"] as? String == two }, "a slow edge swipe past half must go forward after a stationary release")
        record("Slow forward completed")
        drag(width * 0.1, width * 0.8)
        XCTAssertTrue(wait { self.savedTab()?["url"] as? String == one }, "the content swipe must finish too")
        record("Slow content back completed")
    }

    /// A finger put down on `element` (at `from` points from the screen's
    /// left, else its middle) and thrown `by` points sideways.
    private func swipe(at element: XCUIElement, by distance: CGFloat, from x: CGFloat? = nil) {
        let window = app.windows.firstMatch
        let point = CGVector(dx: x ?? element.frame.midX, dy: element.frame.midY)
        let start = window.coordinate(withNormalizedOffset: .zero).withOffset(point)
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: distance, dy: 0)),
                    withVelocity: .fast, thenHoldForDuration: 0)
    }

    // MARK: - ‹ held

    func testHoldingBackListsTheTabsPagesNewestFirstAndGoesToOne() throws {
        launch("/one", shows: "Page one")
        let page = app.webViews.firstMatch
        let one = site.url("/one").absoluteString, two = site.url("/two").absoluteString
        let three = site.url("/three").absoluteString
        follow(page.links["To page two"])
        XCTAssertTrue(page.staticTexts["Page two"].waitForExistence(timeout: 15))
        follow(page.links["To page three"])
        XCTAssertTrue(page.staticTexts["Page three"].waitForExistence(timeout: 15))
        XCTAssertTrue(wait { self.savedTab()?["url"] as? String == three })
        let id = try XCTUnwrap(savedTab()?["id"] as? String)
        let back = app.buttons["chrome.back"]
        XCTAssertTrue(wait { back.isEnabled && back.isHittable })
        back.press(forDuration: 0.8)
        let newest = app.buttons["chrome.back.history.1"], oldest = app.buttons["chrome.back.history.2"]
        XCTAssertTrue(newest.waitForExistence(timeout: 5), "holding ‹ shows the tab's pages")
        XCTAssertTrue(oldest.exists)
        XCTAssertTrue(newest.label.contains("Page two"), newest.label)
        XCTAssertTrue(oldest.label.contains("Page one"), oldest.label)
        XCTAssertLessThan(newest.frame.minY, oldest.frame.minY, "the nearest page on top")
        XCTAssertFalse(app.buttons["chrome.back.history.3"].exists)
        let all = app.buttons["chrome.back.history.all"]
        XCTAssertTrue(all.exists, "the menu ends in All History")
        XCTAssertEqual(all.label, "All History")
        XCTAssertGreaterThan(all.frame.minY, oldest.frame.maxY, "under the pages, past a line")
        XCTAssertTrue(page.staticTexts["Page three"].exists, "a hold doesn't go back")
        record("Back held: the tab's pages")
        menuShot(app, "back-history")
        all.tap()
        XCTAssertTrue(element("history.page").waitForExistence(timeout: 5), "All History opens History")
        XCTAssertEqual(savedTab()?["url"] as? String, three, "and goes nowhere in the tab")
        app.buttons["settings.close"].tap()
        XCTAssertTrue(wait { !self.element("history.page").exists && back.isHittable })
        back.press(forDuration: 0.8)
        XCTAssertTrue(oldest.waitForExistence(timeout: 5))
        oldest.tap()
        XCTAssertTrue(page.staticTexts["Page one"].waitForExistence(timeout: 10))
        XCTAssertTrue(wait { self.savedTab()?["url"] as? String == one })
        XCTAssertTrue(wait { (try? self.navigation(id)) == [one, two, three, "index=0"] }, "two pages back at once")
    }

    // MARK: - nothing behind

    func testWithNothingBehindBackIsDimmedAndThePageSpringsBack() throws {
        launch("/three", shows: "Page three")
        let page = app.webViews.firstMatch
        let three = site.url("/three").absoluteString
        XCTAssertTrue(wait { self.savedTab()?["url"] as? String == three })
        let id = try XCTUnwrap(savedTab()?["id"] as? String)
        let tabs = todayIDs()
        let back = app.buttons["chrome.back"]
        XCTAssertTrue(back.exists)
        XCTAssertFalse(back.isEnabled, "no Back and no opener: ‹ dimmed and still")
        edgeSwipe(by: 170, slowly: true)
        XCTAssertTrue(page.staticTexts["Page three"].waitForExistence(timeout: 5))
        XCTAssertEqual(savedTab()?["id"] as? String, id)
        XCTAssertEqual(savedTab()?["url"] as? String, three)
        XCTAssertEqual(todayIDs(), tabs, "nothing closed")
        XCTAssertFalse(app.buttons["chrome.toast.undo"].exists)
        follow(page.links["To page one"])
        XCTAssertTrue(page.staticTexts["Page one"].waitForExistence(timeout: 15))
        XCTAssertTrue(wait { back.isEnabled }, "a page later ‹ lights up")
    }

    // MARK: - the column's close

    func testClosingATabFromTheSpacesSaysNothing() {
        app = XCUIApplication()
        app.launchArguments = ["-YabWorld", "mira", "-YabNoAnim", "YES"]
        app.launchEnvironment["YAB_HAPTICS_SILENT"] = "1"
        app.launch()
        XCTAssertTrue(element("chrome.plate").waitForExistence(timeout: 20))
        // Up from the plate: the spaces, each tab a row; held, the column's menu.
        SpacesGesture.open(in: app)
        let row = element("newtab.tab.work-hn")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(wait { row.isHittable })
        row.press(forDuration: 0.8)
        let close = app.buttons["Close Tab"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(wait { !self.element("newtab.tab.work-hn").exists })
        XCTAssertFalse(app.buttons["chrome.toast.undo"].waitForExistence(timeout: 1), "a close says nothing")
        XCTAssertFalse(app.staticTexts["Closed news.ycombinator.com"].exists)
        record("Spaces close, quietly")
    }

    // MARK: - helpers

    private func launch(_ path: String, shows text: String) {
        app = XCUIApplication()
        app.launchArguments = ["-YabProfileDirectory", folder.path, "-YabURL", site.url(path).absoluteString, "-YabNoAnim", "NO"]
        app.launchEnvironment = ["YAB_TEST": "1", "YAB_HAPTICS_SILENT": "1", "YAB_HAPTICS_JOURNAL": journal.path,
                                 "YAB_SWIPES_JOURNAL": swipeJournal.path]
        app.terminate()
        app.launch()
        // A fresh profile is a first run: the welcome stands over the page.
        let notNow = app.buttons["welcome.start"]
        let input = app.textFields["field.input"]
        XCTAssertTrue(notNow.waitForExistence(timeout: 15))
        app.passWelcome()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        outside().tap()
        XCTAssertTrue(wait { !input.exists && !self.app.alerts["welcome"].exists })
        XCTAssertTrue(app.webViews.staticTexts[text].waitForExistence(timeout: 15))
    }

    /// A finger from the screen's left edge across the page's middle: let go
    /// moving fast past half the screen, or slowly, held still at the end.
    private func edgeSwipe(by distance: CGFloat = 280, slowly: Bool = false) {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 2, dy: window.frame.height * 0.45))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: distance, dy: 0)),
                    withVelocity: slowly ? .slow : .fast, thenHoldForDuration: slowly ? 0.05 : 0)
    }

    /// A link followed by a finger at its middle: a page a link opened in a
    /// tab of its own answers WebKit's accessibility hit test with nothing,
    /// so XCTest would call its links unreachable.
    private func follow(_ link: XCUIElement) {
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func outside() -> XCUICoordinate {
        app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 6, dy: app.windows.firstMatch.frame.height * 0.2))
    }

    private func wait(_ condition: () -> Bool) -> Bool {
        let until = Date().addingTimeInterval(10)
        while Date() < until {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private func record(_ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }

    /// What the finger felt since launch: "soft back to opener"…
    private var haptics: [String] {
        guard let text = try? String(contentsOf: journal, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map { line in line.split(separator: " ", maxSplits: 1).dropFirst().joined() }
    }

    private func felt(_ haptic: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(wait { self.haptics.contains(haptic) }, "felt \(haptics), not \(haptic)", file: file, line: line)
    }

    private func profile() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("profile.json"))) as? [String: Any])
    }

    private func savedTab() -> [String: Any]? {
        guard let profile = try? profile(), let spaces = profile["spaces"] as? [[String: Any]] else { return nil }
        let id = profile["spaceID"] as? String
        for space in spaces where id == nil || space["id"] as? String == id {
            guard let current = space["current"] as? String, let tabs = space["today"] as? [[String: Any]] else { continue }
            if let tab = tabs.first(where: { $0["id"] as? String == current }) { return tab }
        }
        return nil
    }

    private func todayIDs() -> [String] {
        guard let profile = try? profile(), let spaces = profile["spaces"] as? [[String: Any]] else { return [] }
        return spaces.flatMap { ($0["today"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String } }
    }

    private func navigation(_ id: String) throws -> [String] {
        let all = try XCTUnwrap(try profile()["navigation"] as? [String: Any])
        let state = try XCTUnwrap(all[id] as? [String: Any])
        let entries = try XCTUnwrap(state["entries"] as? [[String: Any]])
        let index = try XCTUnwrap(state["index"] as? Int)
        return entries.compactMap { $0["url"] as? String } + ["index=\(index)"]
    }
}

/// Five short pages on 127.0.0.1: three in a row, and a page opened in a
/// tab of its own by a target=_blank link, with one page after it.
final class GoingBackSite: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "yab.going-back-site")
    private var connections: [NWConnection] = []
    var ready: (() -> Void)?
    var responseBody: ((String) -> String)?

    init() throws {
        let options = NWParameters.tcp
        options.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: options)
    }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)\(path)")! }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in if case .ready = state { self?.ready?() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.receive(connection, bytes: Data())
        }
        listener.start(queue: queue)
    }

    func stop() {
        queue.sync { connections.forEach { $0.cancel() }; connections.removeAll(); listener.cancel() }
    }

    private func receive(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] chunk, _, done, error in
            guard let self else { connection.cancel(); return }
            var all = bytes
            if let chunk { all.append(chunk) }
            guard all.count <= 65_536 else { connection.cancel(); return }
            guard all.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if done || error != nil { connection.cancel() } else { self.receive(connection, bytes: all) }
                return
            }
            let target = String(decoding: all, as: UTF8.self).components(separatedBy: "\r\n").first?
                .split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let path = URL(string: target, relativeTo: self.url("/"))?.path ?? "/"
            let body = Data((self.responseBody?(path) ?? Self.html(path)).utf8)
            let header = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
            connection.send(content: header + body, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
        }
    }

    /// A native scroller (overflow-x) and a script's carousel that keeps
    /// sideways moves for itself (touch-action: pan-y, pointer events, as
    /// Swiper's), each saying where it stands.
    private static let carousel = "<div id='strip' style='overflow-x:auto;white-space:nowrap;height:150px;margin:8px 0'>"
        + (1...6).map { "<div style='display:inline-block;width:260px;height:130px;margin-right:12px;background:#c9d6ff;border-radius:16px;font-size:22px;padding:12px;box-sizing:border-box'>Card \($0)</div>" }.joined()
        + "</div><p id='stripAt'>Strip at start</p>"
        + "<div id='slides' style='touch-action:pan-y;height:150px;background:#ffd9c9;border-radius:16px;font-size:26px;padding:20px;box-sizing:border-box'>Slide 2</div>"
        + "<script>var strip=document.getElementById('strip'),at=document.getElementById('stripAt');"
        + "strip.addEventListener('scroll',function(){at.textContent=strip.scrollLeft>4?'Strip moved':'Strip at start'});"
        + "var slides=document.getElementById('slides'),n=2,x0=null;"
        + "slides.addEventListener('pointerdown',function(e){x0=e.clientX});"
        + "slides.addEventListener('pointerup',function(e){if(x0===null)return;var dx=e.clientX-x0;x0=null;"
        + "if(dx>40)n=Math.max(1,n-1);else if(dx<-40)n=Math.min(3,n+1);slides.textContent='Slide '+n});</script>"

    private static func html(_ path: String) -> String {
        let pages: [String: (title: String, links: String)] = [
            "/one": ("Page one", "<a href='/two'>To page two</a><a href='/child' target='_blank'>Open the child in a new tab</a>"
                + "<a href='/carousel'>To the carousel</a><a href='/video'>To the video</a>"),
            "/carousel": ("Carousel", carousel),
            "/video": ("Video", "<video id='clip' controls playsinline muted preload='auto' style='position:fixed;left:0;right:0;top:45%;width:100%;height:220px;background:#000' "
                + "src='data:video/mp4;base64,\(GoingBackVideo.base64)'></video>"),
            "/two": ("Page two", "<a href='/three'>To page three</a>"),
            "/three": ("Page three", "<a href='/one'>To page one</a>"),
            "/child": ("Child page", "<a href='/child-next'>Next child page</a>"),
            "/child-next": ("Child next", ""),
        ]
        let page = pages[path] ?? ("Not here", "")
        let prose = (1...12).map { "<p>Paragraph \($0) of \(page.title), so the page scrolls under the plate.</p>" }.joined()
        return "<!doctype html><html><head><meta name='viewport' content='width=device-width,initial-scale=1'>"
            + "<title>\(page.title)</title><style>body{font:18px -apple-system;margin:0;padding:70px 16px 160px;background:#eef3ff;color:#111}"
            + "a{display:block;padding:12px 0;font-size:20px}p{line-height:1.5}</style></head>"
            + "<body><h1>\(page.title)</h1>\(page.links)\(prose)</body></html>"
    }
}
