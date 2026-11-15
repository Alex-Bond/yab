import AppKit
import SwiftUI
import Testing
@testable import Fast

/// #1194: invoke the actual ordinary and search/Option menu handlers on a
/// sleeping tab while a different tab is selected. Passive actions must
/// use their explicit target without selecting or loading its page.
@MainActor
@Suite(.serialized)
struct TabMenuPassiveTests {
    init() throws {
        try #require(Store.testing && Store.world != nil && Store.settings !== UserDefaults.standard)
        _ = NSApplication.shared
    }

    private func withTabs(_ body: (Browser, Fast.Tab, Fast.Tab) throws -> Void) rethrows {
        let id = UUID(), browser = Browser(windowID: id)
        let target = Fast.Tab(), current = Fast.Tab()
        defer {
            browser.cancelTabEdit()
            browser.letGo()
            browser.dropSpare()
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            for tab in [target, current] where !tab.gone { tab.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
        }
        for tab in [target, current] { browser.prepare(tab) }
        target.restore(url: URL(string: "https://passive-menu.invalid/\(id.uuidString)")!, title: "Sleeping target")
        browser.lay([target, current])
        browser.activeID = current.id
        try body(browser, target, current)
    }

    @Test(arguments: ["Copy Link", "Rename…", "Duplicate"], [false, true])
    func aSleepingTargetsMenuLeavesTheCurrentTabSelected(action: String, extra: Bool) throws {
        let id = UUID(), windowID = UUID()
        let browser = Browser(windowID: windowID)
        let target = Fast.Tab(), current = Fast.Tab()
        defer {
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            for tab in browser.tabs + browser.parkedTabs { tab.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(windowID.uuidString).json"))
            Store.settings.removeObject(forKey: "window.\(windowID.uuidString).space")
        }
        for tab in [target, current] { browser.prepare(tab) }
        let url = URL(string: "https://passive-menu.invalid/\(id.uuidString)")!
        target.restore(url: url, title: "Sleeping target")
        current.restore(url: URL(string: "https://current-menu.invalid/")!, title: "Current")
        browser.lay([target, current])
        browser.activeID = current.id
        #expect(target.asleep)
        #expect(target.builtPage == nil)

        let menu = NSHostingMenu(rootView: TabMenu(browser: browser, tab: target, close: {}))
        menu.update()
        let level: NSMenu
        if extra {
            level = try #require(menu.items.first { $0.title == ActionMenu.tabSearchActions }?.submenu)
            level.update()
        } else {
            level = menu
        }
        let title = extra && action == "Copy Link" ? "Copy URL" : action
        let index = try #require(level.items.firstIndex { $0.title == title })
        #expect(level.items[index].isEnabled)
        level.performActionForItem(at: index)

        #expect(browser.activeID == current.id, "\(title) must not select its target")
        #expect(target.asleep, "\(title) must leave its target asleep")
        #expect(target.builtPage == nil, "\(title) must not create its target's page")
        if action == "Copy Link" {
            #expect(NSPasteboard.general.string(forType: .string) == Diary.shareable(url).absoluteString)
            #expect(browser.tabs.count == 2)
        } else if action == "Rename…" {
            #expect(browser.editingTab == target.id)
            #expect(browser.tabDraft == "Sleeping target")
            browser.tabDraft = "Renamed while asleep"
            browser.commitTabEdit()
            #expect(target.label == "Renamed while asleep")
            #expect(browser.activeID == current.id)
            #expect(target.asleep && target.builtPage == nil)
        } else {
            let copy = try #require(browser.tabs.first { $0 !== target && $0 !== current })
            #expect(browser.tabs.count == 3)
            #expect(copy.address == url)
            #expect(copy.from == target.id)
            let at = try #require(browser.tabs.firstIndex { $0 === target })
            #expect(browser.tabs[at + 1] === copy)
        }
    }

    @Test(arguments: [0, 1, 2, 3])
    func copyAddressesNeverSelectsItsSingleAddressOrFallsBackToTheCurrentTab(kind: Int) throws {
        try withTabs { browser, target, current in
            let url = try #require(target.address)
            current.restore(url: URL(string: "https://current-menu.invalid/")!, title: "Current")
            let blank = Fast.Tab()
            defer { blank.close() }
            let groups: [[Fast.Tab]] = [[], [blank], [target], [blank, target]]
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("Unchanged", forType: .string)
            browser.copyAddresses(groups[kind])
            #expect(NSPasteboard.general.string(forType: .string) == (kind < 2 ? "Unchanged" : Diary.shareable(url).absoluteString))
            #expect(browser.activeID == current.id)
            #expect(target.pending == url && target.builtPage == nil)
            #expect(current.asleep && current.builtPage == nil)
            #expect(blank.isBlank && blank.builtPage == nil)
        }
    }

    @Test func duplicatingASingleExplicitTargetLeavesItAsleepAndCurrentTabSelected() throws {
        try withTabs { browser, target, current in
            browser.duplicate([target])
            #expect(browser.activeID == current.id)
            #expect(target.asleep && target.builtPage == nil)
            let copy = try #require(browser.tabs.first { $0 !== target && $0 !== current })
            #expect(copy.address == target.address && copy.from == target.id)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func groupedCopyAndDuplicateLeaveSleepingOriginalsAlone(extra: Bool, copying: Bool) throws {
        try withTabs { browser, target, current in
            if !copying { current.restore(url: URL(string: "https://current-menu.invalid/")!, title: "Current") }
            browser.pickAll()
            let menu = NSHostingMenu(rootView: TabMenu(browser: browser, tab: target, close: {}))
            menu.update()
            let level: NSMenu
            if extra {
                level = try #require(menu.items.first { $0.title == ActionMenu.tabSearchActions }?.submenu)
                level.update()
            } else {
                level = menu
            }
            #expect(browser.activeID == current.id && target.asleep && target.builtPage == nil)
            let title = copying ? "Copy 2 URLs" : "Duplicate 2 Tabs"
            let index = try #require(level.items.firstIndex { $0.title == title })
            #expect(level.items[index].isEnabled)
            level.performActionForItem(at: index)
            #expect(browser.activeID == current.id)
            #expect(target.asleep && target.builtPage == nil)
            #expect(current.builtPage == nil)
            if copying {
                #expect(current.isBlank)
                #expect(NSPasteboard.general.string(forType: .string) == target.address.map(Diary.shareable)?.absoluteString)
                #expect(browser.tabs.count == 2)
            } else {
                #expect(current.asleep)
                let copies = browser.tabs.filter { $0 !== target && $0 !== current }
                #expect(copies.count == 2)
                #expect(copies.map(\.address) == [target.address, current.address])
            }
        }
    }

    @Test(arguments: ["Copy Link", "Rename…"], [false, true])
    func actionMenuSearchAndOptionKeepTheSleepingTargetPassive(action: String, option: Bool) throws {
        try withTabs { browser, target, current in
            let list = ActionMenuList(menu: NSHostingMenu(rootView: TabMenu(browser: browser, tab: target, close: {})), falls: true)
            if option { list.modifiers(.option) } else { list.query = action }
            let title = option && action == "Copy Link" ? "Copy Markdown Link" : action
            let index = try #require(list.lines.firstIndex { $0.title == title })
            #expect(list.lines[index].enabled)
            list.take(index)
            #expect(browser.activeID == current.id && target.asleep && target.builtPage == nil)
            if action == "Copy Link" {
                let page = try #require(MarkdownLink.page(target))
                #expect(NSPasteboard.general.string(forType: .string) == (option ? MarkdownLink.markdown(page) : page.url.absoluteString))
            } else {
                #expect(browser.editingTab == target.id && browser.tabDraft == "Sleeping target")
            }
        }
    }

    @Test(arguments: [false, true], [false, true])
    func editingASleepingHomeFromEitherMenuNeverSelectsOrLoadsIt(pinned: Bool, extra: Bool) throws {
        try withTabs { browser, target, current in
            if pinned { target.pin = "S" } else { target.kept = true }
            let home = try #require(target.home)
            let menu = NSHostingMenu(rootView: TabMenu(browser: browser, tab: target, close: {}))
            menu.update()
            let level: NSMenu
            if extra {
                level = try #require(menu.items.first { $0.title == ActionMenu.tabSearchActions }?.submenu)
                level.update()
            } else {
                level = menu
            }
            let submenu = try #require(level.items.first { $0.title == (pinned ? "Edit Pinned Page" : "Edit Kept Page") }?.submenu)
            submenu.update()
            let edit = try #require(submenu.items.firstIndex { $0.title == "Edit…" })
            submenu.performActionForItem(at: edit)
            #expect(browser.activeID == current.id && target.pending == home && target.builtPage == nil)
            #expect(browser.editingTab == target.id && browser.editingHome && browser.tabDraft == home.absoluteString)
            browser.cancelTabEdit()
            #expect(target.home == home && target.pending == home)
            submenu.performActionForItem(at: edit)
            let newHome = URL(string: "https://passive-menu.invalid/new-home")!
            browser.tabDraft = newHome.absoluteString
            browser.commitTabEdit()
            #expect(target.home == newHome && target.pending == newHome && target.address == newHome)
            #expect(browser.activeID == current.id && target.asleep && target.builtPage == nil)
            #expect(browser.editingTab == nil && !browser.editingHome)
        }
    }

    @Test func movingASleepingTabBehindAnotherWindowsPageDoesNotWakeIt() throws {
        try withTabs { source, target, current in
            try withTabs { destination, other, front in
                try #require(source.spaceID == destination.spaceID)
                #expect(BrowserWindows.shared.move(target, from: source, to: destination,
                                                   announce: false, selecting: false, undoable: false))
                #expect(source.activeID == current.id && destination.activeID == front.id)
                #expect(!source.tabs.contains { $0 === target })
                #expect(destination.tabs.contains { $0 === target })
                #expect(target.asleep && target.builtPage == nil)
                #expect(other.asleep && other.builtPage == nil)
            }
        }
    }
}
