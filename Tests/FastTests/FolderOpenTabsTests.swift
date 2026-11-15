import Foundation
import Testing
@testable import Fast

/// Register 1451: favorites above, kept folders below, and an outside tab.
@MainActor
@Suite(.serialized)
struct FolderOpenTabsTests {
    @Test(arguments: [false, true])
    func openedRowsStayAfterLeavingAHoverListOrExpandedFolder(_ expanded: Bool) {
        let window = UUID(), browser = Browser(windowID: window)
        browser.takeOwnFolders()
        let folder = Nest(name: "资讯", open: false)
        let pin = Tab(), reddit = Tab(), x = Tab(), unopened = Tab(), outside = Tab()
        let tabs = [pin, reddit, x, unopened, outside]
        defer {
            browser.folderBook.browser = nil
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            tabs.forEach { $0.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(window.uuidString).json"))
            Store.settings.removeObject(forKey: "window.\(window.uuidString).space")
        }
        for (index, tab) in tabs.enumerated() {
            tab.restore(url: URL(string: "about:blank#folder-1451-\(index)")!, title: "Tab \(index)")
            browser.prepare(tab)
        }
        pin.pin = "Favorite"
        for tab in [reddit, x, unopened] { tab.kept = true; tab.nest = folder }
        browser.lay(tabs)
        browser.activeID = outside.id
        browser.folderBook.refresh()
        #expect(Folders.awake(in: tabs).isEmpty)
        #expect(browser.folderBook.place(of: reddit)?.shown == false)

        if expanded {
            folder.open = true
            browser.folderBook.refresh()
            browser.select(reddit)
            folder.open = false
        } else {
            browser.glance.pretendFolder(folder.key, true)
            browser.glance.pick(reddit)
        }
        #expect(!reddit.unopened)
        browser.select(outside)
        browser.folderBook.refresh()
        #expect(!folder.open)
        #expect(browser.folderBook.place(of: reddit)?.shown == true)
        #expect(browser.folderBook.place(of: unopened)?.shown == false)

        browser.glance.pretendFolder(folder.key, true)
        browser.glance.pick(x)
        browser.select(outside)
        // A page discarded for memory is still an opened tab.
        reddit.sleep(picture: nil)
        #expect(reddit.asleep && !reddit.unopened)
        browser.folderBook.refresh()
        #expect(Folders.awake(in: tabs) == [reddit.id, x.id])
        #expect(browser.folderBook.place(of: reddit)?.shown == true)
        #expect(browser.folderBook.place(of: x)?.shown == true)
        #expect(browser.folderBook.place(of: unopened)?.shown == false)

        reddit.rest()
        browser.folderBook.refresh()
        #expect(reddit.unopened)
        #expect(browser.folderBook.place(of: reddit)?.shown == false)
        #expect(browser.folderBook.place(of: x)?.shown == true)
        // A session-restored link has the same unopened state as a put-down tab.
        x.restore(url: URL(string: "about:blank#restored-1451")!, title: "X")
        browser.folderBook.refresh()
        #expect(Folders.awake(in: tabs).isEmpty)
        #expect(browser.folderBook.place(of: x)?.shown == false)
    }
}
