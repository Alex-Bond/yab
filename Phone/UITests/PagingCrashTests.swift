import Network
import XCTest

/// Actual finger swipes over real loopback pages, including pool eviction.
final class PagingCrashTests: XCTestCase {
    private var server: PagingTestSite!
    private var folder: URL!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        folder = URL(fileURLWithPath: "/tmp/yab-paging-crash-\(UUID().uuidString)")
        server = try PagingTestSite()
        let ready = expectation(description: "paging site ready")
        server.ready = { ready.fulfill() }
        server.start()
        wait(for: [ready], timeout: 10)
        let tabs: [[String: Any]] = (0..<5).map { index in
            ["id": "paging.\(index)", "title": "Swipe page \(index)", "site": "Swipe page \(index)", "icon": "globe",
             "url": server.url(index).absoluteString]
        }
        let space: [String: Any] = ["id": "paging.space", "name": "Paging", "emoji": "", "tint": [238,233,226],
                                   "current": "paging.2", "today": tabs]
        let profile: [String: Any] = ["version": 1, "spaceID": "paging.space", "spaces": [space],
                                     "navigation": [String: Any](), "visits": [Any]()]
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: profile).write(to: folder.appendingPathComponent("profile.json"), options: .atomic)
    }

    override func tearDownWithError() throws {
        if let server {
            let receipt = XCTAttachment(string: server.receipt)
            receipt.name = "owned loopback request timing"
            receipt.lifetime = .keepAlways
            add(receipt)
        }
        if let app {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "paging final native screen"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            app.terminate()
        }
        server?.stop()
        try? FileManager.default.removeItem(at: folder)
    }

    func testRapidAndShortPublicSwipesKeepRealPageAndTouchesAlive() throws {
        launch()
        try exercise(order: [0,1,2,3,4], initial: 2)
        XCTAssertTrue(wait { self.savedCurrent() == "paging.2" })
        let data = try Data(contentsOf: folder.appendingPathComponent("profile.json"))
        let profile = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let spaces = try XCTUnwrap(profile["spaces"] as? [[String: Any]])
        let tabs = try XCTUnwrap(spaces.first?["today"] as? [[String: Any]])
        XCTAssertEqual(tabs.compactMap { $0["id"] as? String }, (0..<5).map { "paging.\($0)" })
        XCTAssertEqual(tabs.compactMap { $0["url"] as? String }, (0..<5).map { server.url($0).absoluteString })
        let navigation = try XCTUnwrap(profile["navigation"] as? [String: Any])
        for index in 0..<5 {
            let state = try XCTUnwrap(navigation["paging.\(index)"] as? [String: Any])
            let entries = try XCTUnwrap(state["entries"] as? [[String: Any]])
            XCTAssertEqual(entries.compactMap { $0["url"] as? String }, [server.url(index).absoluteString],
                           "tab paging must not append duplicate navigation entries")
            XCTAssertEqual(state["index"] as? Int, 0)
        }
    }

    func testRapidAndShortPrivateSwipesKeepPrivatePagesTransient() throws {
        launch(privateAuthentication: "off")
        for index in [10,11,12] { openPrivate(index) }
        try exercise(order: [12,11,10], initial: 0)
        let data = try Data(contentsOf: folder.appendingPathComponent("profile.json"))
        let text = String(decoding: data, as: UTF8.self)
        for index in [10,11,12] {
            XCTAssertFalse(text.contains(server.url(index).absoluteString), "a private swipe must not persist its URL")
        }
        // Three private tabs: the right button is their stack.
        XCTAssertTrue(app.buttons["chrome.plus"].label.hasPrefix("Previous tab, Swipe page"))
        XCTAssertEqual(app.buttons["chrome.plus"].value as? String, "Private")
    }

    private func launch(privateAuthentication: String? = nil) {
        app = XCUIApplication()
        app.launchArguments = ["-YabProfileDirectory", folder.path, "-YabNoAnim", "NO"]
        if let privateAuthentication { app.launchArguments += ["-YabPrivateLockTestAuthentication", privateAuthentication] }
        app.launchEnvironment = ["YAB_TEST": "1", "YAB_HAPTICS_SILENT": "1"]
        app.terminate()
        app.launch()
        let notNow = app.buttons["welcome.start"]
        XCTAssertTrue(notNow.waitForExistence(timeout: 10))
        app.passWelcome()
        let input = app.textFields["field.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertTrue(app.closeField(), "the welcome's New Tab field stayed over the page")
        XCTAssertTrue(app.webViews.staticTexts["Swipe page 2"].waitForExistence(timeout: 15))
    }

    private func openPrivate(_ index: Int) {
        let plus = app.buttons["chrome.plus"]
        XCTAssertTrue(wait { plus.isHittable })
        app.openNewTabFromChrome()
        let input = app.textFields["field.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let eyes = app.descendants(matching: .any)["field.eyes"].firstMatch
        if eyes.value as? String != "on" { eyes.tap() }
        XCTAssertEqual(eyes.value as? String, "on")
        let emptyValue = input.value as? String
        XCTAssertTrue(emptyValue == nil || emptyValue == "" ||
                      (input.placeholderValue != nil && emptyValue == input.placeholderValue),
                      "a new private tab starts with no retained address")
        input.typeText(server.url(index).absoluteString)
        XCTAssertEqual(input.value as? String, server.url(index).absoluteString, "the field contains this exact owned URL before Go")
        let go = app.keyboards.buttons.matching(NSPredicate(format: "label ==[c] 'go' OR identifier ==[c] 'go'")).firstMatch
        XCTAssertTrue(go.isHittable)
        go.tap()
        XCTAssertTrue(wait { !input.exists })
        XCTAssertTrue(app.webViews.staticTexts["Swipe page \(index)"].waitForExistence(timeout: 15))
    }

    private func exercise(order: [Int], initial: Int) throws {
        var index = initial
        let plate = app.descendants(matching: .any)["chrome.plate"].firstMatch
        func selected() -> Bool {
            app.descendants(matching: .any).matching(NSPredicate(
                format: "identifier == %@ AND label CONTAINS %@", "chrome.plate", "Swipe page \(order[index])"
            )).firstMatch.exists && app.webViews.staticTexts["Swipe page \(order[index])"].exists
        }
        for target in Array(order.indices) + Array(order.indices.reversed()) + [initial] {
            while index != target {
                let step = target > index ? 1 : -1
                dragPlate(CGFloat(-step) * 180, velocity: .fast)
                index += step
                XCTAssertTrue(wait { selected() && plate.exists }, "a committed swipe must show its actual page")
                XCTAssertEqual(app.state, .runningForeground)
            }
            dragPlate(-45, velocity: .slow)
            let reload = app.descendants(matching: .any)["chrome.reload"].firstMatch
            XCTAssertTrue(wait {
                plate.exists && selected() && reload.exists && reload.isEnabled
                    && !app.descendants(matching: .any)["paging.blank"].exists
            }, "a short swipe must finish settling on the same page before its controls return")
            XCTAssertFalse(app.descendants(matching: .any)["paging.blank"].exists)
        }
        let page = app.webViews.firstMatch
        page.swipeUp(velocity: .slow)
        XCTAssertTrue(wait { plate.value as? String == "folded" })
        // A horizontal touch on the folded capsule must not switch tabs.
        dragPlate(-60, velocity: .slow)
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertFalse(app.textFields["field.input"].exists,
                       "a horizontal drag on the folded capsule must not act as an address tap")
        XCTAssertTrue(selected())
        page.swipeDown(velocity: .slow)
        XCTAssertTrue(wait { plate.value as? String == "open" })
        let button = page.buttons["Swipe page action"]
        XCTAssertTrue(button.isHittable)
        button.tap()
        XCTAssertTrue(page.staticTexts["Swipe page action worked \(order[index])"].waitForExistence(timeout: 5),
                      "the selected real page must receive touches after all swipes")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "paging \(order.first! < 10 ? "public" : "private") restored real page"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func dragPlate(_ dx: CGFloat, velocity: XCUIGestureVelocity) {
        let plate = app.descendants(matching: .any)["chrome.plate"].firstMatch
        XCTAssertTrue(plate.exists)
        let window = app.windows.firstMatch
        let point = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: plate.frame.midX - window.frame.minX, dy: plate.frame.midY - window.frame.minY))
        point.press(forDuration: 0.05, thenDragTo: point.withOffset(CGVector(dx: dx, dy: 0)),
                    withVelocity: velocity, thenHoldForDuration: 0.05)
    }

    private func savedCurrent() -> String? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("profile.json")),
              let profile = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let spaces = profile["spaces"] as? [[String: Any]] else { return nil }
        return spaces.first?["current"] as? String
    }

    private func wait(_ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(10)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }
}

private final class PagingTestSite {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "yab.paging-test-site")
    private var connections: [NWConnection] = []
    private let started = ProcessInfo.processInfo.systemUptime
    private var events: [String] = []

    var receipt: String { queue.sync { events.joined(separator: "\n") } }

    private func note(_ event: String) {
        events.append(String(format: "%.3f %@", ProcessInfo.processInfo.systemUptime - started, event))
    }
    var ready: (() -> Void)?

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func url(_ index: Int) -> URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/tab/\(index)?q=a%2Bb#part")! }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.ready?() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.receive(connection, data: Data())
        }
        listener.start(queue: queue)
    }

    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] chunk, _, done, error in
            guard let self else { connection.cancel(); return }
            var requestData = data
            if let chunk { requestData.append(chunk) }
            guard requestData.count <= 65_536 else {
                self.note("oversized request rejected")
                connection.cancel()
                return
            }
            guard requestData.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if done || error != nil { connection.cancel() }
                else { self.receive(connection, data: requestData) }
                return
            }
            let request = String(decoding: requestData, as: UTF8.self)
            let route = request.components(separatedBy: " ").dropFirst().first ?? ""
            let number = route.split(separator: "?").first?.split(separator: "/").last.flatMap { Int($0) } ?? -1
            let html = """
            <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="icon" href="data:,"><title>Swipe page \(number)</title>
            <style>body{margin:0;min-height:350vh;font:20px system-ui;background:#d7efff}h1{margin:16px}nav{position:fixed;top:25%;left:20px}button{padding:14px}</style>
            <h1 id="part">Swipe page \(number)</h1><nav><button onclick="document.getElementById('result').textContent='Swipe page action worked \(number)'">Swipe page action</button><p id="result"></p></nav>
            """
            let body = Data(html.utf8)
            var response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
            response.append(body)
            self.note("response queued tab=\(number) bytes=\(response.count)")
            connection.send(content: response, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] error in
                self?.note("response sent tab=\(number) error=\(error.map { String(describing: $0) } ?? "none")")
                if error != nil { connection.cancel() }
            })
        }
    }

    func stop() {
        listener.cancel()
        queue.sync {
            for connection in connections { connection.cancel() }
            connections = []
        }
    }
}
