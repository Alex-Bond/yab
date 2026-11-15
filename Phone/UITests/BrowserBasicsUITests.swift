import Network
import XCTest

/// The browser basics as a finger uses them, pages from an owned profile and
/// a loopback site, never the internet.
final class BrowserBasicsUITests: XCTestCase {
    private var site: LinksSite!
    private var folder: URL!
    private var journal: URL!
    private var haptics: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        folder = URL(fileURLWithPath: "/private/tmp/yab-browser-basics-\(UUID().uuidString)", isDirectory: true)
        journal = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("yab-open-\(UUID().uuidString).log")
        haptics = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("yab-haptics-\(UUID().uuidString).log")
        site = try LinksSite()
        let ready = expectation(description: "owned links site ready")
        site.start { result in
            if case let .failure(error) = result { XCTFail("Owned listener failed: \(error)") }
            ready.fulfill()
        }
        wait(for: [ready], timeout: 10)
    }

    override func tearDownWithError() throws {
        XCUIApplication().terminate()
        site?.stop()
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.removeItem(at: journal)
        try? FileManager.default.removeItem(at: haptics)
    }

    /// A tapped call link, or a button whose script goes to tel:, is handed
    /// to iOS (YAB_OPEN_JOURNAL records it instead of leaving the app); a page
    /// that sends itself to mailto: well after the last touch is not followed.
    func testATappedCallIsHandedToIOSAndAPageGoingThereByItselfIsNot() throws {
        let app = try launch()
        // A touch arms a redirect that comes well after it: no touch then.
        let arm = app.buttons["Arm redirect"]
        XCTAssertTrue(arm.isHittable)
        arm.tap()
        XCTAssertTrue(app.staticTexts["Armed"].waitForExistence(timeout: 5))
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        XCTAssertEqual(opened, [], "a page sending itself to mailto: with no touch is not followed")

        let call = app.links["Call Anna"]
        XCTAssertTrue(call.isHittable)
        call.tap()
        XCTAssertTrue(wait { self.opened == ["tel:+15551234567"] }, "journal: \(opened)")

        let script = app.buttons["Call by script"]
        XCTAssertTrue(script.isHittable)
        script.tap()
        XCTAssertTrue(wait { self.opened == ["tel:+15551234567", "tel:+15550000000"] }, "journal: \(opened)")
        // The page is where it was, no failure over it.
        XCTAssertTrue(document(app).exists)
        XCTAssertTrue(arm.isHittable)
        record(app, "links page after its calls went to iOS")
    }

    /// A held link offers Open in New Tab and Open in Background Tab over the
    /// system's own actions; the background one leaves the page in front.
    func testAHeldLinkOffersNewAndBackgroundTabsAndTheBackgroundOneLeavesThePageInFront() throws {
        let app = try launch()
        let link = app.links["Second page"]
        XCTAssertTrue(link.isHittable)
        let before = try today().count
        link.press(forDuration: 1.2)
        let background = app.buttons["Open in Background Tab"]
        let arrived = background.waitForExistence(timeout: 8)
        if !arrived { record(app, "held link menu missing") }
        XCTAssertTrue(arrived)
        XCTAssertTrue(app.buttons["Open in New Tab"].exists)
        XCTAssertTrue(app.buttons["Copy Link"].exists || app.buttons["Share…"].exists, "the system's own actions stay")
        record(app, "held link menu")
        menuShot(app, "link")
        background.tap()
        // Its haptic is what it did, whatever XCTest's idle wait made of the
        // toast's 2.2 s (the toast itself is a unit test's).
        XCTAssertTrue(wait { self.felt.contains("soft background tab") }, "haptics: \(felt)")
        record(app, "opened in background")
        XCTAssertTrue(document(app).exists, "the page stays in front")
        XCTAssertTrue(wait { (try? self.today().count) == before + 1 })
        let today = try today(), page = try current()
        XCTAssertEqual(page["url"] as? String, site.url("/links").absoluteString)
        let at = try XCTUnwrap(today.firstIndex { $0["id"] as? String == page["id"] as? String })
        XCTAssertEqual(today[at + 1]["url"] as? String, site.url("/second").absoluteString, "right after the page it came from")

        link.press(forDuration: 1.2)
        let front = app.buttons["Open in New Tab"]
        XCTAssertTrue(front.waitForExistence(timeout: 8))
        front.tap()
        // The new tab is in front at once; its page may take a while to draw
        // on a loaded farm Mac.
        XCTAssertTrue(wait { (try? self.today().count) == before + 2 })
        XCTAssertTrue(wait { (try? self.current()["url"] as? String) == self.site.url("/second").absoluteString }, "the new tab is in front")
        let drawn = app.staticTexts["The second page"].waitForExistence(timeout: 30)
        if !drawn { record(app, "new tab's page") }
        XCTAssertTrue(drawn, "the new tab shows the linked page")
    }

    /// Settings › Privacy's Clear History and Website Data asks first.
    func testClearHistoryAndWebsiteDataAsksFirst() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-YabWorld", "mira", "-YabState", "settings.page-privacy", "-YabNoAnim", "YES"]
        app.launchEnvironment = ["YAB_HAPTICS_SILENT": "1"]
        app.launch()
        let row = app.buttons["settings.row.privacy.clearData"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        if !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.isHittable)
        row.tap()
        let clear = app.buttons["Clear History and Data"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        record(app, "Clear History and Website Data asks")
        // iOS 26 shows Cancel on some sheets; a tap away from it cancels too.
        let cancel = app.buttons["Cancel"]
        if cancel.exists && cancel.isHittable { cancel.tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap() }
        XCTAssertTrue(wait { !clear.exists })
        XCTAssertFalse(app.descendants(matching: .any)["chrome.toast"].exists, "Cancel clears nothing")
        row.tap()
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.tap()
        let toast = app.descendants(matching: .any)["chrome.toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 10))
        XCTAssertTrue(toast.label.contains("History and Data Cleared"), toast.label)
    }

    // MARK: - the owned profile

    /// "<kind> <reason>" for each haptic played.
    private var felt: [String] {
        guard let text = try? String(contentsOf: haptics, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map { $0.split(separator: " ").dropFirst().joined(separator: " ") }
    }

    private var opened: [String] {
        guard let text = try? String(contentsOf: journal, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    private func launch() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = ["YAB_TEST": "1", "YAB_HAPTICS_SILENT": "1", "YAB_OPEN_JOURNAL": journal.path,
                                 "YAB_HAPTICS_JOURNAL": haptics.path]
        // Welcomed already (the arguments' defaults): the page is in front,
        // not the first run's New Tab field over a blank tab.
        app.launchArguments = ["-YabProfileDirectory", folder.path, "-YabURL", site.url("/links").absoluteString,
                               "-YabPrivateLockTestAuthentication", "off", "-settings.welcomed", "YES",
                               // No movement: the held link's menu lands at once and the app goes idle.
                               "-YabNoAnim", "YES"]
        app.terminate()
        app.launch()
        let welcome = app.buttons["welcome.skip"], join = app.buttons["join.close"]
        let arrived = wait { self.document(app).exists || welcome.exists || join.exists || app.textFields["field.input"].exists }
        if !arrived { record(app, "Links launch did not arrive") }
        XCTAssertTrue(arrived)
        if join.exists { XCTAssertTrue(join.isHittable); join.tap() }
        // The welcome may still be coming in over the page: wait for it.
        app.passWelcome(timeout: 6)
        // Without a Mac the welcome leaves the field up: a tap beside it closes it.
        if app.textFields["field.input"].waitForExistence(timeout: 2) {
            let window = app.windows.firstMatch
            window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 6, dy: window.frame.height * 0.3)).tap()
        }
        let ready = wait {
            !app.textFields["field.input"].exists && !app.keyboards.firstMatch.exists && !app.alerts["welcome"].exists
                && self.document(app).exists && app.links["Call Anna"].isHittable
        }
        if !ready { record(app, "Links page readiness") }
        XCTAssertTrue(ready)
        return app
    }

    private func document(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts["Document: \(site.url("/links").absoluteString)"]
    }

    private func space() throws -> [String: Any] {
        let saved = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("profile.json"))) as? [String: Any])
        let id = try XCTUnwrap(saved["spaceID"] as? String)
        let spaces = try XCTUnwrap(saved["spaces"] as? [[String: Any]])
        return try XCTUnwrap(spaces.first { $0["id"] as? String == id })
    }

    private func today() throws -> [[String: Any]] { try XCTUnwrap(try space()["today"] as? [[String: Any]]) }

    private func current() throws -> [String: Any] {
        let id = try XCTUnwrap(try space()["current"] as? String)
        return try XCTUnwrap(try today().first { $0["id"] as? String == id })
    }

    private func wait(_ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(15)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private func record(_ app: XCUIApplication, _ name: String) {
        let png = XCTAttachment(screenshot: app.screenshot())
        png.name = name; png.lifetime = .keepAlways; add(png)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + " native hierarchy"; tree.lifetime = .keepAlways; add(tree)
    }
}

/// A loopback page of links: a call, mail, a web link, a button whose script
/// calls, and one that arms a redirect to mailto: well after its touch.
private final class LinksSite: @unchecked Sendable {
    private let queue = DispatchQueue(label: "owned-browser-basics-links")
    private let listener: NWListener
    private var ready: ((Result<Void, Error>) -> Void)?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var stopped = false
    var port: UInt16 { listener.port!.rawValue }
    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start(_ completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            self.ready = completion
            self.listener.stateUpdateHandler = { [weak self] state in
                guard let self, let callback = self.ready else { return }
                switch state {
                case .ready: self.ready = nil; callback(.success(()))
                case let .failed(error): self.ready = nil; callback(.failure(error))
                case .cancelled: self.ready = nil; callback(.failure(NSError(domain: "LinksSite", code: 2)))
                default: break
                }
            }
            self.listener.newConnectionHandler = { [weak self] connection in
                guard let self, !self.stopped else { connection.cancel(); return }
                self.connections[ObjectIdentifier(connection)] = connection
                connection.start(queue: self.queue)
                self.receive(connection, previous: Data())
            }
            self.listener.start(queue: self.queue)
        }
    }

    func stop() {
        queue.sync {
            stopped = true
            listener.cancel()
            let callback = ready; ready = nil
            callback?(.failure(NSError(domain: "LinksSite", code: 2)))
            connections.values.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func receive(_ connection: NWConnection, previous: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, ended, error in
            guard let self else { connection.cancel(); return }
            var bytes = previous
            if let data { bytes.append(data) }
            guard !self.stopped, error == nil, bytes.count <= 16_384 else { self.close(connection); return }
            guard let header = String(data: bytes, encoding: .utf8), header.contains("\r\n\r\n") else {
                if ended { self.close(connection) } else { self.receive(connection, previous: bytes) }
                return
            }
            let target = header.components(separatedBy: " ").dropFirst().first ?? "/"
            let body = target.hasPrefix("/second") ? Self.second : Self.links
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { [weak self] _ in self?.close(connection) })
        }
    }

    private func close(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = nil
        connection.cancel()
    }

    private static let links = """
    <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><title>Owned links</title>
    <style>body{font:18px -apple-system;padding:70px 20px 120px}a,button{display:block;font:inherit;min-height:44px;margin:10px 0}#document{font-size:12px;overflow-wrap:anywhere}</style>
    <p id="document"></p>
    <a href="tel:+15551234567">Call Anna</a>
    <a href="mailto:anna@example.com">Mail Anna</a>
    <a href="/second">Second page</a>
    <button onclick="location.href='tel:+15550000000'">Call by script</button>
    <button onclick="arm()">Arm redirect</button>
    <p id="armed"></p>
    <script>
    document.getElementById('document').textContent = 'Document: ' + document.URL;
    function arm() {
      document.getElementById('armed').textContent = 'Armed';
      setTimeout(function () { location.href = 'mailto:auto@example.com'; }, 1600);
    }
    </script>
    """

    private static let second = """
    <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><title>Second</title>
    <style>body{font:18px -apple-system;padding:70px 20px}</style><p>The second page</p>
    """
}
