import Foundation
import Testing
@testable import Fast

/// Today's tabs in every window of their space, as in Arc (feedback #340,
/// KeptEverywhere.swift): turned on, every window's today's are one list;
/// a tab opened, closed, moved or put in a folder in one window is so in
/// the other, each window with its own tab in front; turned off, each
/// window keeps what it has open.
@Suite(.serialized)
@MainActor
struct TodayEveryWindowTests {
    private func page(_ name: String, in browser: Browser) -> Tab {
        let tab = Tab()
        tab.restore(url: URL(string: "https://today.test/\(name)")!, title: name)
        browser.prepare(tab)
        return tab
    }

    private func names(_ row: [Tab]) -> [String?] { row.map { $0.address?.lastPathComponent } }

    /// Two windows on one space, a's today's x and y, b's own z, and the
    /// setting turned on between them.
    private func two(_ body: (Browser, Browser, [Tab]) throws -> Void) rethrows {
        let one = UUID(), two = UUID()
        let was = KeptEverywhere.today
        KeptEverywhere.today = false
        defer {
            KeptEverywhere.today = was
            KeptEverywhere.known = [:]
            for id in [one, two] { try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json")) }
        }
        let a = Browser(windowID: one), b = Browser(windowID: two)
        defer { a.letGo(); b.letGo() }
        let x = page("x", in: a), y = page("y", in: a), z = page("z", in: b)
        a.lay([x, y])
        a.select(y)
        b.lay([z])
        b.select(z)
        KeptEverywhere.turnToday(true, first: a, others: [b])
        try body(a, b, [x, y, z])
    }

    @Test func turningItOnJoinsEveryWindowsToday() {
        two { a, b, made in
            let (x, y, z) = (made[0], made[1], made[2])
            #expect(names(a.tabs) == ["x", "y", "z"])
            #expect(names(b.tabs) == ["x", "y", "z"])
            // Each window's own tabs stay its own; the other's come asleep,
            // under the key every window knows the tab by.
            #expect(a.tabs[0] === x && a.tabs[1] === y && b.tabs[2] === z)
            #expect(b.tabs[0].asleep && b.tabs[1].asleep && a.tabs[2].asleep)
            #expect(KeptEverywhere.key(b.tabs[0]) == x.id && KeptEverywhere.key(a.tabs[2]) == KeptEverywhere.key(z))
            // Each window keeps its own tab in front.
            #expect(a.activeID == y.id && b.activeID == z.id)
        }
    }

    @Test func aTabOpenedInOneWindowIsInTheOther() {
        two { a, b, _ in
            let w = page("w", in: a)
            a.lay(a.tabs + [w])
            b.followKept(a.keptList(a.tabs), in: b.spaceID)
            #expect(names(b.tabs) == ["x", "y", "z", "w"])
            #expect(b.tabs[3].asleep && b.tabs[3] !== w)
            // And the other way.
            let v = page("v", in: b)
            b.lay(b.tabs + [v])
            a.followKept(b.keptList(b.tabs), in: a.spaceID)
            #expect(names(a.tabs) == ["x", "y", "z", "w", "v"])
            #expect(a.tabs.contains { $0 === w })
        }
    }

    @Test func aTabClosedInOneWindowClosesInTheOtherEvenInFront() {
        two { a, b, made in
            let x = made[0]
            // b on its own tab for x, awake: a closes x.
            let copy = b.tabs[0]
            b.select(copy)
            #expect(b.activeID == copy.id)
            a.close(x)
            #expect(!a.tabs.contains { $0 === x })
            b.followKept(a.keptList(a.tabs), in: b.spaceID)
            #expect(names(b.tabs) == ["y", "z"])
            #expect(!b.tabs.contains { $0 === copy })
            // b lands on another of today's, never none or the one gone.
            #expect(b.activeID != nil && b.activeID != copy.id)
            // Closed in b: gone from a too, asleep or not.
            let z = made[2]
            b.close(z)
            a.followKept(b.keptList(b.tabs), in: a.spaceID)
            #expect(names(a.tabs) == ["y"])
            // The same list again changes nothing.
            let before = a.tabs
            a.followKept(b.keptList(b.tabs), in: a.spaceID)
            #expect(a.tabs.elementsEqual(before, by: ===))
        }
    }

    @Test func aTabMovedToAnotherSpaceLeavesBothWindows() throws {
        try two { a, b, made in
            let (x, y) = (made[0], made[1])
            a.prefs.usesSpaces = true
            let saved = Store.settings.object(forKey: "spaces")
            let work = Space(id: UUID(), name: "Work", icon: "💼", ownSignIns: false)
            a.spaces.append(work)
            Spaces.sharing.insert(work.id)
            Browser.pretendHand = true
            defer {
                Browser.pretendHand = false
                Spaces.sharing.remove(work.id)
                Spaces.pageCounts[work.id] = nil
                Store.settings.set(saved, forKey: "spaces")
                for window in [a, b] {
                    guard let id = window.windowID else { continue }
                    try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString)-\(work.id.uuidString).json"))
                    Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
                }
            }
            let copyOfX = b.tabs[0]
            _ = try #require(a.moveTabs([x], to: work.id, say: false))
            #expect(names(a.tabs) == ["y", "z"])
            #expect(a.parked[work.id]?.tabs.contains { $0 === x } == true)
            b.followKept(a.keptList(a.tabs), in: b.spaceID)
            // Gone from b's row here too, the tab in front of each kept.
            #expect(names(b.tabs) == ["y", "z"])
            #expect(!b.tabs.contains { $0 === copyOfX })
            #expect(a.activeID == y.id && b.activeID == made[2].id)
        }
    }

    @Test func aNewOrderInOneWindowIsTheOthers() {
        two { a, b, made in
            let (x, y, z) = (made[0], made[1], made[2])
            let theirZ = a.tabs[2]
            a.lay([theirZ, x, y])
            b.followKept(a.keptList(a.tabs), in: b.spaceID)
            #expect(names(b.tabs) == ["z", "x", "y"])
            #expect(b.tabs[0] === z)
            // The tab in front stays where it is in each window.
            #expect(a.activeID == y.id && b.activeID == z.id)
        }
    }

    @Test func aFolderOfTodaysIsInBothWindows() {
        two { a, b, made in
            let (x, y) = (made[0], made[1])
            a.newFolder(with: [x, y], today: true)
            x.nest?.name = "Trip"
            b.followKept(a.keptList(a.tabs), in: b.spaceID)
            let mine = b.tabs.filter { $0.nest != nil }
            #expect(names(mine) == ["x", "y"])
            #expect(mine.allSatisfy { $0.nest?.name == "Trip" && $0.nest?.id == x.nest?.id && $0.nest !== x.nest && $0.nest?.fleeting == true })
            #expect(mine.allSatisfy { !$0.kept })
        }
    }

    @Test func keptAndLetGoStaysOneTabInBoth() {
        two { a, b, made in
            let x = made[0]
            a.keepTabs([x])
            b.followKept(a.keptList(a.tabs), in: b.spaceID)
            #expect(b.tabs.first.map { $0.kept && KeptEverywhere.key($0) == x.id } == true)
            #expect(b.tabs.count == 3)
            a.releaseTabs([x])
            b.followKept(a.keptList(a.tabs), in: b.spaceID)
            // Let go, it is one of today's in both, never closed or twice.
            #expect(b.tabs.count == 3 && b.tabs.filter { KeptEverywhere.key($0) == x.id }.count == 1)
            #expect(b.tabs.allSatisfy { !$0.kept })
        }
    }

    @Test func turningItOffKeepsWhatAWindowHasOpen() {
        two { a, b, made in
            let z = made[2]
            let copyOfX = b.tabs[0], copyOfY = b.tabs[1]
            b.select(copyOfX)
            KeptEverywhere.turnToday(false, first: a, others: [b])
            #expect(!KeptEverywhere.today)
            // b keeps x, in front, and its own z; y asleep goes, still in a.
            #expect(b.tabs.contains { $0 === copyOfX } && b.tabs.contains { $0 === z })
            #expect(!b.tabs.contains { $0 === copyOfY })
            #expect(b.tabs.allSatisfy { $0.keptKey == nil })
            #expect(names(a.tabs) == ["x", "y", "z"])
            // Each window's own again: a tab closed in a stays in b.
            let before = b.tabs
            a.close(made[0])
            b.followKept(a.keptList(a.tabs), in: b.spaceID)
            #expect(b.tabs.elementsEqual(before, by: ===))
        }
    }

    // MARK: the file

    @Test func aWindowsOwnTodaysJoinTheListAtTheSameAddressToo() {
        func entry(_ url: String, id: String = UUID().uuidString, shared: Bool? = nil) -> Session.Entry {
            var entry = Session.Entry(url: url, title: url, pin: nil, name: nil, seen: nil, id: id)
            entry.shared = shared
            return entry
        }
        let x = entry("https://today.test/x")
        let own = Session.Shape(tabs: [
            entry("https://today.test/x", id: x.id!, shared: true),
            entry("https://today.test/gone", shared: true),
            entry("https://today.test/x"),
            entry("https://today.test/mine"),
        ], active: 3)
        let joined = KeptEverywhere.joined(own, list: [x], today: true)
        #expect(joined.shape.tabs.map(\.url) == ["https://today.test/x", "https://today.test/x", "https://today.test/mine"])
        #expect(joined.keyed == 3 && joined.strays == 2)
        #expect(joined.shape.active == 2)
        // Off, as before: today's are the window's own, after the list.
        let off = KeptEverywhere.joined(own, list: [x], today: false)
        #expect(off.keyed == 1 && off.strays == 0)
    }
}
