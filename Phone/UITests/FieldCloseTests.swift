import Network
import XCTest

/// Closing the real field returns touch ownership to the same browser page.
final class FieldCloseTests: XCTestCase {
    private var folder: URL!
    private var site: FieldCloseSite!

    override func setUpWithError() throws {
        continueAfterFailure = false
        folder = URL(fileURLWithPath: "/private/tmp/yab-field-close-\(UUID().uuidString)", isDirectory: true)
        site = try FieldCloseSite()
        let ready = expectation(description: "owned loopback page ready")
        site.start { ready.fulfill() }
        wait(for: [ready], timeout: 10)
    }

    override func tearDownWithError() throws {
        XCUIApplication().terminate()
        site?.stop()
        if let data = try? Data(contentsOf: folder.appendingPathComponent("profile.json")) {
            let receipt = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            receipt.name = "field-close-owned-profile"
            receipt.lifetime = .keepAlways
            add(receipt)
        }
        try? FileManager.default.removeItem(at: folder)
    }

    func testAddressAndTypedSearchCloseKeepURLHistoryDraftAndPageTouch() throws {
        let first = site.url.appendingPathComponent("one")
        let second = URL(string: "two?q=a%2Bb#part", relativeTo: site.url)!.absoluteURL
        let app = launch(url: first)
        let page = app.webViews.firstMatch
        XCTAssertTrue(page.staticTexts["Cyan orange page"].waitForExistence(timeout: 15))
        XCTAssertTrue(wait { self.currentTab()?["url"] as? String == first.absoluteString })
        openAddress(app, url: first)
        checkCloseTarget(app)
        record(app.screenshot(), "Address field over cyan orange page")
        close(app)
        touchPage(app, result: "Page action 1")
        page.links["Open green blue page"].tap()
        XCTAssertTrue(page.staticTexts["Green blue page"].waitForExistence(timeout: 10))
        XCTAssertTrue(wait { self.currentTab()?["url"] as? String == second.absoluteString })
        let id = try XCTUnwrap(currentTab()?["id"] as? String)
        XCTAssertTrue(wait { (try? self.navigation(id).count) == 3 }, "both real pages must reach saved history")
        let before = try navigation(id)

        openAddress(app, url: second)
        checkCloseTarget(app)
        record(app.screenshot(), "Address field over green blue page")
        close(app)
        openAddress(app, url: second)
        let input = app.textFields["field.input"]
        input.typeText("rain forecast tomorrow")
        // Typed over, the address gives way to the space's one card and its rows (ab780a23).
        XCTAssertTrue(app.buttons["field.best"].waitForExistence(timeout: 5))
        record(app.screenshot(), "Typed search close target")
        close(app)
        touchPage(app, result: "Page action 1")
        openAddress(app, draft: "rain forecast tomorrow")
        close(app)
        XCTAssertEqual(currentTab()?["id"] as? String, id)
        XCTAssertEqual(currentTab()?["url"] as? String, second.absoluteString)
        XCTAssertEqual(try navigation(id), before, "closing or typing must not create a history entry")
        XCTAssertEqual(site.count("/two"), 1, "Close must not reload")
        app.buttons["chrome.back"].tap()
        XCTAssertTrue(page.staticTexts["Cyan orange page"].waitForExistence(timeout: 10))
        XCTAssertTrue(wait { self.currentTab()?["url"] as? String == first.absoluteString })
    }

    func testNewTabCloseKeepsPublicDraftAndNeverKeepsPrivateWords() throws {
        let url = site.url.appendingPathComponent("one")
        let app = launch(url: url, privateAuthentication: "off")
        XCTAssertTrue(app.webViews.staticTexts["Cyan orange page"].waitForExistence(timeout: 15))
        XCTAssertTrue(wait { self.currentTab()?["url"] as? String == url.absoluteString })
        let id = try XCTUnwrap(currentTab()?["id"] as? String)
        app.buttons["chrome.plus"].tap()
        let input = app.textFields["field.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.typeText("public new tab draft")
        checkCloseTarget(app)
        record(app.screenshot(), "New tab close target with public draft")
        close(app)
        touchPage(app, result: "Page action 1")
        app.buttons["chrome.plus"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "public new tab draft")
        XCTAssertTrue(app.buttons["field.clearWords"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["field.eyes"].exists)
        // Keep the public draft. With words present, Private is entered
        // through New Private Tab rather than the input's clear button.
        close(app)
        app.buttons["chrome.plus"].press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["chrome.menu.newprivate"].waitForExistence(timeout: 5))
        app.buttons["chrome.menu.newprivate"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(app.descendants(matching: .any)["field.eyes"].value as? String, "on")
        input.typeText("private unsaved words")
        checkCloseTarget(app)
        record(app.screenshot(), "New tab close target with private words")
        close(app)
        touchPage(app, result: "Page action 2")
        app.buttons["chrome.plus"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "public new tab draft", "private words must not replace the public draft")
        XCTAssertTrue(app.buttons["field.clearWords"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["field.eyes"].exists)
        close(app)
        XCTAssertEqual(currentTab()?["id"] as? String, id)
        XCTAssertEqual(currentTab()?["url"] as? String, url.absoluteString)
        let saved = try String(contentsOf: folder.appendingPathComponent("profile.json"), encoding: .utf8)
        XCTAssertFalse(saved.contains("private unsaved words"))
        XCTAssertEqual(site.count("/one"), 1)
    }

    func testPrivatePageSearchCloseDropsDraftAndKeepsPrivatePageClickable() throws {
        let publicURL = site.url.appendingPathComponent("one")
        let privateURL = site.url.appendingPathComponent("two").appending(queryItems: [URLQueryItem(name: "private", value: "1")])
        let app = launch(url: publicURL, privateAuthentication: "off")
        XCTAssertTrue(app.webViews.staticTexts["Cyan orange page"].waitForExistence(timeout: 15))
        app.buttons["chrome.plus"].tap()
        let input = app.textFields["field.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        app.descendants(matching: .any)["field.eyes"].tap()
        input.typeText(privateURL.absoluteString)
        let go = app.keyboards.buttons.matching(NSPredicate(format: "label ==[c] 'go' OR identifier ==[c] 'go'")).firstMatch
        XCTAssertTrue(go.waitForExistence(timeout: 5))
        go.tap()
        XCTAssertTrue(wait { !input.exists && !app.keyboards.firstMatch.exists })
        XCTAssertTrue(app.webViews.staticTexts["Green blue page"].waitForExistence(timeout: 15))
        openAddress(app, url: privateURL)
        // The plate's field has no page card any more: its actions are the
        // page menu's (448423cb), so nothing here offers Ask or On Mac.
        XCTAssertFalse(app.descendants(matching: .any)["field.card"].exists)
        input.typeText("private page search draft")
        checkCloseTarget(app)
        record(app.screenshot(), "Private page typed search close target")
        close(app)
        touchPage(app, result: "Page action 1")
        openAddress(app, url: privateURL)
        close(app)
        let saved = try String(contentsOf: folder.appendingPathComponent("profile.json"), encoding: .utf8)
        XCTAssertFalse(saved.contains(privateURL.absoluteString))
        XCTAssertFalse(saved.contains("private page search draft"))
        XCTAssertEqual(site.count("/two"), 1)
    }

    private func launch(url: URL, privateAuthentication: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-YabProfileDirectory", folder.path, "-YabURL", url.absoluteString, "-YabNoAnim", "YES"]
        if let privateAuthentication {
            // Only the two close-route tests opt out of their isolated biometric gate.
            app.launchArguments += ["-YabPrivateLockTestAuthentication", privateAuthentication]
        }
        app.launchEnvironment = ["YAB_TEST": "1", "YAB_HAPTICS_SILENT": "1"]
        app.terminate()
        app.launch()
        let notNow = app.buttons["welcome.skip"]
        XCTAssertTrue(notNow.waitForExistence(timeout: 10))
        app.passWelcome()
        XCTAssertTrue(app.textFields["field.input"].waitForExistence(timeout: 5))
        close(app)
        return app
    }

    private func openAddress(_ app: XCUIApplication, url: URL? = nil, draft: String? = nil) {
        let plate = app.descendants(matching: .any)["chrome.plate"].firstMatch
        XCTAssertTrue(plate.waitForExistence(timeout: 5))
        let window = app.windows.firstMatch
        let frame = plate.frame
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX - window.frame.minX, dy: frame.midY - window.frame.minY)).tap()
        let input = app.textFields["field.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, draft ?? url?.absoluteString)
    }

    /// ✕ is its own glass circle 7 beside the field (65619b17),
    /// as tall as the field at any text size (33be1e46).
    private func checkCloseTarget(_ app: XCUIApplication) {
        let field = app.descendants(matching: .any)["field.frame"].frame
        let close = app.buttons["field.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertEqual(close.label, "Close")
        XCTAssertEqual(close.frame.width, field.height, accuracy: 1)
        XCTAssertEqual(close.frame.height, field.height, accuracy: 1)
        XCTAssertGreaterThanOrEqual(close.frame.height, 44)
        XCTAssertEqual(close.frame.midY, field.midY, accuracy: 1)
        XCTAssertEqual(close.frame.minX - field.maxX, 7, accuracy: 1, "✕ stands 7 beside the field")
        let shot = XCTAttachment(screenshot: close.screenshot())
        shot.name = "Native close circle beside the field"
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func close(_ app: XCUIApplication) {
        XCTAssertTrue(app.closeField(), "Close must dismiss the entire field and keyboard")
    }

    private func touchPage(_ app: XCUIApplication, result: String) {
        let action = app.webViews.buttons["Page touch action"]
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        XCTAssertTrue(wait { action.isHittable })
        action.tap()
        XCTAssertTrue(app.webViews.staticTexts[result].waitForExistence(timeout: 5), "the page must receive touch after Close")
    }

    private func currentTab() -> [String: Any]? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("profile.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let spaces = json["spaces"] as? [[String: Any]] else { return nil }
        return spaces.lazy.compactMap { space -> [String: Any]? in
            guard let current = space["current"] as? String, let today = space["today"] as? [[String: Any]] else { return nil }
            return today.first { $0["id"] as? String == current }
        }.first
    }

    private func navigation(_ id: String) throws -> [String] {
        let data = try Data(contentsOf: folder.appendingPathComponent("profile.json"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let all = try XCTUnwrap(json["navigation"] as? [String: [String: Any]])
        let state = try XCTUnwrap(all[id])
        let entries = try XCTUnwrap(state["entries"] as? [[String: Any]])
        let index = try XCTUnwrap(state["index"] as? Int)
        return [String(index)] + entries.compactMap { $0["url"] as? String }
    }

    private func record(_ screen: XCUIScreenshot, _ name: String) {
        let shot = XCTAttachment(screenshot: screen)
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func wait(_ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(10)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }
}

/// Bound HTTP header framing and FIN keep the owned server out of UI timing.
private final class FieldCloseSite {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "yab.field-close-site")
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var counts: [String: Int] = [:]
    var url: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/")! }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start(ready: @escaping () -> Void) {
        listener.stateUpdateHandler = { state in if case .ready = state { ready() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections[ObjectIdentifier(connection)] = connection
            connection.start(queue: self.queue)
            self.receive(connection, bytes: Data())
        }
        listener.start(queue: queue)
    }

    private func receive(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, done, error in
            guard let self else { connection.cancel(); return }
            var bytes = bytes
            if let data { bytes.append(data) }
            guard bytes.count <= 16_384, error == nil else { self.finish(connection); return }
            guard bytes.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if done { self.finish(connection) } else { self.receive(connection, bytes: bytes) }
                return
            }
            let request = String(decoding: bytes, as: UTF8.self)
            let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let route = target.components(separatedBy: "?")[0]
            self.counts[route, default: 0] += 1
            let second = route == "/two"
            let body = """
            <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="icon" href="data:,"><title>\(second ? "Green blue page" : "Cyan orange page")</title>
            <style>body{margin:0;min-height:200vh;font:20px system-ui;background:linear-gradient(90deg,\(second ? "#16af50 50%,#285bd9 50%" : "#00aade 50%,#ed7000 50%"))}h1,button,a,p{margin:24px}button{display:block;padding:16px}a{display:block}#detail{height:90px;background:repeating-linear-gradient(90deg,transparent 0 5px,#fff 5px 10px)}</style>
            <h1 id="part">\(second ? "Green blue page" : "Cyan orange page")</h1><button onclick="document.getElementById('result').textContent='Page action '+(++window.clicks)">Page touch action</button><p id="result"></p>
            \(second ? "" : "<a href='/two?q=a%2Bb#part'>Open green blue page</a>")<div id="detail"></div><script>window.clicks=0</script>
            """
            let response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
            connection.send(content: response, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { [weak self] _ in self?.finish(connection) })
        }
    }

    private func finish(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = nil
        connection.cancel()
    }

    func count(_ route: String) -> Int { queue.sync { counts[route, default: 0] } }
    func stop() {
        listener.cancel()
        queue.sync { connections.values.forEach { $0.cancel() }; connections.removeAll() }
    }
}
