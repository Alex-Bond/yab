import Network
import XCTest

/// Explicit test-owned normal profile, real taps, forms and WebKit. No world
/// fixture, private auth bypass or cleanup-safety override is passed.
final class TabClearUITests: XCTestCase {
    private var directory: URL!
    private var site: TabClearSite!
    override func setUpWithError() throws {
        continueAfterFailure = false
        directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("yab-tab-clear-" + UUID().uuidString)
        site = try TabClearSite()
        let ready = expectation(description: "owned Clear site ready")
        site.ready = { ready.fulfill() }; site.start()
        wait(for: [ready], timeout: 10)
    }
    override func tearDownWithError() throws {
        XCUIApplication().terminate(); site?.stop()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }
    func testClearProtectsActualDraftAndCurrentPageAndUndoReturnsTheOriginalOrder() throws {
        let app = launch()
        app.links["Open form tab"].tap()
        let draft = app.textFields["Owned draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Owned form page"].exists)
        let window = app.windows.firstMatch
        let draftFrame = draft.frame
        XCTAssertGreaterThan(draftFrame.width, 0); XCTAssertGreaterThan(draftFrame.height, 0)
        XCTAssertTrue(window.frame.contains(draftFrame))
        // Use the displayed input's real window coordinate. Keep the native
        // keyboard and DOM focus/input events as mandatory arrival proof;
        // an intercepted finger must still fail before any Clear action.
        save(app, "Actual visible owned form before native finger focus")
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: draftFrame.midX - window.frame.minX, dy: draftFrame.midY - window.frame.minY)).tap()
        XCTAssertTrue(wait { app.keyboards.firstMatch.exists && app.staticTexts["Owned draft focused"].exists })
        draft.typeText(" unfinished")
        XCTAssertTrue(wait { app.staticTexts["Owned draft edited: before unfinished"].exists })
        XCTAssertEqual(draft.value as? String, "before unfinished")
        // The actual R40 movie shows WebKit's focused input zoom with a
        // visible link whose AX hit-point is unavailable. Dismiss through
        // the real system accessory, retaining the dirty value and DOM proof.
        let done = app.toolbars.buttons["Done"].firstMatch
        XCTAssertTrue(wait { done.isHittable })
        done.tap()
        XCTAssertTrue(wait { !app.keyboards.firstMatch.exists })
        XCTAssertEqual(draft.value as? String, "before unfinished")
        XCTAssertTrue(app.staticTexts["Owned draft edited: before unfinished"].exists)
        // WebKit keeps its zoom on the input after Done, where the link's AX
        // hit point is unavailable (the R40 movie): tap it where it is drawn.
        let next = app.links["Open current tab"]
        XCTAssertTrue(wait { next.exists && window.frame.contains(CGPoint(x: next.frame.midX, y: next.frame.midY)) })
        save(app, "Actual edited form after native Done before opening the next tab")
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: next.frame.midX - window.frame.minX, dy: next.frame.midY - window.frame.minY)).tap()
        XCTAssertTrue(app.staticTexts["Owned current page"].waitForExistence(timeout: 10))
        XCTAssertTrue(wait { !app.keyboards.firstMatch.exists })
        XCTAssertTrue(wait { self.today().count == 4 })
        let before = today(), current = savedSpace()?["current"] as? String
        let safe = try XCTUnwrap(before.first { ($0["url"] as? String)?.hasSuffix("/safe") == true }?["id"] as? String)
        let form = try XCTUnwrap(before.first { ($0["url"] as? String)?.hasSuffix("/form") == true }?["id"] as? String)
        // The spaces took the column's place and keep its today line with
        // Clear (aaf8443d); Clear's Undo stands over the plate once they are
        // put away (BrowserClearUndo stays out of a shown field).
        SpacesGesture.open(in: app)
        let page = app.scrollViews["newtab.space.local.personal"]
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        let clear = app.buttons["column.clear"]
        XCTAssertTrue(wait { clear.isHittable && page.frame.contains(clear.frame) })
        save(app, "Actual current tab and unfinished form before Clear")
        clear.tap()
        XCTAssertTrue(wait { self.today().count < before.count }, "Clear cleared nothing")
        let cleared = today()
        XCTAssertFalse(cleared.contains { $0["id"] as? String == safe })
        XCTAssertTrue(cleared.contains { $0["id"] as? String == form })
        XCTAssertEqual(savedSpace()?["current"] as? String, current)
        // Undo's six seconds start once its toast is on screen, not under
        // the spaces that made it: longer than that with them still up, and
        // Undo is there when they go.
        RunLoop.current.run(until: Date().addingTimeInterval(7))
        XCTAssertTrue(app.closeField(), "the spaces stayed up")
        let undo = app.buttons.matching(NSPredicate(format: "identifier == 'column.clear.undo' OR label == 'Undo'")).firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        // Measured once it has come in (42.7 mid-way, 6ca918148c564a21).
        undo.waitUntilStill(timeout: 2)
        XCTAssertTrue(undo.isHittable)
        XCTAssertGreaterThanOrEqual(undo.frame.width, 44); XCTAssertGreaterThanOrEqual(undo.frame.height, 44)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(undo.frame))
        undo.tap()
        XCTAssertTrue(wait { self.today().compactMap { $0["id"] as? String } == before.compactMap { $0["id"] as? String } })
        XCTAssertEqual(savedSpace()?["current"] as? String, current)
        save(app, "Actual restored row order with the current page retained")
    }
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-YabProfileDirectory", directory.path, "-YabURL", site.url.appendingPathComponent("safe").absoluteString]
        app.launchEnvironment = ["YAB_TEST": "1", "YAB_HAPTICS_SILENT": "1"]
        app.terminate(); app.launch()
        let later = app.buttons["welcome.start"]
        XCTAssertTrue(later.waitForExistence(timeout: 15)); app.passWelcome()
        XCTAssertTrue(app.textFields["field.input"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.closeField(), "the welcome's New Tab field stayed over the page")
        XCTAssertTrue(app.staticTexts["Owned safe page"].waitForExistence(timeout: 15))
        return app
    }
    private func savedSpace() -> [String: Any]? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("profile.json")),
              let profile = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (profile["spaces"] as? [[String: Any]])?.first { $0["id"] as? String == "local.personal" }
    }
    private func today() -> [[String: Any]] { savedSpace()?["today"] as? [[String: Any]] ?? [] }
    private func wait(_ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline { if predicate() { return true }; RunLoop.current.run(until: Date().addingTimeInterval(0.03)) }
        return predicate()
    }
    private func save(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name
        attachment.lifetime = .keepAlways; add(attachment)
    }
}

private final class TabClearSite {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "TabClearSite")
    private var connections: [NWConnection] = []
    var ready: (() -> Void)?
    var url: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)")! }
    init() throws { listener = try NWListener(using: .tcp, on: .any) }
    func start() {
        listener.stateUpdateHandler = { [weak self] state in if case .ready = state { self?.ready?() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }; self.connections.append(connection)
            connection.start(queue: self.queue); self.receive(connection, bytes: Data())
        }
        listener.start(queue: queue)
    }
    private func receive(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            guard let self else { return }; var bytes = bytes; if let data { bytes.append(data) }
            guard bytes.count <= 32_768 else { connection.cancel(); return }
            if bytes.range(of: Data("\r\n\r\n".utf8)) != nil {
                let path = String(decoding: bytes, as: UTF8.self).split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let body: String
                if path == "/safe" { body = "<h1>Owned safe page</h1><a href='/form' target='_blank'>Open form tab</a>" }
                else if path == "/form" { body = "<h1>Owned form page</h1><input aria-label='Owned draft' value='before'><p id='draft-focus'>Owned draft idle</p><p id='draft-input'>Owned draft unchanged</p><p><a href='/current' target='_blank'>Open current tab</a></p><script>const ownedDraft=document.querySelector('input'); ownedDraft.addEventListener('focus',()=>{document.getElementById('draft-focus').textContent=document.activeElement===ownedDraft?'Owned draft focused':'Owned draft not focused';}); ownedDraft.addEventListener('input',()=>{document.getElementById('draft-input').textContent='Owned draft edited: '+ownedDraft.value;});</script>" }
                else { body = "<h1>Owned current page</h1>" }
                let html = "<!doctype html><meta name='viewport' content='width=device-width,initial-scale=1'><title>Owned</title><body style='background:white;color:black;font:20px system-ui;margin:24px'>" + body + "</body>"
                let payload = Data(html.utf8)
                let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(header.utf8) + payload, contentContext: .finalMessage, isComplete: true,
                                completion: .contentProcessed { _ in connection.cancel() })
            } else if error != nil || done { connection.cancel() }
            else { self.receive(connection, bytes: bytes) }
        }
    }
    func stop() { listener.cancel(); queue.sync { connections.forEach { $0.cancel() }; connections = [] } }
}
