import Network
import XCTest

/// Real WebKit file inputs use the default iOS panel in an owned browser profile.
final class SystemWebsiteDialogUITests: XCTestCase {
    private var site: WebsiteSystemDialogSite!
    private var folder: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        folder = URL(fileURLWithPath: "/private/tmp/yab-system-dialogs-\(UUID().uuidString)", isDirectory: true)
        site = try WebsiteSystemDialogSite()
        let ready = expectation(description: "owned system-dialog listener ready")
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

    func testPublicDefaultFilesPickerCancelReopenRetainsPageHistoryAndTouch() throws {
        try filesJourney(privately: false)
    }

    func testPrivateDefaultFilesPickerCancelReopenNeverPersistsPrivateDocument() throws {
        try filesJourney(privately: true)
    }

    private func filesJourney(privately: Bool) throws {
        let app = try launch()
        let initial = try selectedPublicTab()
        let tabID = try XCTUnwrap(initial["id"] as? String)
        let timeline = try navigation(tabID)
        let identityBefore = try Data(contentsOf: folder.appendingPathComponent("website-data-store.json"))
        let requested = site.url(privately ? "/page?private=owned-files" : "/page")
        if privately {
            let plus = app.buttons["chrome.plus"]
            XCTAssertTrue(plus.isHittable)
            plus.tap()
            let input = app.textFields["field.input"]
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            let eyes = app.descendants(matching: .any)["field.eyes"]
            XCTAssertTrue(eyes.isHittable)
            eyes.tap()
            XCTAssertEqual(eyes.value as? String, "on")
            // Privacy changes rebuild native input traits. Restore actual
            // keyboard focus with a genuine finger before typing the URL.
            XCTAssertTrue(input.isHittable)
            input.tap()
            XCTAssertTrue(wait { app.keyboards.firstMatch.exists && input.isHittable })
            input.typeText(requested.absoluteString)
            XCTAssertEqual(input.value as? String, requested.absoluteString)
            let go = app.keyboards.buttons.matching(NSPredicate(format: "label ==[c] 'go' OR identifier ==[c] 'go'")).firstMatch
            XCTAssertTrue(go.waitForExistence(timeout: 5))
            XCTAssertTrue(go.isHittable)
            go.tap()
            XCTAssertTrue(wait { !input.exists && !app.keyboards.firstMatch.exists && self.document(app, requested).exists })
        }
        XCTAssertEqual(app.buttons["chrome.plus"].value as? String, privately ? "Private" : "Public")
        XCTAssertTrue(document(app, requested).exists)
        XCTAssertEqual(site.pageRequests(requested.path + (requested.query.map { "?" + $0 } ?? "")), 1)

        // Four genuine cancellations probe a 44-point square around the
        // actual native Cancel center. Its AX glyph rect is not its hit region.
        for attempt in 1...4 {
            let upload = app.buttons["Choose text file"]
            XCTAssertTrue(upload.isHittable, "the actual page file input cannot receive the next finger")
            upload.tap()
            // Some iOS configurations show a source menu before Files. Both
            // branches must arrive at the genuine native navigation controller.
            let chooseFile = app.sheets.buttons["Choose File"].firstMatch
            let cancel = app.navigationBars.buttons["Cancel"].firstMatch
            let appeared = wait { cancel.isHittable || chooseFile.isHittable }
            if !appeared { record(app, "Files picker missing on attempt \(attempt)") }
            XCTAssertTrue(appeared, "INCOMPLETE: WebKit's actual file picker did not appear")
            if chooseFile.isHittable { chooseFile.tap() }
            let filesNavigation = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"]
            let nativeArrived = wait { filesNavigation.exists && cancel.isHittable }
            if !nativeArrived { record(app, "Files navigation missing on attempt \(attempt)") }
            XCTAssertTrue(nativeArrived, "INCOMPLETE: no genuine Files navigation and Cancel control were observed")
            let window = app.windows.firstMatch, frame = cancel.frame
            XCTAssertGreaterThan(frame.width, 0); XCTAssertGreaterThan(frame.height, 0)
            XCTAssertTrue(window.frame.contains(frame))
            // The four corners of the native Cancel's own frame, 1 pt in: on
            // iOS 26.4 it is 36.7 × 36 and a finger 22 out from its middle,
            // past that frame, missed it (c82ec7ad52964ce8). That is iOS's
            // control, not Yab's to widen.
            let radius = min(CGFloat(22), min(frame.width, frame.height) / 2 - 1)
            let x = frame.midX + (attempt == 1 || attempt == 3 ? -radius : radius)
            let y = frame.midY + (attempt <= 2 ? -radius : radius)
            let point = CGPoint(x: x, y: y)
            XCTAssertTrue(window.frame.contains(point))
            XCTAssertTrue(filesNavigation.frame.contains(point))
            let facts = XCTAttachment(string: "Native Cancel AX frame=\(frame), navigation=\(filesNavigation.frame), actual window=\(window.frame), finger=\(point), tested side=\(2 * radius), covered upload AX hittable=\(upload.isHittable)")
            facts.name = "Actual Files cancellation corner \(attempt)"; facts.lifetime = .keepAlways; add(facts)
            record(app, "\(privately ? "Private" : "Public") native Files picker attempt \(attempt)")
            window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: x - window.frame.minX, dy: y - window.frame.minY)).tap()
            XCTAssertTrue(wait { !cancel.exists && app.buttons["Choose text file"].isHittable })
            XCTAssertTrue(app.staticTexts["Files selected: 0"].exists)
            XCTAssertTrue(app.staticTexts["Picker attempts: \(attempt)"].exists)
            XCTAssertTrue(document(app, requested).exists)
            XCTAssertEqual(site.uploadRequests, 0, "cancellation cannot submit a file")
            XCTAssertFalse(app.textFields["field.input"].exists)
            XCTAssertFalse(app.keyboards.firstMatch.exists)
        }

        let action = app.buttons["Page action"]
        XCTAssertTrue(action.isHittable)
        action.tap()
        XCTAssertTrue(app.staticTexts["Page action 1"].waitForExistence(timeout: 5))
        XCTAssertTrue(document(app, requested).exists)
        record(app, "\(privately ? "Private" : "Public") actual page touch after four genuine native corner cancellations")
        XCTAssertEqual(site.pageRequests(requested.path + (requested.query.map { "?" + $0 } ?? "")), 1)
        XCTAssertEqual(site.uploadRequests, 0)
        XCTAssertEqual(try selectedPublicTab()["id"] as? String, tabID)
        XCTAssertEqual(try navigation(tabID), timeline)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("website-data-store.json")), identityBefore)
        let saved = try String(contentsOf: folder.appendingPathComponent("profile.json"), encoding: .utf8)
        if privately {
            XCTAssertFalse(saved.contains("private=owned-files"))
            XCTAssertEqual(app.buttons["chrome.plus"].value as? String, "Private")
        } else {
            XCTAssertEqual(try selectedPublicTab()["url"] as? String, requested.absoluteString)
        }
    }

    private func launch() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = ["YAB_TEST": "1", "YAB_HAPTICS_SILENT": "1"]
        app.launchArguments = ["-YabProfileDirectory", folder.path, "-YabURL", site.url().absoluteString,
                               "-YabPrivateLockTestAuthentication", "off"]
        app.terminate()
        app.launch()
        let welcome = app.buttons["welcome.skip"], join = app.buttons["join.close"]
        let arrived = wait {
            self.document(app, self.site.url()).exists || welcome.exists || join.exists || app.textFields["field.input"].exists
        }
        if !arrived { record(app, "System-dialog owned launch did not arrive") }
        XCTAssertTrue(arrived)
        let bytes = try Data(contentsOf: folder.appendingPathComponent("website-data-store.json"))
        let identity = try XCTUnwrap(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(identity["version"] as? Int, 1)
        _ = try XCTUnwrap((identity["dataStoreID"] as? String).flatMap(UUID.init(uuidString:)))
        if join.exists { XCTAssertTrue(join.isHittable); join.tap() }
        // The page draws before the welcome's tray rises over it (1.3 s in): wait for it.
        app.passWelcome(timeout: 6)
        if app.textFields["field.input"].exists { app.closeField() }
        let ready = wait {
            !app.textFields["field.input"].exists && !app.keyboards.firstMatch.exists
                && self.document(app, self.site.url()).exists && app.buttons["Choose text file"].isHittable
        }
        if !ready { record(app, "System-dialog actual document readiness") }
        XCTAssertTrue(ready)
        XCTAssertEqual(try selectedPublicTab()["url"] as? String, site.url().absoluteString)
        return app
    }

    private func document(_ app: XCUIApplication, _ url: URL) -> XCUIElement {
        app.staticTexts["Document: \(url.absoluteString)"]
    }

    private func profile() throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("profile.json"))) as? [String: Any])
    }

    private func selectedPublicTab() throws -> [String: Any] {
        let saved = try profile()
        let id = try XCTUnwrap(saved["spaceID"] as? String)
        let spaces = try XCTUnwrap(saved["spaces"] as? [[String: Any]])
        let space = try XCTUnwrap(spaces.first { $0["id"] as? String == id })
        let current = try XCTUnwrap(space["current"] as? String)
        let tabs = try XCTUnwrap(space["today"] as? [[String: Any]])
        return try XCTUnwrap(tabs.first { $0["id"] as? String == current })
    }

    private func navigation(_ id: String) throws -> [String] {
        let saved = try profile()
        let all = try XCTUnwrap(saved["navigation"] as? [String: [String: Any]])
        let current = try XCTUnwrap(all[id])
        let index = try XCTUnwrap(current["index"] as? Int)
        let entries = try XCTUnwrap(current["entries"] as? [[String: Any]])
        return [String(index)] + entries.compactMap { $0["url"] as? String }
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

/// A bounded loopback document. Neither files nor credentials are preselected.
private final class WebsiteSystemDialogSite: @unchecked Sendable {
    private let queue = DispatchQueue(label: "owned-website-system-dialog-site")
    private let listener: NWListener
    private var ready: ((Result<Void, Error>) -> Void)?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var stopped = false
    private var pages: [String: Int] = [:]
    private var uploads = 0
    var port: UInt16 { listener.port!.rawValue }
    var uploadRequests: Int { queue.sync { uploads } }
    func pageRequests(_ path: String) -> Int { queue.sync { pages[path, default: 0] } }
    func url(_ path: String = "/page") -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

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
                case .cancelled: self.ready = nil; callback(.failure(NSError(domain: "WebsiteSystemDialogSite", code: 2)))
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
            self.queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, let callback = self.ready else { return }
                self.ready = nil; self.listener.cancel()
                callback(.failure(NSError(domain: "WebsiteSystemDialogSite", code: 1)))
            }
        }
    }

    func stop() {
        queue.sync {
            stopped = true
            listener.cancel()
            let callback = ready; ready = nil
            callback?(.failure(NSError(domain: "WebsiteSystemDialogSite", code: 2)))
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
            let first = header.components(separatedBy: "\r\n")[0].split(separator: " ")
            guard first.count == 3 else { self.close(connection); return }
            let method = String(first[0]), target = String(first[1])
            if method == "POST" { self.uploads += 1 }
            if method == "GET", target.hasPrefix("/page") { self.pages[target, default: 0] += 1 }
            let body = Self.page
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { [weak self] _ in self?.close(connection) })
        }
    }

    private func close(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = nil
        connection.cancel()
    }

    private static let page = """
    <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Owned system dialog page</title>
    <style>body{font:18px -apple-system;padding:60px 20px 100px}h1{font-size:22px}input,button{font:inherit;min-height:44px;margin:8px 0}#document{font-size:12px;overflow-wrap:anywhere}</style>
    <h1>Owned system dialog page</h1><p id="document"></p>
    <form method="post" action="/upload" enctype="multipart/form-data">
    <input id="files" type="file" accept=".txt,text/plain" aria-label="Choose text file">
    </form>
    <p id="attempts">Picker attempts: 0</p><p id="selected">Files selected: 0</p>
    <button onclick="document.getElementById('action').textContent='Page action '+(++actions)">Page action</button>
    <p id="action">Page action 0</p>
    <script>
    var attempts=0, actions=0;
    document.getElementById('document').textContent='Document: '+document.URL;
    document.getElementById('files').addEventListener('click',function(){document.getElementById('attempts').textContent='Picker attempts: '+(++attempts)});
    document.getElementById('files').addEventListener('change',function(){document.getElementById('selected').textContent='Files selected: '+this.files.length});
    </script>
    """
}
