import Network
import XCTest

/// What a page may do with a person's tap, touched as a person would, over
/// three owned sites on loopback: 127.0.0.1 is the page, localhost the frame
/// on it, [::1] the third site an advertisement wants to reach. Which paths
/// the third site was asked for tells what got through.
final class PageWindowsUITests: XCTestCase {
    private var site: PageWindowsSite!
    private var folder: URL!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        folder = URL(fileURLWithPath: "/tmp/yab-page-windows-\(UUID().uuidString)")
        site = try PageWindowsSite()
        let ready = expectation(description: "page windows site ready")
        site.ready = { ready.fulfill() }
        site.start()
        wait(for: [ready], timeout: 10)
    }

    override func tearDownWithError() throws {
        app?.terminate()
        site?.stop()
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - refused

    func testOneTapOpensOneWindow() throws {
        launch("/page", shows: "Windows page")
        let before = todayIDs().count
        tap("Two windows")
        XCTAssertTrue(wait { self.site.asked.contains("/first") }, "the first window opened")
        settle()
        XCTAssertFalse(site.asked.contains("/second"), "asked for \(site.asked)")
        XCTAssertEqual(todayIDs().count, before + 1)
    }

    func testAnotherSitesFrameCannotOpenAThirdSite() throws {
        launch("/framed", shows: "Framed page")
        let before = todayIDs().count
        tap("Frame window")
        settle()
        XCTAssertFalse(site.asked.contains("/ad"), "asked for \(site.asked)")
        XCTAssertEqual(todayIDs().count, before)
    }

    func testAnotherSitesFrameCannotSendThePageToAThirdSite() throws {
        launch("/framed", shows: "Framed page")
        let id = try XCTUnwrap(savedTab()?["id"] as? String)
        tap("Frame redirect")
        settle()
        XCTAssertFalse(site.asked.contains("/ad"), "asked for \(site.asked)")
        XCTAssertEqual(savedTab()?["id"] as? String, id)
        XCTAssertEqual(savedTab()?["url"] as? String, site.url("/framed").absoluteString)
    }

    func testThePageBehindANewWindowStaysPut() throws {
        launch("/page", shows: "Windows page")
        tap("Window and redirect")
        XCTAssertTrue(wait { self.site.asked.contains("/first") }, "the window opened")
        settle()
        XCTAssertFalse(site.asked.contains("/ad"), "asked for \(site.asked)")
        XCTAssertEqual(saved(path: "/page"), 1, "the opener kept its page")
    }

    func testThePageBehindANewWindowStaysPutLater() throws {
        launch("/page", shows: "Windows page")
        tap("Window, then a late redirect")
        XCTAssertTrue(wait { self.site.asked.contains("/first") }, "the window opened")
        settle(for: 3.5)
        XCTAssertFalse(site.asked.contains("/ad"), "asked for \(site.asked)")
        XCTAssertEqual(saved(path: "/page"), 1, "the opener kept its page")
    }

    // MARK: - still works

    func testOneWindowFromATapOpens() throws {
        launch("/page", shows: "Windows page")
        let before = todayIDs().count
        tap("One window")
        XCTAssertTrue(wait { self.site.asked.contains("/first") })
        XCTAssertTrue(wait { self.todayIDs().count == before + 1 })
    }

    func testAFrameOpensItsOwnSite() throws {
        launch("/framed", shows: "Framed page")
        let before = todayIDs().count
        tap("Frame sign in")
        XCTAssertTrue(wait { self.site.asked.contains("/sign-in") }, "asked for \(site.asked)")
        XCTAssertTrue(wait { self.todayIDs().count == before + 1 })
    }

    func testAFramesEmptyWindowFillsItself() throws {
        launch("/framed", shows: "Framed page")
        let before = todayIDs().count
        tap("Frame blank window")
        XCTAssertTrue(wait { self.site.asked.contains("/checkout") }, "asked for \(site.asked)")
        XCTAssertTrue(wait { self.todayIDs().count == before + 1 })
    }

    func testAFramesLinkOpensAnywhere() throws {
        launch("/framed", shows: "Framed page")
        let before = todayIDs().count
        let link = app.webViews.firstMatch.links["Frame link"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(wait { self.site.asked.contains("/linked") }, "asked for \(site.asked)")
        XCTAssertTrue(wait { self.todayIDs().count == before + 1 })
    }

    func testAPageMayStillGoElsewhereOnItsOwn() throws {
        launch("/page", shows: "Windows page")
        tap("Late redirect")
        XCTAssertTrue(wait { self.site.asked.contains("/elsewhere") }, "asked for \(site.asked)")
    }

    // MARK: - helpers

    private func launch(_ path: String, shows text: String) {
        app = XCUIApplication()
        app.launchArguments = ["-YabProfileDirectory", folder.path, "-YabURL", site.url(path).absoluteString, "-YabNoAnim", "YES"]
        app.launchEnvironment = ["YAB_TEST": "1", "YAB_HAPTICS_SILENT": "1"]
        app.terminate()
        app.launch()
        let notNow = app.buttons["welcome.skip"]
        let input = app.textFields["field.input"]
        XCTAssertTrue(notNow.waitForExistence(timeout: 15))
        app.passWelcome()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 6, dy: window.frame.height * 0.2)).tap()
        XCTAssertTrue(wait { !input.exists && !self.app.alerts["welcome"].exists })
        XCTAssertTrue(app.webViews.staticTexts[text].waitForExistence(timeout: 15))
        XCTAssertTrue(wait { self.savedTab()?["url"] as? String == self.site.url(path).absoluteString })
    }

    /// A finger on the button, wherever on the page or in a frame it is.
    private func tap(_ label: String) {
        let button = app.webViews.firstMatch.buttons[label]
        XCTAssertTrue(button.waitForExistence(timeout: 10), label)
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    /// Long enough for anything a tap set off to have reached the site.
    private func settle(for seconds: TimeInterval = 2) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func wait(_ condition: () -> Bool) -> Bool {
        let until = Date().addingTimeInterval(10)
        while Date() < until {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private func profile() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("profile.json"))) as? [String: Any])
    }

    private func tabs() -> [[String: Any]] {
        guard let profile = try? profile(), let spaces = profile["spaces"] as? [[String: Any]] else { return [] }
        return spaces.flatMap { $0["today"] as? [[String: Any]] ?? [] }
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

    private func todayIDs() -> [String] { tabs().compactMap { $0["id"] as? String } }

    /// How many saved tabs stand at this page of the first site.
    private func saved(path: String) -> Int {
        tabs().filter { $0["url"] as? String == site.url(path).absoluteString }.count
    }
}

final class PageWindowsSite: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "yab.page-windows-site")
    private var connections: [NWConnection] = []
    private var paths: [String] = []
    var ready: (() -> Void)?

    init() throws { listener = try NWListener(using: .tcp) }

    private var port: UInt16 { listener.port!.rawValue }
    private var frame: String { "http://localhost:\(port)" }
    private var third: String { "http://[::1]:\(port)" }
    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    /// Every path asked for so far, on any of the three sites.
    var asked: [String] { queue.sync { paths } }

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
            let path = String(target.split(separator: "?").first ?? "/")
            self.paths.append(path)
            let body = Data(self.html(path).utf8)
            let header = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
            connection.send(content: header + body, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
        }
    }

    private func button(_ label: String, _ script: String) -> String {
        "<button onclick=\"\(script)\">\(label)</button>"
    }

    private func html(_ path: String) -> String {
        let body: String
        switch path {
        case "/page":
            body = "<h1>Windows page</h1>"
                + button("One window", "window.open('/first')")
                + button("Two windows", "window.open('/first');window.open('/second')")
                + button("Window and redirect", "window.open('/first');location='\(third)/ad'")
                + button("Window, then a late redirect", "window.open('/first');setTimeout(function(){location='\(third)/ad'},2000)")
                + button("Late redirect", "setTimeout(function(){location='\(third)/elsewhere'},1500)")
        case "/framed":
            body = "<h1>Framed page</h1><iframe src='\(frame)/frame' style='width:100%;height:520px;border:0'></iframe>"
        case "/frame":
            body = button("Frame window", "window.open('\(third)/ad')")
                + button("Frame redirect", "top.location='\(third)/ad'")
                + button("Frame sign in", "window.open('\(frame)/sign-in')")
                + button("Frame blank window", "var w=window.open('');w.location='\(third)/checkout'")
                + "<a href='\(third)/linked' target='_blank'>Frame link</a>"
        default:
            body = "<h1>Elsewhere</h1>"
        }
        return "<!doctype html><html><head><meta name='viewport' content='width=device-width,initial-scale=1'>"
            + "<style>body{font:18px -apple-system;margin:0;padding:70px 16px 40px;background:#eef3ff;color:#111}"
            + "iframe body{padding:0}button,a{display:block;width:100%;margin:6px 0;padding:12px 0;font-size:18px;text-align:center}</style></head>"
            + "<body>\(body)</body></html>"
    }
}
