import Network
import UIKit
import XCTest

/// Actual fingers exercise native WebKit dialogs and the production error pane.
final class BrowserFeedbackUITests: XCTestCase {
    private var site: FeedbackSite!
    private var folder: URL!
    override func setUpWithError() throws {
        continueAfterFailure = false
        folder = URL(fileURLWithPath:"/private/tmp/yab-browser-feedback-\(UUID().uuidString)",isDirectory:true)
        site = try FeedbackSite()
        let ready = expectation(description:"owned feedback listener ready")
        site.start { result in if case let .failure(error) = result { XCTFail("Owned listener failed: \(error)") }; ready.fulfill() }
        wait(for:[ready],timeout:10)
    }
    override func tearDownWithError() throws {
        XCUIApplication().terminate(); site?.stop()
        if let bytes = try? Data(contentsOf:folder.appendingPathComponent("profile.json")) {
            let attachment = XCTAttachment(data:bytes,uniformTypeIdentifier:"public.json")
            attachment.name="browser-feedback-owned-profile"; attachment.lifetime = .keepAlways; add(attachment)
        }
        try? FileManager.default.removeItem(at:folder)
    }
    func testNativeWebsiteDialogsAndRealRetryPreserveThePublicPageAndBack() throws { try journey(privateMode:false,largest:false) }
    func testPrivateLargestDialogsRetryAndPageTouchNeverPersistPrivateURLs() throws { try journey(privateMode:true,largest:true) }

    /// A tester's report (2026-10-12): offline, the error pane left the page the
    /// failed navigation started from showing under the toolbar and status bar.
    /// A refused connection fails provisionally, as no internet does: the old
    /// page stays. (A dropped one, `/drop`, is retried by the network stack and
    /// showed no error within 15 s on a loaded adhd.)
    func testFailedNavigationCoversThePageItStartedFromEdgeToEdge() throws {
        let app = try launch(largest:false)
        let page = app.webViews.firstMatch
        let refused = page.links["Open unreachable address"]
        reveal(page,refused); refused.tap()
        let error = app.staticTexts["page.error.title"]
        // localhost's refusal took 10 s and more on a loaded adhd.
        XCTAssertTrue(error.waitForExistence(timeout:45))
        XCTAssertTrue(wait(timeout:5) { !app.textFields["field.input"].exists && !app.keyboards.firstMatch.exists })
        RunLoop.current.run(until:Date().addingTimeInterval(1))
        let shot = app.screenshot()
        record(app,"Provisional failure covers the previous page")
        let pixels = try ScreenPixels(shot.image)
        // The pane's own surface, from empty space under its buttons.
        let surface = pixels.color(x:0.5,y:0.55)
        // Under the toolbar and over the status bar the old page (a cyan to
        // peach gradient) used to show; now it is the same surface.
        for (x,y) in [(0.02,0.995),(0.98,0.995),(0.02,0.93),(0.25,0.004),(0.98,0.004)] {
            let seen = pixels.color(x:x,y:y)
            XCTAssertTrue(seen.near(surface), "at (\(x),\(y)) saw \(seen), the pane is \(surface): the previous page shows through")
        }
        XCTAssertTrue(app.buttons["page.error.retry"].isHittable)
        // A link that fails leaves the tab at its address, as its error says.
        XCTAssertTrue(wait { self.currentTab()?["url"] as? String == FeedbackSite.unreachable },
                      "the tab is \(currentTab()?["url"] ?? "none") under the error for \(FeedbackSite.unreachable)")
    }

    /// A tester's report (2026-10-12): offline, an address typed over a page
    /// failed, and the field and tab stack went back to the page it started
    /// from while the error named the typed one. They say the failed address.
    func testFailedAddressFromTheFieldIsTheOneTheFieldShows() throws {
        let app = try launch(largest:false)
        let plate = app.buttons["chrome.plate"]
        XCTAssertTrue(wait { (plate.label as String).hasPrefix("127.0.0.1") })
        plate.tap()
        let input = app.textFields["field.input"]
        XCTAssertTrue(input.waitForExistence(timeout:5))
        input.typeText(FeedbackSite.unreachable)
        let go = app.keyboards.buttons.matching(NSPredicate(format:"label ==[c] 'go' OR identifier ==[c] 'go'")).firstMatch
        XCTAssertTrue(go.waitForExistence(timeout:5)); go.tap()
        XCTAssertTrue(app.staticTexts["page.error.title"].waitForExistence(timeout:45))
        XCTAssertTrue(wait { !input.exists && !app.keyboards.firstMatch.exists })
        XCTAssertEqual(app.staticTexts["page.error.title"].label, "Not answering")
        XCTAssertTrue(app.staticTexts["page.error.reason"].label.hasPrefix("localhost:59999"))
        // WebKit puts the old address back before it reports the failure;
        // give any late write the time it would take.
        RunLoop.current.run(until:Date().addingTimeInterval(1.5))
        record(app,"Failed typed address in the field")
        XCTAssertTrue(plate.label.hasPrefix("localhost"), "the field says \(plate.label) over the error for localhost:59999")
        XCTAssertTrue(wait { self.currentTab()?["url"] as? String == FeedbackSite.unreachable },
                      "the tab is \(currentTab()?["url"] ?? "none")")
        // The same pane in dark, for the colors.
        XCUIDevice.shared.appearance = .dark
        defer { XCUIDevice.shared.appearance = .light }
        RunLoop.current.run(until:Date().addingTimeInterval(1.5))
        record(app,"Failed typed address in the field, dark")
        // The status bar stands on the pane, not on the page the navigation
        // left (a tester's second picture: dark marks on the pane's dark).
        let dark = try ScreenPixels(app.screenshot().image)
        var brightest = 0
        for x in stride(from:0.10, to:0.26, by:0.004) { for y in stride(from:0.020, to:0.046, by:0.002) {
            let c = dark.color(x:x,y:y); brightest = max(brightest, min(c.r, c.g, c.b))
        } }
        XCTAssertGreaterThan(brightest, 180, "the clock over the dark pane is dark")
        XCUIDevice.shared.appearance = .light
        RunLoop.current.run(until:Date().addingTimeInterval(1))
        // The toolbar's Back (the pane has none) returns to the page the
        // failure started from, and the field says it again.
        app.buttons["chrome.back"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Owned dialog page"].waitForExistence(timeout:10))
        XCTAssertTrue(wait { (plate.label as String).hasPrefix("127.0.0.1") }, "after Back the field says \(plate.label)")
    }

    /// #350 (2026-10-22): back to Yab after a while away, the page
    /// iOS had stopped showed the error pane, its Retry dimmed and Refresh
    /// doing nothing. Now the page loads again when it is shown.
    /// The app ends its pages' processes itself as it goes to the background
    /// (-YabTestEndPagesAway), with WebKit's own kill, as iOS does.
    func testPageWhoseProcessEndedAwayLoadsAgainWhenBack() throws {
        let app = try launch(largest:false, extra:["-YabTestEndPagesAway","YES"])
        let page = app.webViews.firstMatch
        let error = app.staticTexts["page.error.title"]
        for round in 1...2 {
            let before = site.count("/page")
            XCUIDevice.shared.press(.home)
            // Long enough for the app to be suspended with its page gone.
            RunLoop.current.run(until:Date().addingTimeInterval(8))
            app.activate()
            // A stopped page has no document to read; WebKit may load it again
            // from its cache, so the page's own words and touch say it is
            // back, not the server's count. A cold web process on a loaded
            // farm Mac takes a while (37 s on adhd once).
            let loaded = wait(timeout:60) { page.staticTexts["Owned dialog page"].exists && !error.exists }
            record(app, "Back after the page's process ended away, round \(round)")
            if !loaded, error.exists {
                let retry = app.buttons["page.error.retry"]
                XCTFail("round \(round): the error pane '\(error.label)' shows; Retry enabled=\(retry.isEnabled); requests \(site.count("/page")) (were \(before))")
                return
            }
            XCTAssertTrue(loaded, "round \(round): the page never loaded again; requests \(site.count("/page")) (were \(before)), error=\(error.exists)")
            // The page is live: its own script answers a touch.
            button(page,"Page action").tap()
            XCTAssertTrue(page.staticTexts["Page action 1"].waitForExistence(timeout:5))
        }
        // Refresh works on the page brought back.
        let reload = app.buttons["chrome.reload"]
        if reload.waitForExistence(timeout:3) {
            let before = site.count("/page")
            XCTAssertTrue(wait { reload.isEnabled && reload.label == "Reload Page" }, "Reload is \(reload.label)")
            reload.tap()
            XCTAssertTrue(wait(timeout:15) { self.site.count("/page") > before }, "Refresh did nothing")
        }
    }

    private func journey(privateMode:Bool,largest:Bool) throws {
        let app = try launch(largest:largest)
        let page = app.webViews.firstMatch
        XCTAssertTrue(wait { self.currentTab()?["url"] as? String == self.site.url().absoluteString })
        let initialID = try XCTUnwrap(currentTab()?["id"] as? String)
        let url = privateMode ? site.url("/page?private=owned") : site.url()
        if privateMode {
            app.buttons["chrome.plus"].tap()
            let input = app.textFields["field.input"]
            XCTAssertTrue(input.waitForExistence(timeout:5))
            app.descendants(matching:.any)["field.eyes"].tap()
            XCTAssertEqual(app.descendants(matching:.any)["field.eyes"].value as? String,"on")
            input.typeText(url.absoluteString)
            let go = app.keyboards.buttons.matching(NSPredicate(format:"label ==[c] 'go' OR identifier ==[c] 'go'")).firstMatch
            XCTAssertTrue(go.waitForExistence(timeout:5)); go.tap()
            XCTAssertTrue(wait { !input.exists && !app.keyboards.firstMatch.exists })
            XCTAssertTrue(page.staticTexts["Owned dialog page"].waitForExistence(timeout:15))
            XCTAssertEqual(app.buttons["chrome.plus"].value as? String,"Private")
        }
        let origin = "127.0.0.1:\(site.port)"
        button(page,"Show alert").tap()
        let alert = app.alerts[origin]
        XCTAssertTrue(alert.waitForExistence(timeout:5))
        XCTAssertTrue(alert.staticTexts["Owned alert"].exists)
        record(app,privateMode ? "Private largest native website alert" : "Public native website alert")
        alert.buttons["OK"].tap()
        XCTAssertTrue(page.staticTexts["Alert dismissed"].waitForExistence(timeout:5))
        button(page,"Show confirm").tap()
        XCTAssertTrue(alert.waitForExistence(timeout:5))
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(page.staticTexts["Confirm false"].waitForExistence(timeout:5))
        button(page,"Show confirm").tap(); XCTAssertTrue(alert.waitForExistence(timeout:5))
        alert.buttons["OK"].tap()
        XCTAssertTrue(page.staticTexts["Confirm true"].waitForExistence(timeout:5))
        button(page,"Show prompt").tap(); XCTAssertTrue(alert.waitForExistence(timeout:5))
        let input = alert.textFields["page.javascript.input"]
        XCTAssertTrue(input.waitForExistence(timeout:5)); XCTAssertEqual(input.value as? String,"Seed")
        input.tap(); input.typeText(" reply")
        record(app,privateMode ? "Private largest native prompt" : "Public native prompt")
        alert.buttons["OK"].tap()
        XCTAssertTrue(page.staticTexts["Prompt Seed reply"].waitForExistence(timeout:5))
        button(page,"Show prompt").tap(); XCTAssertTrue(alert.waitForExistence(timeout:5))
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(page.staticTexts["Prompt cancelled"].waitForExistence(timeout:5))

        let broken = page.links["Open interrupted response"]
        reveal(page,broken); broken.tap()
        let error = app.staticTexts["page.error.title"]
        XCTAssertTrue(error.waitForExistence(timeout:10))
        let retry = app.buttons["page.error.retry"]
        reveal(app,retry)
        XCTAssertTrue(retry.isHittable)
        XCTAssertGreaterThanOrEqual(retry.frame.height + 4*app.windows.firstMatch.frame.height.ulp,44)
        XCTAssertGreaterThanOrEqual(retry.frame.width,44)
        let screen = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(retry.frame.minY,54)
        XCTAssertLessThanOrEqual(retry.frame.maxY,screen.height-34)
        record(app,privateMode ? "Private largest actual navigation failure" : "Public actual navigation failure")
        let before = site.count("/abort")
        let failedTimeline: [String]? = privateMode ? nil : (try timeline(initialID))
        site.allowResponse(); retry.tap()
        XCTAssertTrue(page.staticTexts["Recovered page"].waitForExistence(timeout:15))
        XCTAssertTrue(wait { !error.exists })
        XCTAssertEqual(site.count("/abort"),before+1)
        if !privateMode {
            XCTAssertTrue(wait { self.currentTab()?["url"] as? String == self.site.url("/abort").absoluteString })
            XCTAssertEqual(currentTab()?["id"] as? String,initialID)
            XCTAssertEqual(try timeline(initialID),failedTimeline, "Retry must not append a duplicate history entry")
        }
        button(page,"Page action").tap()
        XCTAssertTrue(page.staticTexts["Page action 1"].waitForExistence(timeout:5))
        record(app,privateMode ? "Private actual Retry page touch" : "Public actual Retry page touch")
        app.buttons["chrome.back"].tap()
        XCTAssertTrue(page.staticTexts["Owned dialog page"].waitForExistence(timeout:10))
        button(page,"Page action").tap()
        XCTAssertTrue(page.staticTexts["Page action 1"].waitForExistence(timeout:5))
        let saved = try String(contentsOf:folder.appendingPathComponent("profile.json"),encoding:.utf8)
        if privateMode {
            XCTAssertFalse(saved.contains("private=owned")); XCTAssertFalse(saved.contains("/abort"))
            XCTAssertFalse(saved.contains("Seed reply"))
            XCTAssertEqual(currentTab()?["id"] as? String,initialID)
            XCTAssertEqual(app.buttons["chrome.plus"].value as? String,"Private")
        } else {
            XCTAssertTrue(wait { self.currentTab()?["url"] as? String == self.site.url().absoluteString })
            XCTAssertEqual(try timeline(initialID), ["0", url.absoluteString, site.url("/abort").absoluteString],
                           "Decoded exact URLs and Back's current index must survive, independent of JSON slash escaping")
            XCTAssertEqual(currentTab()?["id"] as? String,initialID)
        }
    }
    private func currentTab() -> [String:Any]? {
        guard let bytes = try? Data(contentsOf:folder.appendingPathComponent("profile.json")),
              let profile = try? JSONSerialization.jsonObject(with:bytes) as? [String:Any],
              let spaces = profile["spaces"] as? [[String:Any]] else { return nil }
        guard let selected = profile["spaceID"] as? String,
              let space = spaces.first(where: { $0["id"] as? String == selected }),
              let id = space["current"] as? String,
              let tabs = space["today"] as? [[String:Any]] else { return nil }
        return tabs.first { $0["id"] as? String == id }
    }
    private func timeline(_ id:String) throws -> [String] {
        let bytes = try Data(contentsOf:folder.appendingPathComponent("profile.json"))
        let profile = try XCTUnwrap(try JSONSerialization.jsonObject(with:bytes) as? [String:Any])
        let navigation = try XCTUnwrap(profile["navigation"] as? [String:[String:Any]])
        let state = try XCTUnwrap(navigation[id])
        let entries = try XCTUnwrap(state["entries"] as? [[String:Any]])
        return [String(try XCTUnwrap(state["index"] as? Int))] + entries.compactMap { $0["url"] as? String }
    }
    private func launch(largest:Bool, extra:[String] = []) throws -> XCUIApplication {
        let app=XCUIApplication()
        app.launchEnvironment=["YAB_TEST":"1","YAB_HAPTICS_SILENT":"1"]
        app.launchArguments=["-YabProfileDirectory",folder.path,"-YabURL",site.url().absoluteString,
                             "-YabPrivateLockTestAuthentication","off"] + extra
        if largest { app.launchArguments += ["-UIPreferredContentSizeCategoryName","UICTContentSizeCategoryAccessibilityXXXL"] }
        app.terminate(); app.launch()
        let join = app.buttons["join.close"]
        let ready = wait(timeout:15) {
            app.buttons["welcome.start"].exists || app.textFields["field.input"].exists
                || app.webViews.staticTexts["Owned dialog page"].exists || join.exists
        }
        let identityFile = folder.appendingPathComponent("website-data-store.json")
        let ownedIdentityExists = FileManager.default.fileExists(atPath: identityFile.path)
        let arrival: [String: Any] = ["owned_profile_identity_exists": ownedIdentityExists,
            "join_visible": join.exists, "welcome_visible": app.buttons["welcome.start"].exists,
            "field_visible": app.textFields["field.input"].exists,
            "owned_page_visible": app.webViews.staticTexts["Owned dialog page"].exists,
            "owned_page_requests": site.count("/page"), "app_state": app.state.rawValue]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: arrival, options: [.sortedKeys]),
                                      uniformTypeIdentifier: "public.json")
        attachment.name = "browser-feedback-owned-launch-arrival"
        attachment.lifetime = .keepAlways
        add(attachment)
        record(app, "Browser feedback actual launch arrival")
        XCTAssertTrue(ready, "the actual owned launch never showed a recognized surface")
        // A transient Join may cover the first launch. Never dismiss an
        // unrelated profile or accept its page as this test's owned browser.
        XCTAssertTrue(ownedIdentityExists, "the requested disposable profile was not initialized")
        let identity = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: identityFile)) as? [String: Any])
        XCTAssertEqual(identity["version"] as? Int, 1)
        _ = try XCTUnwrap((identity["dataStoreID"] as? String).flatMap(UUID.init(uuidString:)))
        if join.exists {
            XCTAssertTrue(join.isHittable)
            join.tap()
            XCTAssertTrue(wait { !join.exists }, "the actual Join close left the page covered")
        }
        // The page draws before the welcome's tray rises over it (1.3 s in): wait for it.
        app.passWelcome(timeout: 6)
        if app.textFields["field.input"].waitForExistence(timeout:2) { app.closeField() }
        XCTAssertTrue(wait { !app.textFields["field.input"].exists && !app.keyboards.firstMatch.exists })
        // A cold first launch on a loaded farm Mac draws late.
        XCTAssertTrue(app.webViews.staticTexts["Owned dialog page"].waitForExistence(timeout:45))
        return app
    }
    private func button(_ page:XCUIElement,_ label:String) -> XCUIElement {
        let result=page.buttons[label]; reveal(page,result); XCTAssertTrue(result.isHittable); return result
    }
    private func reveal(_ container:XCUIElement,_ element:XCUIElement) {
        for _ in 0..<4 {
            let frame=element.frame, screen=XCUIApplication().windows.firstMatch.frame
            if element.isHittable && frame.minY>=54 && frame.maxY<=screen.height-90 { return }
            let window=XCUIApplication().windows.firstMatch
            let start=window.coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.65))
            start.press(forDuration:0.05,thenDragTo:window.coordinate(withNormalizedOffset:.init(dx:0.5,dy:frame.minY<54 ? 0.9 : 0.3)),withVelocity:.slow,thenHoldForDuration:0)
        }
    }
    private func wait(timeout:TimeInterval=10,_ check:()->Bool) -> Bool {
        let end=Date().addingTimeInterval(timeout)
        while Date()<end { if check() { return true }; RunLoop.current.run(until:Date().addingTimeInterval(0.05)) }
        return check()
    }
    private func record(_ app:XCUIApplication,_ name:String) {
        let attachment=XCTAttachment(screenshot:app.screenshot()); attachment.name=name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

/// A screenshot's pixels as RGBA, read by fractions of its size.
private struct ScreenPixels {
    struct RGB: CustomStringConvertible {
        let r: Int, g: Int, b: Int
        func near(_ other: RGB, tolerance: Int = 10) -> Bool {
            abs(r - other.r) <= tolerance && abs(g - other.g) <= tolerance && abs(b - other.b) <= tolerance
        }
        var description: String { "rgb(\(r),\(g),\(b))" }
    }
    let width: Int, height: Int
    private let bytes: [UInt8]
    init(_ image: UIImage) throws {
        let cg = try XCTUnwrap(image.cgImage)
        let width = cg.width, height = cg.height
        self.width = width; self.height = height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drawn)
        self.bytes = buffer
    }
    func color(x: Double, y: Double) -> RGB {
        let px = min(width - 1, max(0, Int(Double(width) * x)))
        let py = min(height - 1, max(0, Int(Double(height) * y)))
        let i = (py * width + px) * 4
        return RGB(r: Int(bytes[i]), g: Int(bytes[i + 1]), b: Int(bytes[i + 2]))
    }
}

/// Only this test owns the listener, requests and connections. No dev server.
private final class FeedbackSite: @unchecked Sendable {
    private let queue = DispatchQueue(label: "owned-browser-feedback-http")
    private let listener: NWListener
    private var ready: ((Result<Void, Error>) -> Void)?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var stopped = false
    private var aborts = true
    private var counts: [String: Int] = [:]
    var port: UInt16 { listener.port!.rawValue }
    /// Nothing listens there: the connection is refused at once.
    static let unreachable = "http://localhost:59999/refused"
    func url(_ path: String = "/page") -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }
    func count(_ path: String) -> Int { queue.sync { counts[path, default: 0] } }
    func allowResponse() { queue.sync { aborts = false } }
    func failResponse() { queue.sync { aborts = true } }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start(_ completed: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            self.ready = completed
            self.listener.stateUpdateHandler = { [weak self] state in
                guard let self, let callback = self.ready else { return }
                switch state {
                case .ready: self.ready = nil; callback(.success(()))
                case let .failed(error): self.ready = nil; callback(.failure(error))
                case .cancelled: self.ready = nil; callback(.failure(NSError(domain: "FeedbackSite", code: 2)))
                default: break
                }
            }
            self.listener.newConnectionHandler = { [weak self] connection in
                guard let self, !self.stopped else { connection.cancel(); return }
                self.connections[ObjectIdentifier(connection)] = connection
                connection.start(queue: self.queue)
                self.receive(connection, Data())
            }
            self.listener.start(queue: self.queue)
            self.queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, let callback = self.ready else { return }
                self.ready = nil; self.listener.cancel()
                callback(.failure(NSError(domain: "FeedbackSite", code: 1)))
            }
        }
    }
    func stop() {
        queue.sync {
            stopped = true
            let callback = ready; ready = nil
            callback?(.failure(NSError(domain: "FeedbackSite", code: 2)))
            listener.cancel()
            for connection in connections.values { connection.cancel() }
            connections = [:]
        }
    }
    private func receive(_ connection: NWConnection, _ previous: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            guard let self else { connection.cancel(); return }
            var bytes = previous; if let data { bytes.append(data) }
            guard !self.stopped, error == nil, bytes.count <= 16_384 else { self.close(connection); return }
            // The TLS test connects to this owned TCP port. Send a real fatal
            // handshake alert, never an accepted certificate or a trust bypass.
            if bytes.first == 0x16 {
                self.send(Data([0x15,0x03,0x03,0x00,0x02,0x02,0x28]), to: connection)
                return
            }
            guard let header = String(data: bytes, encoding: .utf8), header.contains("\r\n\r\n") else {
                if done { self.close(connection) } else { self.receive(connection, bytes) }
                return
            }
            let target = header.components(separatedBy: " ").dropFirst().first ?? "/page"
            let route = target.components(separatedBy: "?").first ?? target
            self.counts[route, default: 0] += 1
            if route == "/drop" {
                // No bytes at all: the navigation fails before it commits, as
                // it does offline, and the page it started from stays.
                self.close(connection)
                return
            }
            if route == "/abort", self.aborts {
                // The native engine commits real bytes, then observes an
                // incomplete response body and FIN. No injected failure callback.
                let partial = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 100000\r\nConnection: close\r\n\r\n<!doctype html><title>Interrupted response</title><p>Interrupted response</p>"
                self.send(Data(partial.utf8), to: connection)
                return
            }
            let title = route == "/abort" ? "Recovered page" : route == "/second" ? "Second page" : "Owned dialog page"
            let body = """
            <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><title>\(title)</title><link rel=icon href=data:,>
            <style>body{margin:0;padding:20px;font:20px system-ui;background:linear-gradient(120deg,#c2fbff,#ffd0a0);min-height:100vh}button,a{display:block;margin:14px 0;padding:14px;font:inherit}output{display:block;min-height:44px}</style></head><body>
            <h1>\(title)</h1><button onclick="alert('Owned alert');document.getElementById('result').textContent='Alert dismissed'">Show alert</button>
            <button onclick="document.getElementById('result').textContent='Confirm '+confirm('Owned confirmation')">Show confirm</button>
            <button onclick="let v=prompt('Owned prompt','Seed');document.getElementById('result').textContent=v===null?'Prompt cancelled':'Prompt '+v">Show prompt</button>
            <button onclick="window.actions=(window.actions||0)+1;document.getElementById('result').textContent='Page action '+window.actions">Page action</button>
            <output id=result>Ready for dialogs</output><a href="/abort">Open interrupted response</a><a href="/second">Open second page</a><a href="/drop">Open dropped address</a><a href="\(FeedbackSite.unreachable)">Open unreachable address</a></body></html>
            """
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            self.send(Data(response.utf8), to: connection)
        }
    }
    private func send(_ bytes: Data, to connection: NWConnection) {
        connection.send(content: bytes, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] _ in
            guard let self else { connection.cancel(); return }
            self.queue.async { self.close(connection) }
        })
    }
    private func close(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = nil
        connection.cancel()
    }
}
