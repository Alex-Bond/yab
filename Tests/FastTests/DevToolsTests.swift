import AppKit
import Foundation
import JavaScriptCore
import Testing
@testable import Fast

// Developer Tools' layout (DevHead.swift, DevTools.swift): the row in
// the usual DevTools order, a device drawn to fit its room, what the
// inspector kept from before the card listened, and a recording in words.
struct DevToolsTests {
    @Test func theRowIsChromesOrder() {
        #expect(DevTab.allCases.map(\.title) == ["Elements", "Console", "Sources", "Network", "Performance", "Memory",
                                                "Application", "Security", "Audit", "Recorder", "Graphics", "Layers"])
        // Chrome's names where the thing is the same; WebKit's tab behind each.
        #expect(DevTab.performance.pane == .performance)
        #expect(DevTab.application.pane == .application)
        #expect(DevTab.network.pane == .network)
        // WebKit's own Network is never offered; named so where its
        // inspector goes to it by itself.
        #expect(WebPane.requests.title == "WebKit Network")
    }

    /// #383: every pane is kept as a word and read back as itself.
    @Test func panesAreKeptAsWords() {
        let panes: [DevPane] = [.errors, .warnings, .network, .security, .recorder, .console, .elements, .sources, .performance,
                                .memory, .application, .audit, .layers, .panel("Components ⚛")] + WebPane.allCases.map { .webkit($0) }
        for pane in panes { #expect(DevPane(saved: pane.saved) == pane) }
        #expect(DevPane(saved: "nonsense") == nil)
        #expect(DevPane(saved: "webkit:Nope") == nil)
    }

    /// #383: device mode and its device are kept as a hand leaves them,
    /// the scale held under a pulled edge not among them.
    @MainActor @Test func deviceModeIsKeptForTheNextTime() {
        let keys = ["dev.device", "dev.device.on"]
        let before = keys.map { Store.settings.object(forKey: $0) }
        defer { for (key, value) in zip(keys, before) { Store.settings.set(value, forKey: key) } }
        var phone = DeviceMode(name: "iPhone 16", width: 393, height: 852, userAgent: DeviceMode.iPhone, zoom: 0.75)
        phone.held = 0.5
        DevMemory.remember(phone)
        #expect(DevMemory.deviceOn)
        #expect(DevMemory.device == DeviceMode(name: "iPhone 16", width: 393, height: 852, userAgent: DeviceMode.iPhone, zoom: 0.75))
        DevMemory.remember(nil)
        #expect(!DevMemory.deviceOn)
        // Off, the device stays, to come back as it was.
        #expect(DevMemory.device?.name == "iPhone 16")
    }

    @MainActor @Test func anExtensionsPanelIsWebKitsAndComesBackWithTheNextPage() {
        #expect(DevPane.panel("Components ⚛").isWebKit)
        let browser = Browser(windowID: UUID())
        defer { try? FileManager.default.removeItem(at: Store.file("session-window-\(browser.windowID!.uuidString).json")) }
        // Its page's inspector went while it showed: Elements stands in,
        // and the next inspector to have it shows it again.
        browser.panelWanted = "Components ⚛"
        browser.devPane = .webkit(.elements)
        browser.panelsCame([DevPanel(id: "WebExtensionTab-react-1", title: "Components ⚛")])
        #expect(browser.devPane == .panel("Components ⚛"))
        #expect(browser.panelWanted == nil)
        // WebKit can initially restore Console instead of Elements.
        browser.panelWanted = "Components ⚛"
        browser.devPane = .webkit(.console)
        browser.panelsCame([DevPanel(id: "WebExtensionTab-react-2", title: "Components ⚛")])
        #expect(browser.devPane == .panel("Components ⚛"))
        #expect(browser.panelWanted == nil)
        // Its extension took it away: Elements.
        browser.devPane = .panel("Profiler ⚛")
        browser.panelsCame([DevPanel(id: "WebExtensionTab-react-1", title: "Components ⚛")])
        #expect(browser.devPane == .elements)
        // Picked by hand, nothing is wanted back.
        browser.panelWanted = "Components ⚛"
        browser.pickDevPane(.webkit(.console))
        #expect(browser.panelWanted == nil)
    }

    /// Elements is Yab's own: a remembered WebKit Elements, left by Inspect
    /// Element, must not bring WebKit's view back on ⌥⌘I.
    @MainActor @Test func rememberedWebKitElementsOpensYabsElements() {
        let was = Store.settings.string(forKey: "dev.pane")
        defer { Store.settings.set(was, forKey: "dev.pane") }
        DevMemory.pane = .webkit(.elements)
        #expect(DevMemory.pane == .elements)
        DevMemory.pane = .webkit(.graphics)
        #expect(DevMemory.pane == .webkit(.graphics))
        DevMemory.pane = .panel("Components ⚛")
        #expect(DevMemory.pane == .webkit(.elements))
    }

    /// #200: inspect mode is Elements' own; on Console the pointer over the
    /// page went on drawing nodes.
    @MainActor @Test func leavingElementsEndsInspectMode() {
        let browser = Browser(windowID: UUID())
        defer { try? FileManager.default.removeItem(at: Store.file("session-window-\(browser.windowID!.uuidString).json")) }
        browser.devPicking = true
        browser.pickDevPane(.elements)
        #expect(browser.devPicking)
        browser.pickDevPane(.webkit(.elements))
        #expect(browser.devPicking)
        browser.pickDevPane(.console)
        #expect(!browser.devPicking)
        browser.devPicking = true
        browser.pickDevPane(.network)
        #expect(!browser.devPicking)
    }

    /// #269: the card asked for comes out a frame later (moveDev). Put
    /// away within that frame it stayed away; it came out anyway, over
    /// whatever tab was in front by then.
    @MainActor @Test func aCardPutAwayBeforeItIsOutStaysAway() async {
        let browser = Browser(windowID: UUID())
        defer { try? FileManager.default.removeItem(at: Store.file("session-window-\(browser.windowID!.uuidString).json")) }
        let tab = Tab()
        #expect(!browser.devComing)
        // As openDevTools leaves it: heard, on its way out.
        browser.listened = tab
        browser.moveDev(open: true, side: .bottom)
        #expect(browser.devComing)
        #expect(!browser.devOpen)
        browser.closeDevTools()
        #expect(browser.listened == nil)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(!browser.devOpen)
        #expect(!browser.devComing)
        // Out with nothing in its way, as ever.
        browser.listened = tab
        browser.moveDev(open: true, side: .bottom)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(browser.devOpen)
        browser.listened = nil
    }

    @Test func webKitsTabsByTheirType() {
        #expect(WebPane(type: "timeline") == .timelines)
        #expect(WebPane(type: "storage") == .storage)
        #expect(WebPane(type: "search") == .search)
        #expect(WebPane(type: "settings") == .settings)
        #expect(WebPane.memory.type == "timeline")
        #expect(WebPane(type: "nothing") == nil)
    }

    @Test func aDeviceFitsItsRoomAndNeverGrows() {
        let phone = DeviceMode(name: "iPhone 16", width: 393, height: 852)
        // Room for it whole: drawn at its own size, centered under the bar.
        let big = CGSize(width: 1200, height: 1000)
        #expect(phone.scale(in: big) == 1)
        let frame = phone.frame(in: big)
        #expect(frame.width == 393 && frame.height == 852)
        #expect(frame.minY == DeviceMode.bar)
        #expect(abs(frame.midX - 600) <= 1)
        // A short room: drawn smaller, its whole height in.
        let short = CGSize(width: 1200, height: 404)
        let scale = phone.scale(in: short)
        #expect(scale < 1)
        #expect(phone.frame(in: short).maxY <= 404 - DeviceMode.air + 1)
        // Asked for a zoom, drawn at it.
        var zoomed = phone
        zoomed.zoom = 0.5
        #expect(zoomed.scale(in: short) == 0.5)
    }

    @Test func aPulledEdgeStaysUnderTheHand() {
        let room = CGSize(width: 1200, height: 1000)
        let phone = DeviceMode(name: "iPhone 16", width: 393, height: 852, userAgent: DeviceMode.iPhone)
        // The right edge 50 points out: the device in the middle grows both
        // ways, 100 points wider, and is Responsive, in Yab's own agent.
        let wider = phone.pulled(.right, by: CGSize(width: 50, height: 30), in: room)
        #expect(wider.width == 493 && wider.height == 852)
        #expect(wider.name == DeviceMode.responsive && wider.userAgent == nil)
        #expect(wider.held == 1)
        // The left one the other way, the bottom once, the corner both.
        #expect(phone.pulled(.left, by: CGSize(width: 50, height: 0), in: room).width == 293)
        #expect(phone.pulled(.bottom, by: CGSize(width: 40, height: -52), in: room).width == 393)
        #expect(phone.pulled(.bottom, by: CGSize(width: 40, height: -52), in: room).height == 800)
        let corner = phone.pulled(.bottomLeft, by: CGSize(width: -10, height: 8), in: room)
        #expect(corner.width == 413 && corner.height == 860)
        // Never past the room, never under Chrome's 50.
        let most = DeviceMode.room(in: room)
        #expect(phone.pulled(.right, by: CGSize(width: 900, height: 0), in: room).width == most.width)
        #expect(phone.pulled(.bottom, by: CGSize(width: 0, height: 900), in: room).height == most.height)
        #expect(phone.pulled(.right, by: CGSize(width: -900, height: 0), in: room).width == DeviceMode.smallest)
        // Drawn at half, the hand's points are twice the page's.
        var tablet = DeviceMode(name: DeviceMode.responsive, width: 1000, height: 1000)
        tablet.held = 0.5
        #expect(tablet.pulled(.bottom, by: CGSize(width: 0, height: 10), in: room).height == 1020)
        // Larger than the room already: taken, it stays where it was.
        var huge = DeviceMode(name: DeviceMode.responsive, width: 3000, height: 800)
        huge.zoom = 1
        #expect(huge.pulled(.right, by: CGSize(width: 5, height: 0), in: room).width == 3000)
        #expect(huge.pulled(.right, by: CGSize(width: -5, height: 0), in: room).width == 2990)
        // Let go, Fit fits again.
        var released = wider
        released.held = nil
        #expect(released.scale(in: room) == 1)
    }

    @Test func theBottomTwiceIsAsTallAsTheRoom() {
        let room = CGSize(width: 1200, height: 1000)
        let phone = DeviceMode(name: "Pixel 9", width: 412, height: 923, userAgent: DeviceMode.android)
        let tall = phone.fullHeight(in: room)
        #expect(tall.height == DeviceMode.room(in: room).height)
        #expect(tall.width == 412 && tall.name == DeviceMode.responsive && tall.userAgent == nil)
        #expect(tall.scale(in: room) == 1)
        // Wider than the room: as tall as it holds at the width's scale.
        let wide = DeviceMode(name: DeviceMode.responsive, width: 2320, height: 500).fullHeight(in: room)
        #expect(wide.scale(in: room) == 0.5)
        #expect(wide.height == 1880)
    }

    @MainActor @Test func earlyWordsCountOnceAndOnlyFromBeforeListening() {
        let log = DevLog()
        let started = Date()
        log.heardFrom = started.addingTimeInterval(5)
        let before = started.addingTimeInterval(1).timeIntervalSince1970 * 1000
        let after = started.addingTimeInterval(9).timeIntervalSince1970 * 1000
        log.early(level: "error", text: "boom 1", source: "app.js", line: 3, at: before, stack: "")
        log.early(level: "error", text: "boom 2", source: "app.js", line: 3, at: before, stack: "")
        log.early(level: "warning", text: "old API", source: "", line: 0, at: before, stack: "")
        // Said after the page's own script listened: it hears that itself.
        log.early(level: "error", text: "later", source: "", line: 0, at: after, stack: "")
        // Not an error or a warning.
        log.early(level: "log", text: "hello", source: "", line: 0, at: before, stack: "")
        #expect(log.counts.errors == 1)
        #expect(log.counts.warnings == 1)
        #expect(log.entries.first { $0.level == .error }?.count == 2)
        #expect(log.entries.first { $0.level == .error }?.source == "app.js:3")
        // The inspector hands its whole console over again each time it
        // connects: the same message, said at the same moment, once.
        log.early(level: "error", text: "boom 1", source: "app.js", line: 3, at: before, stack: "")
        log.early(level: "warning", text: "old API", source: "", line: 0, at: before, stack: "")
        #expect(log.entries.first { $0.level == .error }?.count == 2)
        #expect(log.entries.first { $0.level == .warning }?.count == 1)
        // A repeat of it, the inspector's second copy, counts.
        log.early(level: "warning", text: "old API", source: "", line: 0, at: before, copy: 1, stack: "")
        #expect(log.entries.first { $0.level == .warning }?.count == 2)
        // A page never listened to late takes nothing from the inspector.
        let local = DevLog()
        local.early(level: "error", text: "x", source: "", line: 0, at: before, stack: "")
        #expect(local.entries.isEmpty)
    }

    @MainActor @Test func aRecordingSaidInWords() {
        typealias Step = Recorder.Step
        #expect(Recorder.words(Step(kind: .navigate, url: "http://localhost:3000/cart")) == "Go to localhost:3000/cart")
        #expect(Recorder.words(Step(kind: .click, label: "Buy")) == "Click “Buy”")
        #expect(Recorder.words(Step(kind: .change, value: "hello", label: "Search")) == "Type “hello” in “Search”")
        #expect(Recorder.words(Step(kind: .change, label: "Password", secret: true)) == "Type a hidden value in “Password”")
        #expect(Recorder.words(Step(kind: .key, value: "Enter")) == "Press Return")
    }

    @Test func aPlaceReadOffAStack() {
        let frame = DevPlace("render@https://example.com/js/app.js:14:22")
        #expect(frame?.url == "https://example.com/js/app.js")
        #expect(frame?.line == 14 && frame?.column == 22)
        #expect(frame?.short == "app.js:14")
        #expect(DevPlace("at http://localhost:3000/:7")?.short == "localhost:7")
        #expect(DevPlace("global code") == nil)
    }

    @MainActor @Test func theAgentsPieceSaysWhatWentWrongOnce() {
        let page = URL(string: "http://localhost:3000/cart")!
        let error = DevLog.Entry(id: "e", level: .error, text: "TypeError: x is undefined", stack: "render@http://localhost:3000/app.js:14:22\nlist@http://localhost:3000/app.js:88:5",
                                 source: "", count: 3, last: Date())
        let warning = DevLog.Entry(id: "w", level: .warning, text: "Deprecated", stack: "", source: "http://localhost:3000/app.js:2:1", count: 1, last: Date())
        let failed = DevLog.Request(id: 1, method: "GET", url: "http://localhost:3000/api/items?token=secret123", status: 500, ms: 320, kind: "fetch",
                                    failure: nil, requestBody: nil, responseBody: "<html><body><h1>Oops</h1></body></html>", headers: [:])
        let text = DevCopy.pack([.said(error), .said(warning), .request(failed)], console: ["[log] hi"], page: page, size: CGSize(width: 800, height: 600),
                                options: DevCopy.PackOptions(page: true, bodies: true))
        #expect(text.hasPrefix("## localhost:3000/cart: 1 error, 1 warning, 1 failed request, 1 console line"))
        #expect(text.contains("### Error: TypeError: x is undefined ×3"))
        #expect(text.contains("  at app.js:14:22 · render"))
        #expect(text.contains("### Warning: Deprecated"))
        #expect(text.contains("- GET /api/items?token=… → 500, 320 ms"))
        #expect(text.contains("  → Oops"))
        #expect(!text.contains("secret123"))
        #expect(text.contains("### Console\n[log] hi"))
        let bare = DevCopy.pack([.said(error)], page: page, size: nil, options: DevCopy.PackOptions(page: false, bodies: false))
        #expect(!bare.contains("Page http"))
    }

    @Test func anHTMLBodyIsItsWords() {
        #expect(DevCopy.short("<!DOCTYPE html><html><head><style>p{}</style></head><body><h1>Error</h1>\n<p>Not found</p></body></html>") == "Error Not found")
        #expect(DevCopy.short("{\"error\": \"timeout\"}") == "{\"error\": \"timeout\"}")
    }

    @Test func rowsArePickedAsFinderPicks() {
        let ids = ["a", "b", "c", "d", "e"]
        var picking = IssuePicking()
        // A click: that row alone; again: none.
        picking.click("b", in: ids, shift: false, command: false)
        #expect(picking.picked == ["b"])
        picking.click("b", in: ids, shift: false, command: false)
        #expect(picking.picked.isEmpty)
        // ⇧: the run from the anchor, in place of what was picked.
        picking.click("b", in: ids, shift: false, command: false)
        picking.click("d", in: ids, shift: true, command: false)
        #expect(picking.picked == ["b", "c", "d"])
        picking.click("a", in: ids, shift: true, command: false)
        #expect(picking.picked == ["a", "b"])
        // ⌘ and the box: one in or out, the rest kept.
        picking.click("e", in: ids, shift: false, command: true)
        #expect(picking.picked == ["a", "b", "e"])
        picking.toggle("a")
        #expect(picking.picked == ["b", "e"])
        // ⇧⌘ adds the run from the last pick.
        picking.click("c", in: ids, shift: true, command: true)
        #expect(picking.picked == ["a", "b", "c", "e"])
        // ⌘A, then a search that hides some: they are no longer picked.
        picking.all(ids)
        #expect(picking.picked.count == 5)
        picking.keep(["b", "d"])
        #expect(picking.picked == ["b", "d"])
        picking.none()
        #expect(picking.picked.isEmpty && picking.anchor == nil)
    }

    // ↑ and ↓ in a Styles value step the first number that stands
    // alone, its unit kept; numbers inside words left as they are.
    @Test func arrowsStepAValue() {
        #expect(DevNudge.step("10px", up: true, by: 1) == "11px")
        #expect(DevNudge.step("10px", up: false, by: 10) == "0px")
        #expect(DevNudge.step("0.5", up: true, by: 0.1) == "0.6")
        #expect(DevNudge.step("-4px 8px", up: true, by: 1) == "-3px 8px")
        #expect(DevNudge.step("translate3d(10px, 0, 0)", up: true, by: 1) == "translate3d(11px, 0, 0)")
        #expect(DevNudge.step("#1e90ff", up: true, by: 1) == nil)
        #expect(DevNudge.step("auto", up: true, by: 1) == nil)
        #expect(DevNudge.step("1.5em", up: true, by: 100) == "101.5em")
    }

    // The color picker writes a color the way the value wrote it.
    @Test func swatchWritesItsOwnWay() {
        let blue = NSColor(srgbRed: 0, green: 128.0 / 255, blue: 1, alpha: 1)
        #expect(DevSwatch.write(blue, like: "#ff0000") == "#0080ff")
        #expect(DevSwatch.write(blue, like: "rgb(255, 0, 0)") == "rgb(0, 128, 255)")
        #expect(DevSwatch.write(blue.withAlphaComponent(0.5), like: "rgba(1, 2, 3, 0.2)") == "rgba(0, 128, 255, 0.5)")
        #expect(DevSwatch.write(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), like: "hsl(10, 50%, 50%)") == "hsl(0, 100%, 50%)")
        #expect(DevSwatch.token(in: "1px solid #ccc") == "#ccc")
        let red = DevSwatch.color("hsl(0, 100%, 50%)")?.usingColorSpace(.sRGB)
        #expect(red.map { abs($0.redComponent - 1) < 0.01 && $0.greenComponent < 0.01 && $0.blueComponent < 0.01 } == true)
    }

    // A pretty printed file's lines and the page's places, both ways.
    @Test func prettyLinesMapBothWays() {
        // `function f(){a();b()}` on one line, shown on four.
        let pretty = DevPretty(text: "function f() {\n    a();\n    b()\n}", back: [[0, 0], [0, 13], [0, 17], [0, 20]])
        #expect(pretty.original(2).line == 0 && pretty.original(2).column == 17)
        #expect(pretty.shown(0, column: 17) == 2)
        #expect(pretty.shown(0, column: 15) == 1)
        #expect(pretty.shown(0) == 0)
    }
}
