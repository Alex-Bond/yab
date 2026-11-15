import AppKit
import Testing
@testable import Fast

@MainActor
struct ColumnGripScrollLifecycleTests {
    @Test func detachingOnlyCancelsAnActiveDrag() {
        _ = NSApplication.shared
        let grip = ColumnGrip()
        var cancellations = 0
        grip.changed = { if $0.state == .cancelled { cancellations += 1 } }
        grip.watch(true)
        grip.watch(false)
        #expect(cancellations == 0)
        grip.watch(true)
        grip.state = .changed
        grip.watch(false)
        #expect(cancellations == 1)
        #expect(grip.state == .idle)
    }
}

/// The real virtualized page and native local-event grip. No HID input,
/// foregrounding or on-screen window: scroll jumps cross the held row's
/// resting slot while its actual cell must stay with the same hand.
@MainActor
@Suite(.serialized)
struct ColumnDragScrollOwnershipTests {
    private final class EventSurface: NSView {
        override func mouseDown(with event: NSEvent) {}
        override func mouseDragged(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) {}
    }

    private func world(folder: Bool, _ check: (Browser, ColumnPage, NSWindow, String) throws -> Void) throws {
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        let prefs = browser.prefs
        let old = (prefs.sidebar, prefs.sideShut, prefs.sideWidth, prefs.usesSpaces)
        prefs.sidebar = true; prefs.sideShut = false; prefs.sideWidth = 240; prefs.usesSpaces = false
        let all = (0..<105).map { n in
            let tab = Tab()
            tab.restore(url: URL(string: "https://drag-scroll.invalid/\(n)")!, title: "Tab \(n)")
            tab.kept = true
            browser.prepare(tab)
            return tab
        }
        let nest = Nest(name: "Held folder", open: false)
        browser.lay(all)
        browser.activeID = all.first?.id
        browser.takeOwnFolders()
        _ = receipt("after-lay", folder: folder, browser: browser, tabs: all, nest: nest)
        if folder { for tab in all[43..<46] { tab.nest = nest } }
        browser.folderBook.refresh()
        let window = NSWindow(contentRect: CGRect(x: -30000, y: 0, width: 240, height: 650),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let page = ColumnPage(browser: browser, space: browser.spaceID)
        page.frame = CGRect(x: 0, y: 0, width: 240, height: 650)
        window.contentView = page
        defer {
            page.hand.grip.watch(false)
            window.close()
            browser.letGoArranging()
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            all.forEach { $0.close() }
            prefs.sidebar = old.0; prefs.sideShut = old.1; prefs.sideWidth = old.2; prefs.usesSpaces = old.3
            if let id = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
                Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
            }
        }
        sync(browser, page)
        try #require(receipt("before-drag", folder: folder, browser: browser, tabs: all, nest: nest, page: page),
                     "DRAG_SCROLL_FIXTURE_INVALID: ordinary sleeping kept tabs and a rendered folder are required")
        let surface = EventSurface(frame: page.bounds)
        page.addSubview(surface, positioned: .above, relativeTo: nil)
        try check(browser, page, window, folder ? nest.key : all[43].id.uuidString)
    }

    /// A failed construction is a harness failure, never a red bug proof.
    private func receipt(_ stage: String, folder: Bool, browser: Browser, tabs: [Tab], nest: Nest,
                         page: ColumnPage? = nil) -> Bool {
        let group = Array(tabs[43..<46])
        let found = browser.folderBook.folder(nest.key)
        let members = found?.members ?? []
        let ordinary = tabs.allSatisfy { !$0.bench && $0.kept && $0.built == nil }
        let membership = group.allSatisfy { $0.nest === nest } && Set(members) == Set(group.map(\.id))
        let rendered = page?.items.contains { $0.id == nest.key && $0.folderKey == nest.key } ?? false
        let valid = ordinary && (!folder || (membership && rendered))
        let record: [String: Any] = [
            "stage": stage, "folder": folder, "valid": valid, "tabs": tabs.count,
            "ordinary_kept_sleeping": ordinary, "nest_key": nest.key,
            "members": group.map { ["id": $0.id.uuidString, "bench": $0.bench, "kept": $0.kept,
                                    "nest": $0.nest?.key ?? ""] as [String: Any] },
            "folder_book_members": members.map(\.uuidString),
            "rendered_folder": rendered,
            "items": page?.items.map { ["id": $0.id, "kind": $0.folderKey != nil ? "folder" : $0.tab != nil ? "tab" : "other"] } ?? []
        ]
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
           let words = String(data: data, encoding: .utf8) { print("DRAG_SCROLL_FIXTURE " + words) }
        return valid
    }

    private func sync(_ browser: Browser, _ page: ColumnPage) {
        page.live(ColumnLayout.live(browser), head: ColumnLayout.head(browser),
                  frame: ColumnPages.Frame(lead: ColumnLayout.lead(browser, pins: browser.pinCellCount),
                                           footRoom: 0, top: 36, foot: false),
                  look: ColumnPages.Look(tone: nil, scheme: .light, titleSize: 13, grain: 0))
        page.layoutSubtreeIfNeeded()
    }

    private func send(_ type: NSEvent.EventType, _ point: CGPoint, page: ColumnPage, window: NSWindow) throws {
        NSApp.sendEvent(try #require(NSEvent.mouseEvent(with: type,
            location: page.convert(point, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)))
    }

    private func cell(_ id: String, in page: ColumnPage) -> ColumnCell? {
        page.scrollView.documentView?.subviews.compactMap { $0 as? ColumnCell }
            .first { $0.itemID == id && !$0.isHidden }
    }

    @Test(arguments: [false, true], [false, true])
    func heldCellSurvivesLargeScrollAndCleansUp(_ folder: Bool, _ cancelled: Bool) throws {
        try exerciseLargeScroll(folder: folder, cancelled: cancelled)
    }

    /// Shared test fixture calls real production objects on both source
    /// revisions. The baseline uses its existing scroll entry; candidate
    /// tests can pass the actual autoscroll entry without a model substitute.
    func exerciseLargeScroll(folder: Bool, cancelled: Bool,
                             advance: ((ColumnPage, CGFloat) -> Void)? = nil) throws {
        try world(folder: folder) { browser, page, window, id in
            let item = try #require(page.items.first { $0.id == id })
            // Put the resting source in sight near the bottom, then carry
            // it to the upper edge without crossing into the pins.
            let initialOffset = max(0, item.y - 400)
            page.scroll(to: initialOffset)
            sync(browser, page)
            let owner = try #require(cell(id, in: page))
            let start = CGPoint(x: 120, y: try #require(page.rowMiddle(id)))
            let end = CGPoint(x: start.x, y: page.rowsClip.minY + 28)
            try #require(start.y > end.y + 100 && start.y < page.rowsClip.maxY)
            try send(.leftMouseDown, start, page: page, window: window)
            try send(.leftMouseDragged, end, page: page, window: window)
            #expect(page.hand.grip.heard["began"] == 1)
            #expect(page.hand.drawn(item).front && page.hand.drawn(item).hold.lifted)
            #expect(cell(id, in: page) === owner)

            // A real bounds change runs ColumnPage.place before another
            // drag event. The source's resting slot is now far below sight.
            let offset = max(0, initialOffset - 900)
            if let advance { advance(page, offset) } else { page.scroll(to: offset) }
            sync(browser, page)
            #expect(item.y > page.scrollView.contentView.bounds.maxY + ColumnLayout.step)
            #expect(cell(id, in: page) === owner, "the held cell must not enter the reuse pool")
            #expect(owner.itemID == id && owner.current?.id == id)

            // Same hand position after the scroll, through the production
            // grip, not a copied travel/visibility model.
            try send(.leftMouseDragged, end, page: page, window: window)
            sync(browser, page)
            #expect(cell(id, in: page) === owner)
            #expect(!owner.isHidden && page.hand.drawn(item).front && page.hand.drawn(item).hold.lifted)
            let drawnMiddle = page.rowsTop + owner.frame.midY + owner.shift.height
            #expect(abs(drawnMiddle - end.y) < 1, "the retained owner stays under the hand")

            // Release or cancel through the real grip/hand paths. A later
            // scroll must recycle normally, with no retained hold.
            if cancelled {
                page.hand.grip.state = .cancelled
            } else {
                try send(.leftMouseUp, end, page: page, window: window)
            }
            sync(browser, page)
            #expect(page.hand.dragging == nil)
            #expect((page.hand.state["nest"] as? String) == "")
            #expect(browser.folderBook.carried == nil)
            page.scroll(to: 3000)
            sync(browser, page)
            #expect(cell(id, in: page) == nil)
            #expect(page.onScreen[id] == nil)
            #expect(allSleeping(browser), "the drag must not wake fixture pages")
        }
    }

    private func allSleeping(_ browser: Browser) -> Bool { browser.tabs.allSatisfy { $0.built == nil } }
}
