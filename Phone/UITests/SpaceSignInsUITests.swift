import Network
import XCTest

/// Real UI, owned HTTP pages, profile, cookie jars and localStorage. No World.
final class SpaceSignInsUITests: XCTestCase {
    private var folder: URL!
    private var site: SpaceSignInsSite!
    private var app: XCUIApplication!
    private let target = "local.personal"
    private let other = "local.other"
    private let tabID = "owned.signins.page"

    override func setUpWithError() throws {
        continueAfterFailure = false
        folder = URL(fileURLWithPath: "/private/tmp/yab-signins-ui-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        site = try SpaceSignInsSite()
        let ready = expectation(description: "owned sign-in HTTP listener")
        site.start { ready.fulfill() }; wait(for: [ready], timeout: 5)
        XCTAssertTrue(site.ready)
        let page: [String: Any] = ["id": tabID, "title": "Owned sign-in page", "site": "Owned sign-in page", "icon": "globe", "url": site.url.absoluteString, "dark": false]
        let selected: [String: Any] = ["id": target, "name": "Research", "emoji": "📚", "tint": [168, 195, 160],
            "ownSignIns": false, "pins": [], "kept": [], "today": [page], "current": tabID, "pinsOpen": false, "private": false]
        let blank: [String: Any] = ["id": "owned.other.blank", "title": "New Tab", "site": "New Tab", "icon": "globe", "url": "about:blank", "dark": false]
        let unselected: [String: Any] = ["id": other, "name": "Other", "emoji": "🌐", "tint": [208, 223, 237],
            "ownSignIns": false, "pins": [], "kept": [], "today": [blank], "current": "owned.other.blank", "pinsOpen": false, "private": false]
        let profile: [String: Any] = ["version": 1, "spaceID": target, "spaces": [selected, unselected], "navigation": [:], "visits": []]
        try JSONSerialization.data(withJSONObject: profile, options: [.sortedKeys]).write(to: folder.appendingPathComponent("profile.json"), options: .atomic)
        app = XCUIApplication()
        app.launchArguments = ["-YabProfileDirectory", folder.path, "-YabURL", site.url.absoluteString, "-YabNoAnim", "YES"]
        app.launchEnvironment = ["YAB_TEST": "1", "YAB_HAPTICS_SILENT": "1"]
    }
    override func tearDownWithError() throws {
        app?.terminate(); site?.stop(); site = nil
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }
    private func wait(_ condition: () -> Bool, timeout: TimeInterval = 10) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if condition() { return true }; RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        return condition()
    }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private func launch(reopening: Bool = false) {
        if reopening { app.launchArguments = ["-YabProfileDirectory", folder.path, "-YabNoAnim", "YES"] }
        app.terminate(); app.launch()
        let notNow = app.buttons["welcome.skip"]
        XCTAssertTrue(wait { notNow.exists || self.element("chrome.plate").exists })
        // The page draws before the welcome's tray rises over it (1.3 s in): wait for it.
        app.passWelcome(timeout: 6)
        if app.textFields["field.input"].exists { app.closeField() }
        XCTAssertTrue(wait { !self.app.textFields["field.input"].exists && self.element("chrome.plate").exists
            && self.app.staticTexts["Owned sign-in page"].exists && self.app.webViews.buttons["Store Shared"].isHittable
            && self.element("chrome.reload").exists && self.element("chrome.reload").label == "Reload Page" })
    }
    private func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        let window = app.windows.firstMatch
        return window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x - window.frame.minX, dy: y - window.frame.minY))
    }
    private func tap(_ control: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(wait { control.exists && control.isHittable }, file: file, line: line)
        // 44 to hit (AX frames come back a hair under, 43.99999).
        XCTAssertGreaterThanOrEqual(control.frame.height, 43.99, file: file, line: line)
        XCTAssertGreaterThanOrEqual(control.frame.width, 43.99, file: file, line: line)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(control.frame), file: file, line: line)
        point(control.frame.midX, control.frame.midY).tap()
    }
    /// The spaces' gear: Settings over the spaces.
    private func openSettingsFromGear() {
        SpacesGesture.open(in: app)
        XCTAssertTrue(wait { self.element("newtab.spaces").exists && self.app.buttons["newtab.settings"].isHittable })
        tap(app.buttons["newtab.settings"])
    }
    private func openSettingsSignIns() {
        openSettingsFromGear()
        XCTAssertTrue(wait { self.app.buttons["settings.row.spaces"].isHittable })
        tap(app.buttons["settings.row.spaces"]); tap(app.buttons["settings.space.\(target)"])
        XCTAssertTrue(wait { self.app.buttons["space.signins.own"].isHittable && self.app.buttons["settings.back"].isHittable })
    }
    /// Settings has one head (a1c21478): ‹ on a page, × only at the root.
    private func closeSettings() {
        let back = app.buttons["settings.back"]
        for _ in 0..<6 where back.exists && back.isHittable {
            tap(back)
            _ = wait { self.app.buttons["settings.close"].isHittable || back.isHittable }
        }
        tap(app.buttons["settings.close"])
        XCTAssertTrue(wait { !self.element("settings.sheet").exists })
        // Settings closes to the spaces it was opened from; ✕ puts them away.
        if element("newtab.spaces").exists { tap(app.buttons["field.close"]) }
        XCTAssertTrue(wait { !self.element("newtab.spaces").exists && self.element("chrome.plate").exists })
    }
    private func choose(_ own: Bool, cancel: Bool = false) {
        tap(app.buttons[own ? "space.signins.own" : "space.signins.shared"])
        let alert = app.alerts["Change Sign-ins?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Unsaved changes may be lost'")).firstMatch.exists)
        shot(own ? "signins-owned-change-alert" : "signins-shared-change-alert")
        tap(alert.buttons[cancel ? "Cancel" : "Change Sign-ins"])
        XCTAssertTrue(wait { !alert.exists })
        XCTAssertFalse(element("space.signins.unavailable").exists)
        let expected = cancel ? !own : own
        XCTAssertTrue(wait { self.app.buttons[expected ? "space.signins.own" : "space.signins.shared"].value as? String == "Selected" })
    }
    private func seedShared() {
        let button = app.webViews.buttons["Store Shared"]
        XCTAssertTrue(wait { button.isHittable }); button.tap()
        XCTAssertTrue(app.staticTexts["Shared sign-in restored"].waitForExistence(timeout: 5))
        let form = app.webViews.textFields["Unsaved form"]
        XCTAssertTrue(form.isHittable); form.tap(); form.typeText("owned-unsaved-form")
        let finish = app.webViews.buttons["Finish Editing"]
        XCTAssertTrue(finish.isHittable); finish.tap()
        XCTAssertTrue(wait { !self.app.keyboards.firstMatch.exists && form.value as? String == "owned-unsaved-form" })
    }
    private func emptyForm() {
        let form = app.webViews.textFields["Unsaved form"]
        XCTAssertTrue(wait { form.exists })
        let value = form.value as? String
        XCTAssertTrue(value == nil || value == "" || value == form.placeholderValue)
    }
    private func profile() -> [String: Any]? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("profile.json")) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    private func profileSpaceID() -> String? { profile()?["spaceID"] as? String }
    private func space() -> [String: Any]? { (profile()?["spaces"] as? [[String: Any]])?.first { $0["id"] as? String == target } }
    private func own() -> Bool? { space()?["ownSignIns"] as? Bool }
    private func metadata() throws -> Data {
        let space = try XCTUnwrap(space())
        return try JSONSerialization.data(withJSONObject: space.filter { ["id", "name", "emoji", "tint", "look", "current", "today", "kept", "pins"].contains($0.key) }, options: [.sortedKeys])
    }
    private func history() throws -> Data {
        let map = try XCTUnwrap(profile()?["navigation"] as? [String: [String: Any]])
        let state = try XCTUnwrap(map[tabID])
        let entries = try XCTUnwrap(state["entries"] as? [[String: Any]])
        // Opening keyboard/another space may legitimately checkpoint scroll.
        // The complete portable URL/title chain and index must not change.
        return try JSONSerialization.data(withJSONObject: ["entries": entries.map { $0.filter { ["url", "title"].contains($0.key) } },
            "index": try XCTUnwrap(state["index"])], options: [.sortedKeys])
    }
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func verifyRestoredSharedAndRelaunch(metadata: Data, history: Data, identity: Data) throws {
        XCTAssertTrue(wait { self.app.staticTexts["Shared sign-in restored"].exists && self.app.webViews.buttons["Store Shared"].isHittable })
        XCTAssertEqual(site.latestCookie, "scope=shared")
        emptyForm(); XCTAssertEqual(try self.metadata(), metadata); XCTAssertEqual(try self.history(), history)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("website-data-store.json")), identity)
        shot("signins-shared-native-cookie-localStorage-restored")
        app.terminate(); launch(reopening: true)
        XCTAssertTrue(app.staticTexts["Shared sign-in restored"].waitForExistence(timeout: 10))
        XCTAssertEqual(site.latestCookie, "scope=shared"); XCTAssertFalse(try XCTUnwrap(own()))
        XCTAssertEqual(try self.metadata(), metadata); XCTAssertEqual(try self.history(), history)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("website-data-store.json")), identity)
        app.webViews.buttons["Page action"].tap()
        XCTAssertTrue(app.staticTexts["Worked 1"].waitForExistence(timeout: 5))
        shot("signins-relaunch-shared-original-tab-history-and-real-touch")
    }

    func testCurrentSpaceChangeAndCancelUseActualNativeStoresAndRestoreSharedAfterRelaunch() throws {
        launch(); seedShared()
        XCTAssertTrue(wait { (self.profile()?["navigation"] as? [String: Any])?[self.tabID] != nil })
        let metadata = try metadata(), history = try history()
        let identity = try Data(contentsOf: folder.appendingPathComponent("website-data-store.json")), requests = site.count
        openSettingsSignIns(); choose(true, cancel: true)
        XCTAssertFalse(try XCTUnwrap(own())); closeSettings()
        XCTAssertEqual(site.count, requests)
        XCTAssertEqual(app.webViews.textFields["Unsaved form"].value as? String, "owned-unsaved-form")
        openSettingsSignIns(); choose(true); XCTAssertTrue(wait { self.own() == true }); closeSettings()
        XCTAssertTrue(wait { self.app.staticTexts["No stored sign-in"].exists && self.site.count > requests })
        XCTAssertEqual(site.latestCookie, ""); emptyForm()
        app.webViews.buttons["Store Own"].tap(); XCTAssertTrue(app.staticTexts["Own sign-in restored"].waitForExistence(timeout: 5))
        shot("signins-settings-own-isolated-real-page")
        openSettingsSignIns(); choose(false); XCTAssertTrue(wait { self.own() == false }); closeSettings()
        try verifyRestoredSharedAndRelaunch(metadata: metadata, history: history, identity: identity)
    }
}

/// Complete bounded HTTP header framing and owned normal FIN responses.
private final class SpaceSignInsSite: @unchecked Sendable {
    private let queue = DispatchQueue(label: "yab.ui.signins")
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private var pageRequests = 0
    private var cookie = ""
    private var didStart = false
    private var port: UInt16 = 0
    private var onReady: (() -> Void)?
    var ready: Bool { queue.sync { didStart } }
    var count: Int { queue.sync { pageRequests } }
    var latestCookie: String { queue.sync { cookie } }
    var url: URL { queue.sync { URL(string: "http://127.0.0.1:\(port)/page#source")! } }
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection); connection.start(queue: self.queue); self.receive(connection, prior: Data())
        }
    }
    func start(_ ready: @escaping () -> Void) {
        queue.async {
            self.onReady = ready
            self.listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .ready = state { self.port = self.listener.port!.rawValue; self.didStart = true; self.onReady?(); self.onReady = nil }
            }
            self.listener.start(queue: self.queue)
        }
    }
    func stop() {
        queue.sync {
            listener.newConnectionHandler = nil; listener.stateUpdateHandler = nil; listener.cancel()
            connections.forEach { $0.cancel() }; connections = []; onReady = nil
        }
    }
    private func receive(_ connection: NWConnection, prior: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] bytes, _, end, error in
            guard let self, error == nil else { connection.cancel(); return }
            var data = prior; if let bytes { data.append(bytes) }
            guard data.count <= 65_536 else { connection.cancel(); return }
            guard let request = String(data: data, encoding: .utf8), request.contains("\r\n\r\n") else {
                if !end { self.receive(connection, prior: data) } else { connection.cancel() }; return
            }
            let path = request.components(separatedBy: " ").dropFirst().first ?? "/"
            let body: Data
            if path == "/page" {
                self.pageRequests += 1
                self.cookie = request.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("cookie:") }
                    .map { String($0.dropFirst(7)).trimmingCharacters(in: .whitespaces) } ?? ""
                body = Data(Self.page.utf8)
            } else { body = Data() }
            let response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8) + body
            connection.send(content: response, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
    private static let page = """
    <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><title>Owned sign-in page</title>
    <style>body{font:18px -apple-system;background:#fff;color:#222;padding:24px}h1{font-size:22px;margin:10px 0}p{margin:8px 0}button,input{display:block;box-sizing:border-box;min-height:48px;font:18px -apple-system;margin:8px 0;padding:8px;max-width:100%}</style>
    <h1>Owned sign-in page</h1><p id="state" aria-live="polite"></p>
    <button onclick="store('shared')">Store Shared</button><button onclick="store('own')">Store Own</button>
    <input aria-label="Unsaved form" placeholder="Unsaved form"><button onclick="document.activeElement.blur()">Finish Editing</button><button onclick="document.getElementById('worked').textContent='Worked '+(++count)">Page action</button><p id="worked">Worked 0</p>
    <script>let count=0;function render(){const s=localStorage.getItem('scope');document.getElementById('state').textContent=s==='shared'?'Shared sign-in restored':s==='own'?'Own sign-in restored':'No stored sign-in'}function store(s){document.cookie='scope='+s+';path=/;max-age=86400';localStorage.setItem('scope',s);render()}render()</script>
    """
}
