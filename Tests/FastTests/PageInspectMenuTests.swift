import AppKit
import Testing
import WebKit
@testable import Fast

@MainActor @Suite(.serialized)
struct PageInspectMenuTests {
    init() throws {
        try #require(Store.testing && Store.world != nil && Store.settings !== UserDefaults.standard)
        _ = NSApplication.shared
    }

    private final class NativeInspect: NSObject {
        var received: NSMenuItem?
        var run: () -> Void = {}

        @objc func inspect(_ item: NSMenuItem) {
            received = item
            run()
        }
    }

    private func menu(_ native: NativeInspect) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(NSMenuItem(title: "Reload", action: nil, keyEquivalent: ""))
        let inspect = NSMenuItem(title: "Inspect Element", action: #selector(NativeInspect.inspect(_:)), keyEquivalent: "")
        inspect.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierInspectElement")
        inspect.target = native
        inspect.representedObject = "WebKit hit-test context"
        menu.addItem(inspect)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Extension action", action: nil, keyEquivalent: ""))
        return menu
    }

    private func event(_ web: PageView, at point: CGPoint) throws -> NSEvent {
        let zoom = web.pageZoom * web.magnification
        let local = CGPoint(x: point.x * zoom, y: web.isFlipped ? point.y * zoom : web.bounds.height - point.y * zoom)
        return try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: web.convert(local, to: nil), modifierFlags: [],
                                               timestamp: 0, windowNumber: web.window?.windowNumber ?? 0, context: nil,
                                               eventNumber: 0, clickCount: 1, pressure: 1))
    }

    @Test(arguments: [false, true])
    func inspectAlwaysForwardsTheOriginalItemAfterMakingRoom(measureAvailable: Bool) throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = PageView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        defer { web.stopLoading(); Tab.end(web) }
        let native = NativeInspect(), menu = menu(native)
        let original = menu.items[1]
        var calls: [String] = []
        web.onMeasure = {
            guard measureAvailable else { return nil }
            return { _ in calls.append("measure") }
        }
        web.onWebInspect = { inspect in calls.append("prepare"); inspect() }
        native.run = { calls.append("webkit") }
        try web.inspectHere(menu, event(web, at: CGPoint(x: 30, y: 40)))
        #expect(calls.isEmpty)
        menu.performActionForItem(at: 1)
        #expect(calls == ["prepare", "webkit"])
        #expect(native.received === original)
        #expect(original.representedObject as? String == "WebKit hit-test context")
        #expect(menu.items.map(\.title) == (measureAvailable
            ? ["Reload", "Inspect Element", "Measure", "", "Extension action"]
            : ["Reload", "Inspect Element", "", "Extension action"]))
    }

    @Test(arguments: [1.0, 2.0])
    func measureUsesTheClickedCSSPointWithoutOpeningTheInspector(zoom: Double) throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = PageView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        defer { web.stopLoading(); Tab.end(web) }
        web.pageZoom = zoom
        let native = NativeInspect(), menu = menu(native)
        var picked: CGPoint?
        var prepared = false
        web.onMeasure = { { point in picked = point } }
        web.onWebInspect = { inspect in prepared = true; inspect() }
        let point = CGPoint(x: 35, y: 45)
        try web.inspectHere(menu, event(web, at: point))
        PageView.dress(menu)
        let index = try #require(menu.items.firstIndex { $0.identifier?.rawValue == "YabMeasure" })
        #expect(index == 2)
        #expect(menu.items[index].title == "Measure")
        #expect(menu.items[index].image === MenuMark.image("yab.ruler"))
        #expect(Glyphs.art("yab.ruler") != nil)
        #expect(menu.items[1].image === MenuMark.image("yab.code"))
        #expect(picked == nil && !prepared && native.received == nil)
        menu.performActionForItem(at: index)
        #expect(picked == point)
        #expect(!prepared && native.received == nil)
        picked = nil
        web.onMeasure = { nil }
        menu.performActionForItem(at: index)
        #expect(picked == nil && !prepared && native.received == nil)
    }

    @Test func delayedInspectKeepsTheOriginalMenuTarget() throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = PageView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        defer { web.stopLoading(); Tab.end(web) }
        let first = NativeInspect(), second = NativeInspect()
        let original = menu(first), next = menu(second)
        var ready: (() -> Void)?
        web.onWebInspect = { ready = $0 }
        try web.inspectHere(original, event(web, at: CGPoint(x: 30, y: 40)))
        original.performActionForItem(at: 1)
        #expect(first.received == nil)
        try web.inspectHere(next, event(web, at: CGPoint(x: 50, y: 60)))
        let complete = try #require(ready)
        complete()
        #expect(first.received === original.items[1])
        #expect(second.received == nil)
    }

    @Test func noInspectAnchorAddsNothing() throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = PageView(frame: .zero, configuration: configuration)
        defer { web.stopLoading(); Tab.end(web) }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Copy", action: nil, keyEquivalent: ""))
        web.onMeasure = { { _ in Issue.record("Measure must not run while opening the menu") } }
        try web.inspectHere(menu, event(web, at: .zero))
        #expect(menu.items.map(\.title) == ["Copy"])
    }

    @Test(arguments: [false, true])
    func tabAvailabilityAndActionsKeepTheirExistingScope(local: Bool) throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let tab = Tab(shy: true, bench: true, configuration: configuration, factory: .webKitOnly)
        let host = "inspect-\(UUID().uuidString.lowercased())" + (local ? ".localhost" : ".example")
        let url = URL(string: "https://\(host)/")!
        let name = try #require(DevSites.name(url))
        defer { DevSites.forget(name); tab.close() }
        tab.restore(url: url, title: "Inspect menu fixture")
        let web = requireNativeWebKitFixture(tab, "PageInspectMenuTests")
        web.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        var opened = 0
        tab.onWebInspectElement = { _, inspect in opened += 1; inspect() }
        for enabled in [false, true] {
            DevSites.set(tab: tab.id, name: name, enabled)
            #expect(tab.isDev == enabled)
            for toolsOpen in [false, true] {
                tab.toolsOpen = { _ in toolsOpen }
                let native = NativeInspect(), menu = menu(native)
                try web.inspectHere(menu, event(web, at: CGPoint(x: 20, y: 30)))
                let measure = menu.items.firstIndex { $0.identifier?.rawValue == "YabMeasure" }
                #expect((measure != nil) == (enabled && !toolsOpen))
                if let measure {
                    menu.performActionForItem(at: measure)
                    #expect(tab.measuring)
                    #expect(native.received == nil)
                    // Choosing Measure again picks here instead of toggling off.
                    menu.performActionForItem(at: measure)
                    #expect(tab.measuring)
                }
                let before = opened
                native.run = { #expect(!tab.measuring && opened == before + 1) }
                menu.performActionForItem(at: 1)
                #expect(opened == before + 1 && native.received === menu.items[1])
                #expect(!tab.measuring)
            }
        }
    }
}
