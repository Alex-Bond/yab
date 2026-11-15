import Network
import XCTest

/// Real fingers answer native WebKit challenges in a disposable real profile.
final class HTTPAuthenticationUITests: XCTestCase {
    private var site: HTTPAuthenticationUISite!
    private var folder: URL!
    override func setUpWithError() throws {
        continueAfterFailure = false
        folder = URL(fileURLWithPath: "/private/tmp/yab-http-auth-\(UUID().uuidString)", isDirectory: true)
        site = try HTTPAuthenticationUISite()
        let ready = expectation(description: "owned HTTP listener")
        site.start { result in if case let .failure(error) = result { XCTFail("Owned listener: \(error)") }; ready.fulfill() }
        wait(for: [ready], timeout: 10)
    }
    override func tearDownWithError() throws {
        XCUIApplication().terminate(); site.stop()
        if let bytes = try? Data(contentsOf: folder.appendingPathComponent("profile.json")) {
            let receipt = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.json")
            receipt.name = "HTTP auth owned profile"; receipt.lifetime = .keepAlways; add(receipt)
        }
        try? FileManager.default.removeItem(at: folder)
    }
    func testActualNativeUsernamePasswordCancelRetryAndBackKeepPublicOwnership() throws { try journey(privateMode: false) }
    func testPrivateNativePasswordAndPageTouchKeepNoPrivateURLOnDisk() throws { try journey(privateMode: true) }
    private func journey(privateMode: Bool) throws {
        let app = XCUIApplication()
        app.launchEnvironment = ["YAB_TEST":"1", "YAB_HAPTICS_SILENT":"1"]
        app.launchArguments = ["-YabProfileDirectory", folder.path, "-YabURL", site.url("/page").absoluteString,
                               "-YabPrivateLockTestAuthentication", "off"]
        app.terminate(); app.launch()
        XCTAssertTrue(wait { app.staticTexts["Owned page"].exists || app.buttons["welcome.start"].exists
            || app.textFields["field.input"].exists || app.buttons["join.close"].exists })
        let identity = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("website-data-store.json"))) as? [String:Any])
        _ = try XCTUnwrap((identity["dataStoreID"] as? String).flatMap(UUID.init(uuidString:)))
        if app.buttons["join.close"].exists { XCTAssertTrue(app.buttons["join.close"].isHittable); app.buttons["join.close"].tap() }
        // The page draws before the welcome's tray rises over it (1.3 s in): wait for it.
        app.passWelcome(timeout: 6)
        if app.textFields["field.input"].exists { app.closeField() }
        XCTAssertTrue(wait { app.staticTexts["Owned page"].exists && !app.textFields["field.input"].exists })
        let pageURL = site.url(privateMode ? "/page?private=owned" : "/page")
        if privateMode {
            app.buttons["chrome.plus"].tap()
            let field = app.textFields["field.input"]; XCTAssertTrue(field.waitForExistence(timeout: 5))
            app.descendants(matching: .any)["field.eyes"].tap()
            XCTAssertEqual(app.descendants(matching: .any)["field.eyes"].value as? String, "on")
            field.typeText(pageURL.absoluteString)
            let go = app.keyboards.buttons.matching(NSPredicate(format: "label ==[c] 'go' OR identifier ==[c] 'go'")).firstMatch
            XCTAssertTrue(go.waitForExistence(timeout: 5)); XCTAssertTrue(go.isHittable); go.tap()
            XCTAssertTrue(wait { app.staticTexts["Owned page"].exists && !field.exists })
        }
        let url = site.url("/auth")
        let link = app.webViews.links["Protected page"]
        XCTAssertTrue(link.isHittable); link.tap()
        let alert = app.alerts["Sign In to 127.0.0.1:\(site.port)"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        XCTAssertEqual(site.authorizedCount, 0)
        record(app, "Actual native HTTP authentication before credentials")
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(wait { !alert.exists }); XCTAssertEqual(site.authorizedCount, 0)
        // Retry is the production captured failed-navigation action, never a
        // synthetic WebKit challenge or direct callback in this UI scenario.
        let retry = app.buttons["page.error.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10)); XCTAssertTrue(retry.isHittable)
        XCTAssertEqual(app.staticTexts["page.error.reason"].label, "Website sign-in was cancelled. Try again to sign in or go back.")
        record(app, "Actual Cancel error has captured Retry and previous-page Back")
        retry.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        let username = alert.textFields["page.authentication.username"]
        let password = alert.secureTextFields["page.authentication.password"]
        XCTAssertTrue(username.isHittable); username.tap(); username.typeText("owned")
        XCTAssertTrue(password.isHittable); password.tap(); password.typeText("fixture")
        record(app, "Actual secure HTTP authentication fields")
        alert.buttons["Sign In"].tap()
        XCTAssertTrue(wait { !alert.exists && app.staticTexts["actual authorized response"].exists })
        XCTAssertEqual(site.authorizedCount, 1)
        let action = app.webViews.buttons["actual authorized response"]
        XCTAssertTrue(action.isHittable); action.tap()
        XCTAssertTrue(app.staticTexts["Page touched"].waitForExistence(timeout: 5))
        record(app, "Actual authenticated page accepts touch")
        XCTAssertEqual(app.buttons["chrome.plus"].value as? String, privateMode ? "Private" : "Public")
        let bytes = try Data(contentsOf: folder.appendingPathComponent("profile.json"))
        let profile = try XCTUnwrap(try JSONSerialization.jsonObject(with: bytes) as? [String:Any])
        let space = try XCTUnwrap(profile["spaceID"] as? String)
        let spaces = try XCTUnwrap(profile["spaces"] as? [[String:Any]])
        let personal = try XCTUnwrap(spaces.first { $0["id"] as? String == space })
        let tabs = try XCTUnwrap(personal["today"] as? [[String:Any]])
        let currentID = try XCTUnwrap(personal["current"] as? String)
        let current = try XCTUnwrap(tabs.first { $0["id"] as? String == currentID })
        if privateMode {
            XCTAssertEqual(space, "local.personal")
            XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(url.absoluteString))
            XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(pageURL.absoluteString))
        } else {
            XCTAssertEqual(current["url"] as? String, url.absoluteString)
            let navigation = try XCTUnwrap(profile["navigation"] as? [String:[String:Any]])
            let entries = try XCTUnwrap(navigation[currentID]?["entries"] as? [[String:Any]])
            XCTAssertEqual(entries.compactMap { $0["url"] as? String }, [pageURL.absoluteString, url.absoluteString])
        }
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("owned:fixture"))
        app.buttons["chrome.back"].tap()
        XCTAssertTrue(wait { !alert.exists && !app.keyboards.firstMatch.exists && app.staticTexts["Owned page"].exists })
        let originalAction = app.webViews.buttons["Owned action"]
        XCTAssertTrue(originalAction.isHittable); originalAction.tap()
        XCTAssertTrue(app.staticTexts["Page touched"].waitForExistence(timeout: 5))
        let returned = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("profile.json"))) as? [String:Any])
        let returnedSpaces = try XCTUnwrap(returned["spaces"] as? [[String:Any]])
        let returnedPersonal = try XCTUnwrap(returnedSpaces.first { $0["id"] as? String == space })
        XCTAssertEqual(returnedPersonal["current"] as? String, currentID)
        if !privateMode {
            let navigation = try XCTUnwrap(returned["navigation"] as? [String:[String:Any]])
            XCTAssertEqual(navigation[currentID]?["index"] as? Int, 0)
        }
    }
    private func wait(_ check: () -> Bool) -> Bool {
        let until = Date().addingTimeInterval(15)
        while Date() < until { if check() { return true }; RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        let arrived = check()
        if !arrived {
            let app = XCUIApplication()
            record(app, "Owned HTTP UI wait failure")
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "Owned HTTP UI wait failure AX"; tree.lifetime = .keepAlways; add(tree)
        }
        return arrived
    }
    private func record(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
    }
}

/// Complete bounded HTTP responses with FIN, owned by this test only.

final class HTTPAuthenticationUISite: @unchecked Sendable {
    private let queue = DispatchQueue(label: "owned-http-auth-site")
    private let listener: NWListener
    private var callback: ((Result<Void, Error>) -> Void)?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var stopped = false
    private var accepted = 0
    var port: UInt16 { listener.port!.rawValue }
    var authorizedCount: Int { queue.sync { accepted } }
    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }
    init() throws {
        let parameters = NWParameters.tcp; parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start(_ done: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            self.callback = done
            self.listener.stateUpdateHandler = { [weak self] state in
                guard let self, let done = self.callback else { return }
                switch state {
                case .ready: self.callback = nil; done(.success(()))
                case let .failed(error): self.callback = nil; done(.failure(error))
                case .cancelled: self.callback = nil; done(.failure(NSError(domain: "HTTPAuthenticationUISite", code: 2)))
                default: break
                }
            }
            self.listener.newConnectionHandler = { [weak self] connection in
                guard let self, !self.stopped else { connection.cancel(); return }
                self.connections[ObjectIdentifier(connection)] = connection
                connection.start(queue: self.queue); self.receive(connection, Data())
            }
            self.listener.start(queue: self.queue)
            self.queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, let done = self.callback else { return }
                self.callback = nil; self.listener.cancel()
                done(.failure(NSError(domain: "HTTPAuthenticationSite", code: 1)))
            }
        }
    }
    func stop() {
        queue.sync {
            stopped = true; listener.cancel()
            let done = callback; callback = nil; done?(.failure(NSError(domain: "HTTPAuthenticationUISite", code: 2)))
            connections.values.forEach { $0.cancel() }; connections = [:]
        }
    }
    private func receive(_ connection: NWConnection, _ previous: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, ended, error in
            guard let self else { connection.cancel(); return }
            var bytes = previous; if let data { bytes.append(data) }
            guard !self.stopped, error == nil, bytes.count <= 16_384 else { self.close(connection); return }
            guard let header = String(data: bytes, encoding: .utf8), header.contains("\r\n\r\n") else {
                if ended { self.close(connection) } else { self.receive(connection, bytes) }; return
            }
            let path = header.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let requiresAuth = path.hasPrefix("/auth")
            let authorized = header.components(separatedBy: "\r\n").contains { line in
                let parts = line.split(separator: ":", maxSplits: 1)
                return parts.count == 2 && parts[0].lowercased() == "authorization"
                    && parts[1].trimmingCharacters(in: .whitespaces) == "Basic b3duZWQ6Zml4dHVyZQ=="
            }
            if requiresAuth && authorized { self.accepted += 1 }
            let allowed = !requiresAuth || authorized
            let title = requiresAuth ? "Authenticated owned page" : "Owned page"
            let words = requiresAuth ? "actual authorized response" : "Owned action"
            // A document title isn't a visible DOM readiness marker. The UI
            // requires this real heading/status and a genuine page click.
            let body = allowed ? "<meta name='viewport' content='width=device-width,initial-scale=1'><style>body{padding:80px 20px 100px;font:18px -apple-system}</style><title>\(title)</title><h1>\(title)</h1><p id='status'>\(words)</p><button id='result' onclick='this.textContent=\"Page touched\";document.getElementById(\"status\").textContent=\"Page touched\"'>\(words)</button><a href='/auth'>Protected page</a>" : "Authentication cancelled"
            let response = "HTTP/1.1 \(allowed ? "200 OK" : "401 Unauthorized")\r\n" + (allowed ? "" : "WWW-Authenticate: Basic realm=\"Owned\"\r\n") + "Content-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in self?.close(connection) })
        }
    }
    private func close(_ connection: NWConnection) { connections[ObjectIdentifier(connection)] = nil; connection.cancel() }
}
