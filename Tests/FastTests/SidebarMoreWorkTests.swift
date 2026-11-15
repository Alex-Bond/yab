import AppKit
import Observation
import Testing
@testable import Fast

/// N-more drawing must not walk sleeping tabs while the rows are idle.
/// The native drag control checks that the same row still moves with its
/// folder's tabs. This makes no wall-clock or reporter-profile claim.
@MainActor
@Suite(.serialized)
struct SidebarMoreWorkTests {
    private final class Changed: @unchecked Sendable { var value = false }
    private final class EventSurface: NSView {
        override func mouseDown(with event: NSEvent) {}
        override func mouseDragged(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) {}
    }

    private func world(count: Int, _ check: @MainActor (Browser, ColumnPage, NSWindow, ColumnItem, [Tab], [Tab]) throws -> Void) async throws {
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        let prefs = browser.prefs
        let old = (prefs.sidebar, prefs.sideShut, prefs.sideWidth, prefs.usesSpaces)
        prefs.sidebar = true; prefs.sideShut = false; prefs.sideWidth = 240; prefs.usesSpaces = false
        // An unregistered agent id forms the ordinary task folder without
        // starting a worker or changing any existing agent session.
        let task = "column-more-" + UUID().uuidString
        let members = (0..<7).map { n in
            let tab = Tab(bench: true)
            tab.agent = task
            tab.restore(url: URL(string: "https://more-work.invalid/task/\(n)")!, title: "Result \(n)")
            browser.prepare(tab)
            return tab
        }
        let loose = (0..<(count - members.count)).map { n in
            let tab = Tab()
            tab.restore(url: URL(string: "https://more-work.invalid/loose/\(n)")!, title: "Tab \(n)")
            browser.prepare(tab)
            return tab
        }
        let all = loose + members
        browser.lay(all)
        browser.activeID = loose.first?.id
        browser.takeOwnFolders()
        let folders = browser.folderBook
        folders.refresh()
        let window = NSWindow(contentRect: CGRect(x: -30000, y: 0, width: 240, height: 650),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let page = ColumnPage(browser: browser, space: browser.spaceID)
        page.frame = CGRect(x: 0, y: 0, width: 240, height: 650)
        window.contentView = page
        defer {
            page.hand.grip.watch(false)
            window.close()
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            all.forEach { $0.close() }
            prefs.sidebar = old.0; prefs.sideShut = old.1; prefs.sideWidth = old.2; prefs.usesSpaces = old.3
            if let id = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
                Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
            }
        }
        let folder = try #require(folders.folder(task))
        #expect(folder.members == members.map(\.id))
        #expect(all.allSatisfy { $0.builtPage == nil })
        folders.toggle(task)
        for _ in 0..<100 where !folders.isOpen(task) { try await Task.sleep(for: .milliseconds(5)) }
        try #require(folders.isOpen(task))
        folders.refresh()
        page.live(ColumnLayout.live(browser), head: ColumnLayout.head(browser),
                  frame: ColumnPages.Frame(lead: ColumnLayout.lead(browser, pins: browser.pinCellCount), footRoom: 0, top: 36, foot: false),
                  look: ColumnPages.Look(tone: nil, scheme: .light, titleSize: 13, grain: 0))
        page.layoutSubtreeIfNeeded()
        let more = try #require(page.items.first { if case .more(let key, let n) = $0.kind { key == task && n == 3 } else { false } })
        #expect(more.height > 0)
        try check(browser, page, window, more, members, loose)
    }

    @Test(arguments: [12, 240])
    func idleMoreDoesNotDependOnTheWholeTabRow(_ count: Int) async throws {
        try await world(count: count) { browser, page, _, more, members, loose in
            page.scroll(to: max(0, more.y - 100))
            let middle = try #require(page.rowMiddle(more.id))
            #expect(middle > page.rowsClip.minY && middle < page.rowsClip.maxY)
            let victim = try #require(loose.last)
            #expect(victim.builtPage == nil)
            let changed = Changed()
            let before = withObservationTracking {
                page.hand.drawn(more)
            } onChange: { changed.value = true }
            browser.close(victim)
            #expect(!browser.tabs.contains { $0 === victim })
            #expect(members.allSatisfy { member in browser.tabs.contains { $0 === member } && member.builtPage == nil })
            let after = page.hand.drawn(more)
            #expect(before.shift == .zero && after.shift == .zero)
            #expect(before.hold == after.hold && before.lean == after.lean)
            #expect(before.opacity == after.opacity && before.front == after.front)
            print("MORE_WORK count=\(count) idleWholeRowDependency=\(changed.value) closed=true")
            #expect(!changed.value, "idle N-more drawing must not read the entire tab row")
            // The lookup guard must not bypass Clear's existing opacity.
            if case .more(let key, _) = more.kind {
                browser.dustingRows.insert(DrawnRows.more(key))
                #expect(page.hand.drawn(more).opacity == 0)
                browser.dustingRows.remove(DrawnRows.more(key))
            }
        }
    }

    @Test func genuineRowDragPreservesMoreGeometry() async throws {
        try await world(count: 12) { browser, page, window, more, members, _ in
            let surface = EventSurface(frame: page.bounds)
            page.addSubview(surface, positioned: .above, relativeTo: nil)
            let held = try #require(members.first { (browser.folderBook.place(of: $0)?.more ?? 0) > 0 })
            let first = try #require(page.items.first { $0.tab === held })
            @MainActor func send(_ type: NSEvent.EventType, _ point: CGPoint) throws {
                NSApp.sendEvent(try #require(NSEvent.mouseEvent(with: type,
                    location: page.convert(point, to: nil), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
            }
            let x = page.bounds.midX
            let start = CGPoint(x: x, y: try #require(page.rowMiddle(first.id)))
            let end = CGPoint(x: x, y: start.y - ColumnLayout.step)
            try #require(end.y < page.bounds.height)
            try send(.leftMouseDown, start)
            try send(.leftMouseDragged, end)
            #expect(page.hand.grip.heard["began"] == 1)
            #expect(page.hand.dragging == held.id)
            let shifted = page.hand.drawn(more).shift
            #expect(shifted.height == -ColumnLayout.step)
            #expect(shifted == page.hand.drawn(first).shift)
            #expect(page.hand.drawn(first).hold.lifted && page.hand.drawn(first).front)
            page.hand.grip.state = .cancelled
            #expect(page.hand.dragging == nil)
            #expect(page.hand.drawn(more).shift == .zero)
            #expect(members.allSatisfy { $0.builtPage == nil })
            print("MORE_DRAG began=1 more=previous-row associated=equal cancelled=true")
        }
    }

    @Test func genuineFolderCarryPreservesMoreGeometry() async throws {
        try await world(count: 12) { browser, page, window, _, members, loose in
            let nest = Nest(name: "Search results", open: true, search: "more work")
            for tab in loose.prefix(2) { tab.nest = nest }
            let folders = browser.folderBook
            folders.refresh()
            page.live(ColumnLayout.live(browser), head: ColumnLayout.head(browser),
                      frame: ColumnPages.Frame(lead: ColumnLayout.lead(browser, pins: browser.pinCellCount), footRoom: 0, top: 36, foot: false),
                      look: ColumnPages.Look(tone: nil, scheme: .light, titleSize: 13, grain: 0))
            page.layoutSubtreeIfNeeded()
            let folder = try #require(page.items.first { $0.folderKey == nest.key })
            let more = try #require(page.items.first { if case .more = $0.kind { true } else { false } })
            let associated = try #require(members.first { (folders.place(of: $0)?.more ?? 0) > 0 })
            let associatedItem = try #require(page.items.first { $0.tab === associated })
            let surface = EventSurface(frame: page.bounds)
            page.addSubview(surface, positioned: .above, relativeTo: nil)
            @MainActor func send(_ type: NSEvent.EventType, _ point: CGPoint) throws {
                NSApp.sendEvent(try #require(NSEvent.mouseEvent(with: type,
                    location: page.convert(point, to: nil), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
            }
            let start = CGPoint(x: page.bounds.midX, y: try #require(page.rowMiddle(folder.id)))
            let end = CGPoint(x: start.x, y: max(5, page.rowsTop - ColumnLayout.step / 2))
            try send(.leftMouseDown, start)
            try send(.leftMouseDragged, end)
            #expect(page.hand.grip.heard["began"] == 1)
            #expect(page.hand.dragging == nil)
            #expect(!(page.hand.state["nest"] as? String ?? "").isEmpty)
            #expect(folders.carried == nest.key)
            let lifted = page.hand.drawn(folder)
            #expect(lifted.hold.lifted && lifted.front)
            #expect(lifted.shift.height == end.y - start.y && lifted.shift.height != 0)
            // Stable task folders follow all of today's folders. Moving a
            // whole folder above the line leaves that task prefix intact,
            // so this control deliberately expects zero, not a fabricated
            // nonzero task shift. The held row control checks nonzero work.
            #expect(page.hand.drawn(more).shift == .zero)
            #expect(page.hand.drawn(more).shift == page.hand.drawn(associatedItem).shift)
            page.hand.grip.state = .cancelled
            #expect((page.hand.state["nest"] as? String) == "")
            #expect(folders.carried == nil)
            #expect(page.hand.drawn(folder).shift == .zero)
            #expect(page.hand.drawn(more).shift == .zero)
            print("MORE_CARRY began=1 dragging=nil lifted=true more=associated-zero cancelled=true")
        }
    }
}
