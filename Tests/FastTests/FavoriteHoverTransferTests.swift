import AppKit
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct FavoriteHoverTransferTests {
    private typealias Reply = @MainActor ([PinItem]) -> Void

    private final class Pointer {
        var spot = CGPoint(x: 35, y: 37)
    }

    private func world(_ body: (Browser, TabGlance, [Tab], Pointer) async throws -> Void) async rethrows {
        _ = NSApplication.shared
        let id = UUID(), browser = Browser(windowID: id)
        let prefs = browser.prefs
        let old = (prefs.sidebar, prefs.sideShut)
        prefs.sidebar = true
        prefs.sideShut = false
        let tabs = (0..<3).map { index in
            let tab = Tab(bench: true)
            tab.restore(url: URL(string: "https://favorite-\(index).test/")!, title: "Favorite \(index)")
            if index < 2 { tab.pin = "\(index)" }
            browser.prepare(tab)
            return tab
        }
        browser.lay(tabs)
        browser.activeID = nil
        let glance = browser.glance, pointer = Pointer()
        glance.pointerLocation = { pointer.spot }
        glance.pinLoader = { tab, _, _, done in done(Self.rows(tab)) }
        browser.keySky.lay(tabs[0].id, CGRect(x: 10, y: 20, width: 50, height: 34))
        browser.keySky.lay(tabs[1].id, CGRect(x: 66, y: 20, width: 50, height: 34))
        browser.keySky.lay(tabs[2].id, CGRect(x: 10, y: 100, width: 200, height: 34))
        glance.folderFrames[TabGlance.pinKey(tabs[0].id)] = browser.keySky.place(tabs[0].id)
        glance.pretendFolder(TabGlance.pinKey(tabs[0].id), true)
        glance.previewFrame = CGRect(x: 64, y: 10, width: 264, height: 200)
        defer {
            glance.drop()
            glance.pointerLocation = nil
            glance.pinLoader = PinList.items
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            tabs.forEach { $0.close() }
            prefs.sidebar = old.0
            prefs.sideShut = old.1
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
        }
        try await body(browser, glance, tabs, pointer)
    }

    private static func rows(_ tab: Tab) -> [PinItem] {
        [PinItem(id: tab.id.uuidString, title: tab.title, detail: "", open: {})]
    }

    @Test(arguments: [false, true])
    func anotherFavoriteWinsEvenWithoutAnEntryEvent(nextRow: Bool) async throws {
        try await world { browser, glance, tabs, pointer in
            let target = nextRow ? CGRect(x: 66, y: 60, width: 50, height: 34)
                                 : CGRect(x: 66, y: 20, width: 50, height: 34)
            browser.keySky.lay(tabs[1].id, target)
            pointer.spot = CGPoint(x: target.midX, y: target.midY)
            #expect(glance.previewFrame?.contains(pointer.spot) == true)
            #expect(!glance.covers(pointer.spot))
            glance.moved(to: pointer.spot)
            #expect(glance.shownFolder == TabGlance.pinKey(tabs[1].id))
            #expect(glance.pinItems.first?.id == tabs[1].id.uuidString)
            // The old square's exit may arrive after the new one's entry.
            glance.hover(tabs[0].id, false)
            try await Task.sleep(for: .milliseconds(400))
            #expect(glance.shownFolder == TabGlance.pinKey(tabs[1].id))
        }
    }

    @Test func nativeHoverCanTransferAcrossAnOverlappingPreview() async {
        await world { _, glance, tabs, pointer in
            pointer.spot = CGPoint(x: 91, y: 37)
            glance.hover(tabs[1].id, true)
            #expect(glance.shownFolder == TabGlance.pinKey(tabs[1].id))
            #expect(glance.pinItems == Self.rows(tabs[1]))
        }
    }

    @Test func traversalCanReturnToTheFirstFavorite() async throws {
        try await world { _, glance, tabs, pointer in
            pointer.spot = CGPoint(x: 91, y: 37)
            glance.moved(to: pointer.spot)
            #expect(glance.shownFolder == TabGlance.pinKey(tabs[1].id))
            glance.previewFrame = CGRect(x: 8, y: 10, width: 264, height: 200)
            pointer.spot = CGPoint(x: 35, y: 37)
            glance.moved(to: pointer.spot)
            try await Task.sleep(for: .milliseconds(150))
            #expect(glance.shownFolder == TabGlance.pinKey(tabs[0].id))
            #expect(glance.pinItems == Self.rows(tabs[0]))
        }
    }

    @Test func itsOwnPreviewHoldsAcrossTheCorridorThenLeaves() async throws {
        try await world { _, glance, tabs, pointer in
            let key = TabGlance.pinKey(tabs[0].id)
            pointer.spot = CGPoint(x: 62, y: 37)
            glance.moved(to: pointer.spot)
            #expect(glance.shownFolder == key)
            pointer.spot = CGPoint(x: 160, y: 80)
            #expect(glance.covers(pointer.spot))
            glance.moved(to: pointer.spot)
            try await Task.sleep(for: .milliseconds(400))
            #expect(glance.shownFolder == key && glance.taking)
            pointer.spot = CGPoint(x: 400, y: 250)
            glance.moved(to: pointer.spot)
            try await Task.sleep(for: .milliseconds(400))
            #expect(glance.shownFolder == nil && !glance.taking)
        }
    }

    @Test func pendingTransferRejectsThePreviousPinsReply() async {
        await world { _, glance, tabs, pointer in
            var replies: [Reply] = []
            glance.pinLoader = { _, _, _, done in replies.append(done) }
            glance.search("recent")
            pointer.spot = CGPoint(x: 91, y: 37)
            glance.moved(to: pointer.spot)
            #expect(replies.count == 2)
            guard replies.count == 2 else { return }
            replies[0](Self.rows(tabs[0]))
            #expect(glance.shownFolder == nil)
            replies[1](Self.rows(tabs[1]))
            #expect(glance.shownFolder == TabGlance.pinKey(tabs[1].id))
            #expect(glance.pinItems == Self.rows(tabs[1]))
        }
    }

    @Test func ordinaryRowsUnderThePinPreviewStayCovered() async {
        await world { _, glance, tabs, pointer in
            pointer.spot = CGPoint(x: 100, y: 117)
            #expect(glance.covers(pointer.spot))
            glance.hover(tabs[2].id, true)
            glance.moved(to: pointer.spot)
            #expect(glance.shownFolder == TabGlance.pinKey(tabs[0].id))
            #expect(glance.shown == nil)
        }
    }

    @Test func aTabsActionCardStillCoversFavoritesUnderIt() async {
        await world { _, glance, tabs, pointer in
            glance.drop()
            glance.pretend(tabs[2].id, true)
            glance.hold(true)
            glance.previewFrame = CGRect(x: 64, y: 10, width: 264, height: 200)
            pointer.spot = CGPoint(x: 91, y: 37)
            #expect(glance.covers(pointer.spot))
            glance.hover(tabs[1].id, true)
            #expect(glance.shown == tabs[2].id)
            #expect(glance.shownFolder == nil)
        }
    }

    @Test func hiddenFavoritesCannotTakeThePreviewsPointer() async {
        await world { browser, glance, tabs, pointer in
            browser.prefs.sideShut = true
            #expect(!browser.peek.out)
            pointer.spot = CGPoint(x: 91, y: 37)
            #expect(glance.covers(pointer.spot))
            glance.moved(to: pointer.spot)
            #expect(glance.shownFolder == TabGlance.pinKey(tabs[0].id))
        }
    }
}
