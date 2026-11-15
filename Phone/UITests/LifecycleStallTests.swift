import Network
import XCTest

/// Crashes 43, 44, 53, 62, 63, 67 and 86: iOS's watchdog killed Yab because
/// its main thread did not answer a scene update in 10 s, or an exit in 5 s,
/// every time inside SwiftUI's update of the window (PageHost, the + menu).
/// This walks a real profile through what a person does around those kills:
/// a scrolled page, a turn to landscape and back, Home and back twice, and
/// the end of the process, with the app's own stall journal on
/// (Testing/MainStalls). No busy stretch of the main thread may come near
/// the watchdog's budget, and none may stay stuck.
final class LifecycleStallTests: XCTestCase {
    private var server: LifecycleTestSite!
    private var folder: URL!
    private var journal: URL!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let id = UUID().uuidString
        folder = URL(fileURLWithPath: "/tmp/yab-lifecycle-stalls-\(id)")
        journal = URL(fileURLWithPath: "/tmp/yab-lifecycle-stalls-\(id).jsonl")
        server = try LifecycleTestSite()
        let ready = expectation(description: "site ready")
        server.ready = { ready.fulfill() }
        server.start()
        wait(for: [ready], timeout: 10)
        // Many tabs, as the people the watchdog stopped had.
        let tabs: [[String: Any]] = (0..<40).map { index in
            ["id": "life.\(index)", "title": "Life page \(index)", "site": "Life page \(index)", "icon": "globe",
             "url": server.url(index).absoluteString]
        }
        let space: [String: Any] = ["id": "life.space", "name": "Life", "emoji": "", "tint": [238, 233, 226],
                                    "current": "life.2", "today": tabs]
        let profile: [String: Any] = ["version": 1, "spaceID": "life.space", "spaces": [space],
                                      "navigation": [String: Any](), "visits": [Any]()]
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: profile).write(to: folder.appendingPathComponent("profile.json"), options: .atomic)
    }

    override func tearDownWithError() throws {
        if let journal, let text = try? String(contentsOf: journal, encoding: .utf8) {
            let attachment = XCTAttachment(string: text)
            attachment.name = "main thread stalls"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCUIDevice.shared.orientation = .portrait
        app?.terminate()
        server?.stop()
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.removeItem(at: journal)
    }

    func testLifecycleNeverHoldsTheMainThreadNearTheWatchdog() throws {
        app = XCUIApplication()
        app.launchArguments = ["-YabProfileDirectory", folder.path, "-YabNoAnim", "NO"]
        app.launchEnvironment = ["YAB_TEST": "1", "YAB_HAPTICS_SILENT": "1", "YAB_STALLS_OUT": journal.path]
        app.terminate()
        app.launch()
        let notNow = app.buttons["welcome.start"]
        XCTAssertTrue(notNow.waitForExistence(timeout: 15))
        app.passWelcome()
        XCTAssertTrue(app.textFields["field.input"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.closeField(), "the welcome's New Tab field stayed over the page")
        XCTAssertTrue(app.webViews.staticTexts["Life page 2"].waitForExistence(timeout: 20))
        mark("ready")
        let ready = Date().timeIntervalSince1970

        let page = app.webViews.firstMatch
        page.swipeUp(velocity: .slow)
        page.swipeUp(velocity: .fast)
        pause(1.5)
        page.swipeDown(velocity: .slow)
        pause(1)
        mark("scrolled")

        XCUIDevice.shared.orientation = .landscapeLeft
        pause(2)
        XCUIDevice.shared.orientation = .portrait
        pause(2)
        mark("turned")

        for round in 1...2 {
            XCUIDevice.shared.press(.home)
            pause(4)
            app.activate()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "round \(round): Yab came back")
            pause(2)
            mark("home \(round)")
        }

        // Home from landscape: iOS turns the scene back upright for its
        // pictures while Yab is already in the background (crash 44's
        // viewport, sampled in the background).
        XCUIDevice.shared.orientation = .landscapeLeft
        pause(2)
        XCUIDevice.shared.press(.home)
        pause(4)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "Yab came back after landscape")
        pause(2)
        XCUIDevice.shared.orientation = .portrait
        pause(2)
        mark("home from landscape")

        XCUIDevice.shared.press(.home)
        pause(3)
        let exit = Date()
        app.terminate()
        let exitSeconds = Date().timeIntervalSince(exit)
        pause(1)
        mark("terminated in \(String(format: "%.2f", exitSeconds)) s")

        let lines = try String(contentsOf: journal, encoding: .utf8).split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        // Launch has its own, longer budget; this is about what comes after.
        let after = lines.filter { ($0["at"] as? Double ?? 0) > ready }
        let busy = after.filter { $0["event"] as? String == "busy" }
        let stuck = after.filter { $0["event"] as? String == "stuck" }
        let worst = busy.max { ($0["busy_ms"] as? Double ?? 0) < ($1["busy_ms"] as? Double ?? 0) }
        let summary = "exit \(String(format: "%.2f", exitSeconds)) s; \(busy.count) stretches over 100 ms; "
            + "worst \(worst.map { "\($0["busy_ms"] ?? 0) ms in \($0["phase"] ?? "?") \($0["counts"] ?? [:])" } ?? "none"); "
            + "stuck \(stuck.count)"
        print("LIFECYCLE-STALLS \(summary)")
        let attachment = XCTAttachment(string: summary)
        attachment.name = "stall summary"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(stuck.isEmpty, "the main thread stayed busy past 2 s: \(stuck)")
        XCTAssertLessThan(worst?["busy_ms"] as? Double ?? 0, 1500, summary)
        XCTAssertLessThan(exitSeconds, 4, "Yab must end well inside iOS's 5 s exit budget")
    }

    private func mark(_ step: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = step
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}

/// Long real pages over loopback, one per tab.
private final class LifecycleTestSite {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "yab.lifecycle-test-site")
    private var connections: [NWConnection] = []
    var ready: (() -> Void)?

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func url(_ index: Int) -> URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/life/\(index)")! }

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
            var request = data
            if let chunk { request.append(chunk) }
            guard request.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if done || error != nil || request.count > 65_536 { connection.cancel() }
                else { self.receive(connection, data: request) }
                return
            }
            let line = String(decoding: request, as: UTF8.self)
            let route = line.components(separatedBy: " ").dropFirst().first ?? ""
            let number = route.split(separator: "/").last.flatMap { Int($0) } ?? -1
            let paragraphs = (0..<60).map { "<p>Paragraph \($0) of a long page, enough to scroll and fold the chrome.</p>" }.joined()
            let html = """
            <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="icon" href="data:,"><title>Life page \(number)</title>
            <style>body{margin:0;font:18px system-ui;background:#eef6ea}h1{margin:16px}p{margin:16px}</style>
            <h1>Life page \(number)</h1>\(paragraphs)
            """
            let body = Data(html.utf8)
            var response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
            response.append(body)
            connection.send(content: response, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in
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
