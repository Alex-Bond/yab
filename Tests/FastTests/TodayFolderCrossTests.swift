import Foundation
import Testing
@testable import Fast

/// The Today row's cross uses the same close/reopen path as its menu.
@MainActor
@Suite(.serialized)
struct TodayFolderCrossTests {
    @Test(arguments: [false, true])
    func closeAndReopenWholeFolder(_ tidy: Bool) throws {
        let window = UUID(), browser = Browser(windowID: window)
        browser.takeOwnFolders()
        let tabs = (0..<4).map { index in
            let tab = Tab()
            tab.restore(url: URL(string: "https://today-cross.test/\(index)")!, title: "Page \(index)")
            browser.prepare(tab)
            return tab
        }
        defer {
            browser.folderBook.browser = nil
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            browser.tabs.forEach { $0.close() }
            tabs.forEach { $0.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(window.uuidString).json"))
            Store.settings.removeObject(forKey: "window.\(window.uuidString).space")
        }
        browser.lay(tabs)
        browser.activeID = tabs[3].id
        if tidy {
            browser.applyTidy([TidyTabs.Group(name: "Tidy group", tabs: [0, 1])], of: tabs)
        } else {
            browser.newFolder(with: Array(tabs.prefix(2)), today: true)
            browser.folderBook.naming = nil
        }
        let folder = try #require(tabs[0].nest)
        #expect(folder.today)
        #expect(tabs[1].nest === folder)
        browser.close(browser.tabs(in: folder))
        #expect(browser.tabs.map(\.id) == Array(tabs.suffix(2)).map(\.id))
        #expect(browser.activeID == tabs[3].id)
        let ghost = try #require(browser.ghosts.last)
        browser.reopen(from: ghost)
        #expect(Set(browser.tabs.compactMap(\.address)) == Set(tabs.compactMap(\.address)))
        let memberURLs = Set(tabs.prefix(2).compactMap(\.address))
        let restored = browser.tabs.filter { $0.address.map(memberURLs.contains) == true }
        #expect(restored.count == 2)
        #expect(restored.allSatisfy { $0.nest?.today == true && !$0.kept })
        #expect(restored.first?.nest === restored.last?.nest)
    }
}
