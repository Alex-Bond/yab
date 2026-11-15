import Network
import XCTest

/// A web page's own text field near the bottom of the screen stays above the
/// keyboard once it takes focus: WebKit's keyboard room is not undone by the
/// page viewport's insets (owner report 2026-11-08, 0.1.39).
final class PageKeyboardUITests: XCTestCase {
    private var site: KeyboardSite!
    private var folder: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        folder = URL(fileURLWithPath: "/private/tmp/yab-page-keyboard-\(UUID().uuidString)", isDirectory: true)
        site = try KeyboardSite()
        let ready = expectation(description: "owned keyboard site ready")
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
    }

    /// A field at the end of a page, where the keyboard comes up over it.
    func testAFieldAtTheEndOfAPageRisesAboveTheKeyboard() throws {
        try check(path: "/end", label: "Last field")
    }

    /// A chat's field pinned to the bottom of the page (position: fixed).
    func testAFieldFixedToTheBottomRisesAboveTheKeyboard() throws {
        try check(path: "/fixed", label: "Message field")
    }

    private func check(path: String, label: String) throws {
        let app = try launch(path)
        let field = app.webViews.textFields[label].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        record(app, "\(path) before the field takes focus")
        // Below the plate's reach, inside the page: its own words, not the chrome's.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 8), "the keyboard came up")
        // The page and the keyboard both move; judge where they settle.
        var settled = false
        var last = CGRect.null
        let end = Date().addingTimeInterval(6)
        while Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            let now = field.frame
            if now == last { settled = true; break }
            last = now
        }
        XCTAssertTrue(settled, "the page stopped moving")
        // Stay focused for the rest: a field the keyboard covers is still typed into.
        field.typeText("hi")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        record(app, "\(path) with the keyboard up")
        let fieldFrame = field.frame, keyboardFrame = keyboard.frame
        XCTAssertLessThanOrEqual(fieldFrame.maxY, keyboardFrame.minY + 1,
                                 "\(label) \(fieldFrame) is under the keyboard \(keyboardFrame)")
    }

    private func launch(_ path: String) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = ["YAB_TEST": "1", "YAB_HAPTICS_SILENT": "1"]
        app.launchArguments = ["-YabProfileDirectory", folder.path, "-YabURL", site.url(path).absoluteString,
                               "-YabPrivateLockTestAuthentication", "off", "-settings.welcomed", "YES"]
        app.terminate()
        app.launch()
        let heading = app.staticTexts["Keyboard page"]
        let welcome = app.buttons["welcome.skip"], join = app.buttons["join.close"]
        // A cold simulator's first launch takes longer than the steps after it.
        let arrived = wait(40) { heading.exists || welcome.exists || join.exists || app.textFields["field.input"].exists }
        if !arrived { record(app, "\(path) launch") }
        XCTAssertTrue(arrived)
        if join.exists { join.tap() }
        app.passWelcome(timeout: 6)
        if app.textFields["field.input"].exists { app.closeField() }
        let ready = wait { heading.exists && !app.textFields["field.input"].exists && !app.keyboards.firstMatch.exists }
        if !ready { record(app, "\(path) readiness") }
        XCTAssertTrue(ready)
        return app
    }

    private func wait(_ seconds: TimeInterval = 15, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private func record(_ app: XCUIApplication, _ name: String) {
        let png = XCTAttachment(screenshot: app.screenshot())
        png.name = name; png.lifetime = .keepAlways; add(png)
    }
}

/// Two loopback pages: a field at the end of a page one screen tall, and a
/// chat's field fixed to the bottom.
private final class KeyboardSite: @unchecked Sendable {
    private let queue = DispatchQueue(label: "owned-page-keyboard")
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
                case .cancelled: self.ready = nil; callback(.failure(NSError(domain: "KeyboardSite", code: 2)))
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
            callback?(.failure(NSError(domain: "KeyboardSite", code: 2)))
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
            let body = target.hasPrefix("/fixed") ? Self.fixed : Self.end
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { [weak self] _ in self?.close(connection) })
        }
    }

    private func close(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = nil
        connection.cancel()
    }

    private static let end = """
    <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><title>Keyboard end</title>
    <style>body{margin:0;font:17px -apple-system}h1{font-size:22px;margin:70px 20px 0}
    #room{height:calc(100vh - 330px)}input{display:block;box-sizing:border-box;width:calc(100% - 40px);margin:0 20px 20px;height:48px;font:17px -apple-system}</style>
    <h1>Keyboard page</h1><div id="room"></div>
    <input aria-label="Last field" placeholder="Last field">
    """

    private static let fixed = """
    <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><title>Keyboard fixed</title>
    <style>body{margin:0;font:17px -apple-system}h1{font-size:22px;margin:70px 20px 0}
    form{position:fixed;left:0;right:0;bottom:0;padding:12px 20px;background:#eee}
    input{display:block;box-sizing:border-box;width:100%;height:48px;font:17px -apple-system}</style>
    <h1>Keyboard page</h1>
    <form onsubmit="return false"><input aria-label="Message field" placeholder="Message field"></form>
    """
}
