import AppKit
import Observation
import Testing
@testable import Fast

/// Pin drawing must not walk the entire tab row unless another pin is
/// actually moving it. This checks the real drawing and close routes,
/// without making a wall-clock performance claim.
@MainActor
@Suite(.serialized)
struct ColumnPinWorkTests {
    private final class Changed: @unchecked Sendable { var value = false }
    /// Let AppKit dispatch through the real local monitor without pressing
    /// a hosted pin button or starting its page. Hit testing still reaches
    /// a descendant of the real ColumnPage.
    private final class EventSurface: NSView {
        override func mouseDown(with event: NSEvent) {}
        override func mouseDragged(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) {}
    }

    private func world(count: Int, _ check: @MainActor (Browser, ColumnPage, NSWindow, [Tab], [Tab]) throws -> Void) throws {
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        let prefs = browser.prefs
        let old = (prefs.sidebar, prefs.sideShut, prefs.sideWidth)
        prefs.sidebar = true; prefs.sideShut = false; prefs.sideWidth = 240
        let tabs = (0..<count).map { n in
            let tab = Tab()
            tab.restore(url: URL(string: "https://pin-work.invalid/\(n)")!, title: "Tab \(n)")
            if n < 3 { tab.pin = String(n) }
            browser.prepare(tab)
            return tab
        }
        browser.lay(tabs)
        browser.activeID = tabs[0].id
        let window = NSWindow(contentRect: CGRect(x: -30000, y: 0, width: 240, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let page = ColumnPage(browser: browser, space: browser.spaceID)
        page.frame = CGRect(x: 0, y: 0, width: 240, height: 600)
        window.contentView = page
        page.live(ColumnLayout.live(browser), head: ColumnLayout.head(browser),
                  frame: ColumnPages.Frame(lead: ColumnLayout.lead(browser, pins: browser.pinCellCount), footRoom: 0, top: 36, foot: false),
                  look: ColumnPages.Look(tone: nil, scheme: .light, titleSize: 13, grain: 0))
        defer {
            page.hand.grip.watch(false)
            window.close()
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            tabs.forEach { $0.close() }
            prefs.sidebar = old.0; prefs.sideShut = old.1; prefs.sideWidth = old.2
            if let id = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
                Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
            }
        }
        try check(browser, page, window, Array(tabs.prefix(3)), Array(tabs.dropFirst(3)))
    }

    @Test(arguments: [12, 240])
    func idlePinDoesNotDependOnTheWholeTabRow(_ count: Int) throws {
        try world(count: count) { browser, page, _, pins, loose in
            let item = try #require(page.headItems.first { $0.tab === pins[0] })
            let victim = try #require(loose.last)
            #expect(victim.builtPage == nil)
            let changed = Changed()
            let before = withObservationTracking {
                page.hand.drawn(item)
            } onChange: { changed.value = true }
            browser.close(victim)
            #expect(!browser.tabs.contains { $0 === victim })
            #expect(browser.tabs.contains { $0 === pins[0] })
            let after = page.hand.drawn(item)
            #expect(before.shift == .zero && after.shift == .zero)
            #expect(before.hold == after.hold)
            #expect(before.lean == after.lean)
            #expect(before.opacity == after.opacity && before.front == after.front)
            print("PIN_WORK count=\(count) idleWholeRowDependency=\(changed.value) closed=true")
            #expect(!changed.value, "idle pin drawing must not read the entire tab row")
        }
    }

    @Test func genuinePinDragPreservesHeldAndNeighborGeometry() throws {
        try world(count: 12) { browser, page, window, pins, _ in
            let surface = EventSurface(frame: page.bounds)
            page.addSubview(surface, positioned: .above, relativeTo: nil)
            let first = try #require(page.headItems.first { $0.tab === pins[0] })
            let second = try #require(page.headItems.first { $0.tab === pins[1] })
            @MainActor func center(_ item: ColumnItem) -> CGPoint {
                CGPoint(x: SideBar.margin + (item.x ?? 0) + (item.width ?? 0) / 2,
                        y: item.y + item.height / 2)
            }
            @MainActor func send(_ type: NSEvent.EventType, _ point: CGPoint) throws {
                NSApp.sendEvent(try #require(NSEvent.mouseEvent(with: type,
                    location: page.convert(point, to: nil), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
            }
            let start = center(first), end = center(second)
            try send(.leftMouseDown, start)
            try send(.leftMouseDragged, end)
            #expect(page.hand.grip.heard["began"] == 1)
            #expect(page.hand.pinDragging == pins[0].id)
            let held = page.hand.drawn(first), neighbor = page.hand.drawn(second)
            #expect(held.shift == CGSize(width: end.x - start.x, height: end.y - start.y))
            #expect(neighbor.shift == CGSize(width: start.x - end.x, height: start.y - end.y))
            #expect(held.hold.lifted && held.front)
            #expect(!neighbor.hold.lifted && !neighbor.front)
            // Bringing the pin below its grid carries it over the rows;
            // its former neighbors no longer need a grid index or shift.
            try send(.leftMouseDragged, CGPoint(x: start.x, y: ColumnLayout.lead(browser, pins: browser.pinCellCount) + 80))
            #expect(page.hand.pinDragging == pins[0].id)
            #expect(page.hand.shape.gap != nil)
            #expect(page.hand.drawn(second).shift == .zero)
            page.hand.grip.state = .cancelled
            #expect(page.hand.pinDragging == nil)
            #expect(page.hand.drawn(first).shift == .zero)
            print("PIN_DRAG began=1 held=travel neighbor=previous-cell carry=zero cancelled=true")
        }
    }

    @Test(arguments: [false, true])
    func heldTabPaintsAboveSpaceName(_ pin: Bool) throws {
        try world(count: 12) { browser, page, window, pins, loose in
            let usesSpaces = browser.prefs.usesSpaces
            browser.prefs.usesSpaces = true
            defer { browser.prefs.usesSpaces = usesSpaces }
            page.live(ColumnLayout.live(browser), head: ColumnLayout.head(browser),
                      frame: .init(lead: ColumnLayout.lead(browser, pins: browser.pinCellCount), footRoom: 0, top: 36, foot: false),
                      look: .init(tone: nil, scheme: .light, titleSize: 13, grain: 0))
            page.layoutSubtreeIfNeeded()
            let nameItem = try #require(page.headItems.first { if case .name = $0.kind { true } else { false } })
            let tab = pin ? pins[0] : loose[0]
            let item = try #require((pin ? page.headItems : page.items).first { $0.tab === tab })
            let name = try #require(findCell(nameItem.id, in: page))
            let owner = try #require(findCell(item.id, in: page))
            let nameFrame = name.convert(name.bounds, to: page)
            let startFrame = owner.convert(owner.bounds, to: page)
            let start = CGPoint(x: startFrame.midX, y: startFrame.midY)
            // The lower half keeps a row in row form. A pin just entering
            // the name stays a pin, before it changes into a carried row.
            let end = CGPoint(x: start.x, y: nameFrame.minY + (pin ? 2 : nameFrame.height * 0.8))
            let surface = EventSurface(frame: page.bounds)
            page.addSubview(surface, positioned: .above, relativeTo: nil)
            @MainActor func send(_ type: NSEvent.EventType, _ point: CGPoint) throws {
                NSApp.sendEvent(try #require(NSEvent.mouseEvent(with: type,
                    location: page.convert(point, to: nil), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
            }
            if !pin { #expect(paintsAbove(name, owner), "at rest the name stays over scrolling rows") }
            try send(.leftMouseDown, start)
            try send(.leftMouseDragged, end)
            let drawn = page.hand.drawn(item)
            try #require(drawn.front && drawn.hold.lifted && drawn.opacity > 0)
            let parent = try #require(owner.superview)
            let heldFrame = parent.convert(owner.frame.offsetBy(dx: drawn.shift.width, dy: drawn.shift.height), to: page)
            #expect(heldFrame.intersects(nameFrame), "exercise an actual overlap with the space name")
            #expect(paintsAbove(owner, name), "a lifted tab must paint over the name across container boundaries")
            #expect(name.convert(name.bounds, to: page) == nameFrame, "the name's layout and drop target do not move")
            page.hand.grip.state = .cancelled
            #expect(page.hand.dragging == nil && page.hand.pinDragging == nil)
            // The cancel's refresh is ColumnPages.sync, which lays the page
            // again; this page has no ColumnPages, so lay it as sync does.
            page.live(ColumnLayout.live(browser, shape: page.hand.shape), head: ColumnLayout.head(browser, gaps: page.hand.pinGaps),
                      frame: .init(lead: ColumnLayout.lead(browser, pins: browser.pinCellCount), footRoom: 0, top: 36, foot: false),
                      look: .init(tone: nil, scheme: .light, titleSize: 13, grain: 0))
            if !pin { #expect(paintsAbove(name, owner), "cancelling restores the normal scroll layering") }
            #expect(browser.tabs.allSatisfy { $0.built == nil })
        }
    }

    private func findCell(_ id: String, in view: NSView) -> ColumnCell? {
        if let cell = view as? ColumnCell, cell.itemID == id, !cell.isHidden { return cell }
        return view.subviews.lazy.compactMap { findCell(id, in: $0) }.first
    }

    /// Compare the branches at their common ancestor, rather than just
    /// siblings inside the pin grid or scroll document.
    private func paintsAbove(_ front: NSView, _ back: NSView) -> Bool {
        var branch = front
        while let parent = branch.superview {
            var other = back
            while let above = other.superview, above !== parent { other = above }
            if other.superview === parent, other !== branch,
               let a = parent.subviews.firstIndex(where: { $0 === branch }),
               let b = parent.subviews.firstIndex(where: { $0 === other }) { return a > b }
            branch = parent
        }
        return false
    }
}
