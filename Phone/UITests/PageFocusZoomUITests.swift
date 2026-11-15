import Network
import XCTest

/// Feedback #1437 (Calendly, 0.1.21): a text input under 16 px zooms the page
/// as it takes focus; after the keyboard's Done the page stayed zoomed and no
/// tap reached it any more. A live page from an owned listener, not a fixture
/// world, so the production viewport code runs.
final class PageFocusZoomUITests: XCTestCase {
    private var site: FocusZoomSite!

    override func setUpWithError() throws {
        continueAfterFailure = false
        site = try FocusZoomSite()
        let ready = expectation(description: "owned listener ready")
        site.start { ready.fulfill() }
        wait(for: [ready], timeout: 10)
    }

    override func tearDown() {
        XCUIApplication().terminate()
        site?.stop()
    }

    func testPageAnswersTapsAfterDoneDismissesAZoomedField() throws {
        let app = XCUIApplication()
        app.launchEnvironment = ["YAB_TEST": "1", "YAB_HAPTICS_SILENT": "1"]
        app.launchArguments = ["-YabProfileDirectory", "/private/tmp/yab-focus-zoom-\(UUID().uuidString)",
                               "-YabURL", site.url, "-YabPrivateLockTestAuthentication", "off"]
        app.launch()
        let join = app.buttons["join.close"]
        if join.waitForExistence(timeout: 3) { join.tap() }
        app.passWelcome(timeout: 6)
        if app.textFields["field.input"].waitForExistence(timeout: 2) { app.closeField() }

        let web = app.webViews.firstMatch
        XCTAssertTrue(web.staticTexts["Pick a time"].waitForExistence(timeout: 45))
        let heading = web.staticTexts["Pick a time"]
        let before = heading.frame
        save(app, "1-before")

        // Before: one tap works.
        let action = web.buttons["Page action"]
        XCTAssertTrue(action.isHittable)
        action.tap()
        XCTAssertTrue(web.staticTexts["Page action 1"].waitForExistence(timeout: 5), "the page never answered a tap at all")

        let name = web.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        name.typeText("Ada")
        settle(1.5)
        let zoomed = heading.frame
        save(app, "2-focused")
        log("heading before \(before), focused \(zoomed)")

        // The form assistant's check mark (Done).
        let done = app.buttons.matching(NSPredicate(format: "label == 'Done' OR identifier == 'Done'")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5), "no Done on the keyboard: \(app.debugDescription)")
        done.tap()
        XCTAssertTrue(wait(timeout: 8) { !app.keyboards.firstMatch.exists }, "the keyboard stayed after Done")
        settle(1.5)
        let after = heading.frame
        save(app, "3-after-done")
        log("heading after Done \(after)")
        // Asserted last, so a zoomed page still says whether taps reach it.
        let stayedZoomed = abs(after.width - before.width) > 2

        // The report: nothing on the page responded to taps any more.
        for count in 2...3 {
            let button = web.buttons["Page action"]
            XCTAssertTrue(button.exists)
            if !button.isHittable { web.swipeDown() }
            button.tap()
            XCTAssertTrue(web.staticTexts["Page action \(count)"].waitForExistence(timeout: 5),
                          "tap \(count) after Done never reached the page")
        }
        // A link still goes, too.
        web.links["Next step"].tap()
        XCTAssertTrue(web.staticTexts["Confirmed"].waitForExistence(timeout: 10), "the link after Done never navigated")
        save(app, "4-tapped")
        XCTAssertFalse(stayedZoomed, "the page stayed zoomed after Done: \(before) -> \(after)")
    }

    private func settle(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    private func wait(timeout: TimeInterval, _ check: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if check() { return true }; settle(0.05) }
        return check()
    }

    private func log(_ line: String) {
        let attachment = XCTAttachment(string: line); attachment.name = "geometry"; attachment.lifetime = .keepAlways; add(attachment)
        print("focus-zoom: \(line)")
    }

    private func save(_ app: XCUIApplication, _ name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let folder = Atlas.out.appendingPathComponent("focus-zoom")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: folder.appendingPathComponent(name + ".png"))
    }
}

/// A scheduling form like Calendly's: 14 px inputs, which iOS zooms to on focus.
private final class FocusZoomSite: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "focus-zoom-fixture")
    private var connections: [NWConnection] = []
    var url: String { "http://127.0.0.1:\(listener.port!.rawValue)/form" }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start(_ ready: @escaping () -> Void) {
        listener.stateUpdateHandler = { state in if case .ready = state { ready() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let body = request.hasPrefix("GET /done") ? Self.done : Self.form
                var response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n".utf8)
                response.append(Data(body.utf8))
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: queue)
    }

    func stop() { queue.sync { listener.cancel(); connections.forEach { $0.cancel() }; connections = [] } }

    private static let form = """
    <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1"><title>Pick a time</title><link rel=icon href=data:,>
    <style>body{margin:0;padding:72px 20px 200px;font:14px -apple-system,system-ui;background:#fff;color:#1a1a1a}
    h1{font-size:22px}label{display:block;margin:16px 0 6px;font-weight:600}
    input{box-sizing:border-box;width:100%;font-size:14px;padding:10px;border:1px solid #bbb;border-radius:8px}
    button,a{display:block;margin:14px 0;padding:14px;font-size:16px;border-radius:8px}button{background:#0069ff;color:#fff;border:0;width:100%}</style></head><body>
    <h1>Pick a time</h1><form onsubmit="return false"><label for=n>Name</label><input id=n name=name autocomplete=off>
    <label for=e>Email</label><input id=e name=email type=email autocomplete=off></form>
    <button onclick="window.actions=(window.actions||0)+1;document.getElementById('result').textContent='Page action '+window.actions">Page action</button>
    <p id=result>Waiting</p><a href="/done">Next step</a></body></html>
    """

    private static let done = """
    <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1"><title>Confirmed</title><link rel=icon href=data:,></head>
    <body style="padding:72px 20px;font:16px system-ui"><h1>Confirmed</h1></body></html>
    """
}
