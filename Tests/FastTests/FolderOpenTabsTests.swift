import Foundation
import Testing
@testable import Fast

/// Register 1451: favorites above, kept folders below, and an outside tab.
@MainActor
@Suite(.serialized)
struct FolderOpenTabsTests {
    @Test func selectionAndNewTabArrivalDoNotShutAnExpandedFavoriteFolder() async throws {
        let w = NestedFoldersBrowserTests.world()
        defer { w.done() }
        let b = w.browser
        b.takeOwnFolders()
        let inside = try #require(w.tabs["sem"])
        let outside = try #require(w.tabs["hn"])
        w.seo.open = true
        b.select(inside)
        b.folderBook.refresh()
        let extra = Tab()
        defer { extra.close() }
        extra.restore(url: URL(string: "about:blank#1451-arrival")!, title: "Arrival")
        b.prepare(extra)
        for tab in [outside, extra] {
            if tab === extra { b.lay(b.tabs + [extra]) }
            b.select(tab)
            // Let the normal publishers refresh the projection. A manual
            // refresh alone would miss an arrival/subscription regression.
            try await Task.sleep(for: .milliseconds(100))
            #expect(w.seo.open)
            #expect(b.folderBook.place(of: inside)?.shown == true)
        }
    }

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

        // Feedback #1690: minus targets this folder's opened rows even
        // while an unrelated tab owns focus. Neither page is closed.
        browser.folderBook.unpeek(folder)
        #expect(browser.activeID == outside.id)
        #expect(browser.folderBook.place(of: reddit)?.shown == false)
        #expect(browser.folderBook.place(of: x)?.shown == false)
        #expect(!reddit.unopened && !x.unopened)
        browser.select(x)
        browser.folderBook.refresh()
        browser.select(outside)
        browser.folderBook.refresh()
        #expect(browser.folderBook.place(of: x)?.shown == true)

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
    @Test func hiddenFoldersSurviveUnrelatedSelectionAndListChanges() throws {
        let w = NestedFoldersBrowserTests.world()
        defer { w.done() }
        let b = w.browser
        b.takeOwnFolders()
        let inside = try #require(w.tabs["sem"])
        let outside = try #require(w.tabs["hn"])
        let another = try #require(w.tabs["brex"])
        b.activeID = inside.id
        b.folderBook.refresh()
        w.seo.open = false
        b.folderBook.refresh()
        b.folderBook.unpeek(w.seo)
        #expect(!w.seo.open)
        #expect(b.folderBook.place(of: inside)?.shown == false)
        // Both changes used to clear every folder's minus suppression.
        for tab in [outside, another] {
            b.activeID = tab.id
            b.folderBook.refresh()
            #expect(b.folderBook.place(of: inside)?.shown == false)
            #expect(!w.seo.open)
        }
        let extra = Tab()
        defer { extra.close() }
        extra.restore(url: URL(string: "about:blank#outside-folder")!, title: "Outside")
        b.prepare(extra)
        b.lay(b.tabs + [extra])
        b.activeID = extra.id
        b.folderBook.refresh()
        #expect(b.folderBook.place(of: inside)?.shown == false)
        b.lay(b.tabs.filter { $0 !== extra })
        b.activeID = outside.id
        b.folderBook.refresh()
        #expect(b.folderBook.place(of: inside)?.shown == false)
        // Reordering the list must preserve the hidden state too.
        b.lay(Array(b.tabs.reversed()))
        b.folderBook.refresh()
        #expect(b.folderBook.place(of: inside)?.shown == false)
        // Explicitly picking a descendant releases that folder's minus.
        b.activeID = inside.id
        b.folderBook.refresh()
        #expect(b.folderBook.place(of: inside)?.shown == true)
        #expect(!w.seo.open)
    }

    @Test func reopeningAHiddenFolderReleasesItsMinus() async throws {
        let w = NestedFoldersBrowserTests.world()
        defer { w.done() }
        let b = w.browser
        b.takeOwnFolders()
        let inside = try #require(w.tabs["sem"])
        b.activeID = inside.id
        b.folderBook.refresh()
        w.seo.open = false
        b.folderBook.refresh()
        b.folderBook.unpeek(w.seo)
        #expect(b.folderBook.place(of: inside)?.shown == false)
        // Selecting the current tab from a list must reveal it as well.
        b.select(inside)
        b.folderBook.refresh()
        #expect(b.folderBook.place(of: inside)?.shown == true)
        b.folderBook.unpeek(w.seo)
        #expect(b.folderBook.place(of: inside)?.shown == false)
        b.folderBook.toggle(w.seo.key)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        b.folderBook.refresh()
        #expect(w.seo.open)
        #expect(b.folderBook.place(of: inside)?.shown == true)
        b.folderBook.toggle(w.seo.key)
        b.folderBook.refresh()
        #expect(b.folderBook.place(of: inside)?.shown == true)
    }

}
