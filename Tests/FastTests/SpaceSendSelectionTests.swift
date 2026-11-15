import AppKit
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct SpaceSendSelectionTests {
    @Test(arguments: [false, true])
    func moveMenuFollowsTheTransferredSelection(ownSignIns: Bool) async throws {
        _ = NSApplication.shared
        let saved = Store.settings.object(forKey: "spaces")
        let savedSpaces = Spaces.read()
        let folders = Folders.shared.browser
        let hand = Browser.pretendHand
        let sharing = Spaces.sharing
        let current = Spaces.current
        let browser = Browser(windowID: UUID())
        browser.prefs.usesSpaces = true
        Folders.shared.browser = browser
        // A window can inherit an isolated home from the test profile. Use
        // two known stores, independent of that profile and Spaces.current.
        let home = Space.firstID
        browser.spaceID = home
        let away = Space(id: UUID(), name: "Destination", icon: "square", ownSignIns: ownSignIns)
        browser.spaces = [Space(id: home, name: "Source", icon: "square", ownSignIns: false), away]
        // Every new window rebuilds Spaces.sharing from the saved spaces.
        // Keep the fixture there too, while the menu's delayed action waits.
        Spaces.write(browser.spaces)
        Spaces.sharing = ownSignIns ? [home] : [home, away.id]
        func tab(_ name: String, in space: UUID) -> Fast.Tab {
            let tab = Fast.Tab(later: Spaces.store(for: space))
            tab.restore(url: URL(string: "https://space-send.invalid/\(name)")!, title: name)
            browser.prepare(tab)
            return tab
        }
        let moved = tab("moved", in: home), left = tab("left", in: home)
        let previous = tab("previous", in: away.id)
        browser.lay([moved, left]); browser.activeID = moved.id
        browser.parked[away.id] = Parked(tabs: [previous], active: previous.id)
        Browser.pretendHand = true
        defer {
            browser.letGo()
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            Spaces.write(savedSpaces)
            Folders.shared.browser = folders; Spaces.sharing = sharing; Spaces.current = current; Browser.pretendHand = hand
            Spaces.pageCounts[away.id] = nil
            Store.settings.set(saved, forKey: "spaces")
            for space in [home, away.id] {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(browser.windowID!.uuidString)-\(space.uuidString).json"))
            }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(browser.windowID!.uuidString).json"))
            Store.settings.removeObject(forKey: "window.\(browser.windowID!.uuidString).space")
        }
        #expect((Spaces.store(for: home) !== Spaces.store(for: away.id)) == ownSignIns)
        SpaceSend(browser: browser, tabs: [moved]).send(to: away.id)
        // Reproduce another suite opening a window before the menu fires.
        let other = Browser(windowID: UUID())
        defer {
            other.letGo()
            other.dozing?.invalidate(); other.stuck.timer?.invalidate(); other.pressure?.cancel()
            Store.settings.removeObject(forKey: "window.\(other.windowID!.uuidString).space")
            try? FileManager.default.removeItem(at: Store.file("session-window-\(other.windowID!.uuidString).json"))
        }
        #expect((Spaces.store(for: home) !== Spaces.store(for: away.id)) == ownSignIns)
        try await Task.sleep(for: .seconds(Browser.folderLeavesAfter + 0.5))
        #expect(browser.spaceID == away.id)
        let arrival = try #require(browser.tabs.first { ($0.pending ?? $0.address)?.path == "/moved" })
        #expect(browser.activeID == arrival.id)
        #expect(browser.activeID != previous.id)
        #expect(ownSignIns ? arrival !== moved : arrival === moved)
        #expect(browser.undoWindow())
        #expect(browser.spaceID == home)
        #expect(browser.active?.pending?.path == "/moved" || browser.active?.address?.path == "/moved")
    }
}
