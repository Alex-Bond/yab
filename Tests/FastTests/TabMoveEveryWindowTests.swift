import AppKit
import Foundation
import Testing
@testable import Fast

/// Feedback #1808 (register 2327): with today's tabs in every window, a tab
/// moved to another space in one window moves in the other too: gone from
/// the space it left, there in the space it went to. Two registered
/// windows, the first one and another, so the move goes through the real
/// broadcast (KeptEverywhere.wrote), nothing followed by hand.
@MainActor @Suite(.serialized, .spacesListAlone)
struct TabMoveEveryWindowTests {

    /// Where the other window is when the tab moves.
    enum Other: String, CaseIterable {
        /// On the space the tab leaves, the other never opened there.
        case onSource
        /// On the space the tab leaves, the other gone to before.
        case visitedTarget
        /// On the space the tab goes to.
        case onTarget
    }

    @MainActor private final class World {
        let first = Space(id: Space.firstID, name: "Home", icon: "🏠", ownSignIns: false)
        // A space and a site of each case's own: rows written by a case
        // before, still on their way to the disk, are none of this one's.
        let work: Space
        let site = "move-\(UUID().uuidString.prefix(8).lowercased()).test"
        private let previousSharing: Set<UUID>
        private let previousToday: Bool
        /// The first window's row of the first space, which the first
        /// window here writes over: put back as it was.
        private let previousHome: Session.Shape
        private let saved: [String: Any]
        private var windows: [(Browser, NSWindow)] = []
        private static let keys: Set<String> = ["spaces", "space.current", SharedPins.key]

        /// `own`: the space the tab goes to has sign-ins of its own, as an
        /// Arc profile brought in makes it, and the tab is opened afresh there.
        init(own: Bool) throws {
            work = Space(id: UUID(), name: "Work", icon: "💼", ownSignIns: own)
            try #require(Store.testing && Store.unitTests)
            _ = NSApplication.shared
            previousSharing = Spaces.sharing
            previousToday = KeptEverywhere.today
            previousHome = Session.read(space: Space.firstID)
            saved = Store.settings.dictionaryRepresentation().filter { Self.keys.contains($0.key) }
            Store.settings.set(Space.firstID.uuidString, forKey: "space.current")
            if !own { Spaces.sharing.insert(work.id) }
            KeptEverywhere.today = true
            KeptEverywhere.known = [:]
        }

        func browser(first isFirst: Bool) -> Browser {
            let id: UUID? = isFirst ? nil : UUID()
            if let id { Store.settings.set(Space.firstID.uuidString, forKey: "window.\(id.uuidString).space") }
            // Spaces off while it comes up: a first window coming up with
            // them on keeps its look into the spaces' file, and every
            // window of the process, another suite's too, reads the list
            // there again (Spaces.changed). On once it is up.
            Store.settings.set(false, forKey: "spaces")
            // Pins in each space: shared ones are turned for every window
            // there is (SharedPins.turn), and kept in one file for all.
            Store.settings.set(false, forKey: SharedPins.key)
            let browser = Browser(windowID: id)
            // Work in each window's own list, never in the spaces' file:
            // written there, every window of the process, another suite's
            // too, would take the list as theirs (Spaces.changed). Every
            // space wears the look on now, so a switch writes no look.
            browser.prefs.usesSpaces = true
            if !browser.spaces.contains(where: { $0.id == work.id }) { browser.spaces.append(work) }
            let look = SpacePaint(browser.prefs)
            for at in browser.spaces.indices { browser.spaces[at].paint = look }
            let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 800, height: 600),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            BrowserWindows.shared.register(window, for: browser)
            windows.append((browser, window))
            return browser
        }

        func close() {
            for (browser, window) in windows {
                for tab in browser.tabs + browser.parkedTabs { tab.close() }
                window.close()
                // The first window outlives a close; gone here, or every
                // suite after would share rows with it.
                BrowserWindows.shared.forgetForTests(browser)
                browser.letGo()
                browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
                if let id = browser.windowID {
                    Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
                    for suffix in ["", "-" + work.id.uuidString] {
                        try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString)\(suffix).json"))
                    }
                }
            }
            windows = []
            try? FileManager.default.removeItem(at: Store.file("session-\(work.id.uuidString).json"))
            Session.write(now: true, space: Space.firstID, previousHome)
            KeptEverywhere.today = previousToday
            KeptEverywhere.known = [:]
            Spaces.sharing = previousSharing
            for key in Self.keys { Store.settings.set(saved[key], forKey: key) }
        }
    }

    private func page(_ name: String, on site: String, in browser: Browser) -> Tab {
        let tab = Tab()
        tab.restore(url: URL(string: "https://\(site)/\(name)")!, title: name)
        browser.prepare(tab)
        return tab
    }

    private func names(_ row: [Tab]?, on site: String) -> [String] {
        (row ?? []).compactMap { ($0.pending ?? $0.address)?.host == site ? ($0.pending ?? $0.address)?.lastPathComponent : nil }
    }

    /// A row as a failure says it: each page's name, id and key.
    private func said(_ row: [Tab]?) -> String {
        (row ?? []).map { "\(($0.pending ?? $0.address)?.lastPathComponent ?? "-") \($0.id.uuidString.prefix(8)) key \(KeptEverywhere.key($0).uuidString.prefix(8))\($0.asleep ? " asleep" : "")" }
            .joined(separator: ", ")
    }


    @Test(arguments: [true, false], Other.allCases)
    func aTabMovedInOneWindowMovesInTheOther(fromFirst: Bool, other where: Other) throws {
        try move(fromFirst: fromFirst, other: `where`, own: false)
    }

    @Test(arguments: [true, false], Other.allCases)
    func aTabMovedIntoASpaceOfItsOwnSignInsMovesInTheOther(fromFirst: Bool, other where: Other) throws {
        try move(fromFirst: fromFirst, other: `where`, own: true)
    }

    private func move(fromFirst: Bool, other where: Other, own: Bool) throws {
        // Nothing here writes the spaces' list: every window of the process,
        // another suite's too, would read it again.
        let writes = Count()
        let watch = NotificationCenter.default.addObserver(forName: Spaces.changed, object: nil, queue: nil) { _ in writes.n += 1 }
        defer {
            NotificationCenter.default.removeObserver(watch)
            #expect(writes.n == 0, "the spaces' list written \(writes.n) times (\(`where`), own \(own))")
        }
        let world = try World(own: own)
        defer { world.close() }
        let primary = world.browser(first: true)
        let second = world.browser(first: false)
        let (mover, other) = fromFirst ? (primary, second) : (second, primary)
        let home = world.first.id, work = world.work.id
        try #require(mover.spaceID == home && other.spaceID == home)
        try #require(mover.prefs.usesSpaces && mover.spaces.contains { $0.id == work })

        // Two of today's in the mover's window, followed in the other's.
        let site = world.site
        let x = page("x", on: site, in: mover), y = page("y", on: site, in: mover)
        mover.lay(mover.tabs + [x, y])
        mover.select(y)
        mover.writeRow(mover.tabs, active: mover.activeID, space: home, pairs: [], now: true)
        try #require(names(other.row(of: home), on: site).contains("x"), "the other window has x before the move")

        switch `where` {
        case .onSource: break
        case .visitedTarget:
            other.switchSpace(to: work)
            other.switchSpace(to: home)
        case .onTarget:
            other.switchSpace(to: work)
        }

        _ = try #require(mover.moveTabs([x], to: work, say: false))
        let early = said(other.row(of: work))
        // Both rows go out at once: not in the space it left meanwhile.
        #expect(!names(other.row(of: home), on: site).contains("x"), "x in Home in the other window right after the move (\(`where`))")

        #expect(!names(mover.row(of: home), on: site).contains("x"))
        #expect(names(mover.row(of: work), on: site) == ["x"], "the mover's Work: \(said(mover.row(of: work)))")
        // The other window: gone from the space it left...
        #expect(!names(other.row(of: home), on: site).contains("x"), "x still in Home in the other window (\(`where`))")
        #expect(names(other.row(of: home), on: site).contains("y"))
        // ...counted in the space it went to while that is not on screen...
        if other.spaceID != work {
            #expect(other.pageCount(in: work) == 1, "Work's count in the other window (\(`where`)): \(said(other.row(of: work)))")
        }
        // ...and there once that row is seen.
        if other.row(of: work) == nil { other.switchSpace(to: work) }
        #expect(names(other.row(of: work), on: site) == ["x"], "Work in the other window (\(`where`)): \(said(other.row(of: work))); mover's: \(said(mover.row(of: work))); right after the move: \(early)")
    }
}

private final class Count: @unchecked Sendable {
    var n = 0
}
