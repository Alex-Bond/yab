import AppKit
import Testing
import WebKit
@testable import Fast

/// #1113: actual existing menu dispatch and Browser action paths on
/// nonpersistent pages. Popup metadata is supplied explicitly through
/// PageHandle/PagePopup; engine event generation is deferred manual QA.
@MainActor @Suite(.serialized)
struct ImageTodayMenuTests {
    private final class OriginalImage: NSObject {
        var calls = 0
        @objc func open(_ item: NSMenuItem) { calls += 1 }
    }

    @MainActor private final class World {
        let browser: Browser
        let id = UUID()
        private let saved: [String: Any]
        private let initial: (Bool, Bool, Bool)
        private weak var previousFolderBrowser: Browser?

        init(groups: Bool = true) throws {
            try #require(Store.testing && Store.world != nil && Store.settings !== UserDefaults.standard,
                         "Only the native runner's named disposable world may construct this fixture")
            _ = NSApplication.shared
            previousFolderBrowser = Folders.shared.browser
            let made = Browser(windowID: id)
            made.lookForMailSignInLink = {}
            browser = made
            let keys = ["tabs.linkFolders", "folders.names", "float.leave"]
            saved = Dictionary(uniqueKeysWithValues: keys.compactMap { key in Store.settings.object(forKey: key).map { (key, $0) } })
            initial = (made.prefs.linkFolders, made.prefs.folderNames, made.prefs.floatsOnLeave)
            made.prefs.folderNames = false
            made.prefs.floatsOnLeave = false
            made.prefs.linkFolders = groups
            made.dropSpare()
            made.letGo()
            made.lay([])
            made.activeID = nil
        }

        func page(_ token: String, shy: Bool = true) -> Tab {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let tab = Tab(shy: shy, configuration: configuration, factory: .webKitOnly)
            tab.restore(url: URL(string: "about:blank#" + token)!, title: token)
            browser.moveIn(tab)
            return tab
        }

        func close() {
            browser.letGo()
            browser.dropSpare()
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            browser.prefs.linkFolders = initial.0
            browser.prefs.folderNames = initial.1
            browser.prefs.floatsOnLeave = initial.2
            for key in ["tabs.linkFolders", "folders.names", "float.leave"] {
                if let value = saved[key] { Store.settings.set(value, forKey: key) }
                else { Store.settings.removeObject(forKey: key) }
            }
            if Folders.shared.browser === browser { Folders.shared.browser = previousFolderBrowser }
            for prefix in ["session", "spaces"] {
                try? FileManager.default.removeItem(at: Store.file("\(prefix)-window-\(id.uuidString).json"))
            }
            Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
        }

        /// Calls the actual neutral Browser popup delegate. Construction is
        /// registered by the existing WebKit adapter; no uninitialized
        /// WKNavigationAction or real site/window-open is fabricated.
        func popup(from source: Tab, foreground: Bool?, kind: PageAction.Kind = .other,
                   destination: URL? = nil) throws -> Tab {
            let web = requireNativeWebKitFixture(source, "ImageTodayMenuTests")
            let popupID = UUID()
            let configuration = web.configuration.copy() as! WKWebViewConfiguration
            let context = WebKitPopup(configuration)
            web.navigationEvents.popups[popupID] = context
            defer { web.navigationEvents.popups[popupID] = nil }
            let action = PageAction(request: URLRequest(url: destination ?? URL(string: "about:blank#popup-" + popupID.uuidString)!),
                                    kind: kind, targetIsMainFrame: nil, source: nil,
                                    modifierFlags: [], buttonNumber: 1,
                                    shouldPerformDownload: false, userInitiated: true)
            let request = PagePopup(id: popupID, action: action, width: nil, height: nil,
                                    toolbarsVisible: nil, menuForeground: foreground)
            var replies: [UUID?] = []
            browser.page(web as any PageHandle, open: request) { replies.append($0) }
            try #require(replies.count == 1)
            let tab = try #require(context.tab)
            #expect(replies[0] == tab.id)
            #expect(tab.shy == source.shy && !tab.store.isPersistent && tab.store === source.store)
            return tab
        }
    }

    @Test(arguments: [false, true], [PageAction.Kind.other, .linkActivated])
    func nativeLinkMenuCreatesTheSameTodayGroupAsCommandClick(foreground: Bool, kind: PageAction.Kind) throws {
        let w = try World(); defer { w.close() }
        let before = w.page("before"), source = w.page("source"), after = w.page("after")
        w.browser.lay([before, source, after])
        w.browser.activeID = source.id
        w.browser.editing = !foreground
        let opened = try w.popup(from: source, foreground: foreground, kind: kind)
        let nest = try #require(source.nest)
        #expect(nest.today && nest.fleeting && nest.linked)
        #expect(opened.nest === nest && before.nest == nil && after.nest == nil)
        #expect(w.browser.tabs.map(\.id) == [before.id, source.id, opened.id, after.id])
        #expect(w.browser.activeID == (foreground ? opened.id : source.id))
        #expect(w.browser.editing == !foreground)
    }

    @Test func laterMenuLinksAndImagesStayInTheExistingTodayFolder() throws {
        let w = try World(); defer { w.close() }
        let source = w.page("source")
        w.browser.activeID = source.id
        let first = try w.popup(from: source, foreground: false)
        let nest = try #require(source.nest)
        let next = try w.popup(from: first, foreground: false)
        #expect(next.nest === nest && first.nest === nest)
        w.browser.imageAct(.open, URL(string: "about:blank#image-in-folder")!, in: first, foreground: false)
        let image = try #require(w.browser.tabs.first { $0 !== source && $0 !== first && $0 !== next })
        #expect(image.nest === nest)
        #expect(Set(w.browser.tabs.compactMap { $0.nest.map(ObjectIdentifier.init) }).count == 1)
        #expect(w.browser.activeID == source.id)
    }

    @Test func onlyAnExplicitBackgroundLinkArmsVideoPlayback() throws {
        let w = try World(); defer { w.close() }
        let source = w.page("source")
        w.browser.activeID = source.id
        let url = URL(string: "https://video.test/watch")!
        let background = try w.popup(from: source, foreground: false, destination: url)
        #expect(background.videoOpening.armed && !background.videoOpening.shown)
        #expect(w.browser.activeID == source.id)
        let foreground = try w.popup(from: source, foreground: true, destination: url)
        #expect(!foreground.videoOpening.armed)
        let scripted = try w.popup(from: source, foreground: nil, kind: .other, destination: url)
        #expect(!scripted.videoOpening.armed)
    }

    @Test func groupingOffPreservesAdjacentPlacementWithoutMakingAFolder() throws {
        let w = try World(groups: false); defer { w.close() }
        let before = w.page("before"), source = w.page("source"), after = w.page("after")
        w.browser.lay([before, source, after]); w.browser.activeID = source.id
        let opened = try w.popup(from: source, foreground: false)
        #expect(source.nest == nil && opened.nest == nil)
        #expect(w.browser.tabs.map(\.id) == [before.id, source.id, opened.id, after.id])
        w.browser.imageAct(.open, URL(string: "about:blank#image-off")!, in: source, foreground: false)
        let image = try #require(w.browser.tabs.first { $0.linkedFrom == source.id && $0 !== opened })
        #expect(image.nest == nil)
        #expect(w.browser.tabs.map(\.id) == [before.id, source.id, opened.id, image.id, after.id])
        #expect(w.browser.activeID == source.id)
    }

    @Test(arguments: [PageAction.Kind.other, .linkActivated])
    func ordinaryScriptAndTargetBlankDoNotGainNewAutomaticGroups(kind: PageAction.Kind) throws {
        let w = try World(); defer { w.close() }
        let source = w.page("source")
        w.browser.activeID = source.id
        let opened = try w.popup(from: source, foreground: nil, kind: kind)
        #expect(source.nest == nil && opened.nest == nil)
        #expect(w.browser.activeID == opened.id)
    }

    @Test func aMenuFromAKeptSourceGroupsOnlyItsSecondAndLaterDestinations() throws {
        let w = try World(); defer { w.close() }
        // Private tabs cannot be kept. Keep an ordinary tab through the
        // real action, with the same disposable store as the other pages.
        let source = w.page("kept", shy: false)
        try #require(source.keepable && !source.store.isPersistent)
        w.browser.keepTabs([source], in: nil)
        try #require(source.nest == nil && source.kept)
        w.browser.activeID = source.id
        // HTTP metadata reaches the existing kept-link Peek branch. The
        // candidate only registers the child; no engine loads this URL.
        // A baseline's erroneous Peek can only reach refused loopback.
        let destination = URL(string: "http://127.0.0.1:9/owned-menu-metadata")!
        let first = try w.popup(from: source, foreground: false, kind: .linkActivated, destination: destination)
        #expect(w.browser.peeking == nil && first.nest == nil)
        #expect(source.nest == nil && source.kept)
        let second = try w.popup(from: source, foreground: false, kind: .linkActivated, destination: destination)
        let nest = try #require(first.nest)
        #expect(second.nest === nest && nest.today && nest.linked)
        #expect(source.nest == nil && source.kept)
        let third = try w.popup(from: source, foreground: false, kind: .linkActivated, destination: destination)
        #expect(third.nest === nest && second.nest === nest && first.nest === nest)
        #expect(source.nest == nil && source.kept)
        #expect(w.browser.activeID == source.id)
    }

    @Test(arguments: ["plain", "command", "shift-command"])
    func theExistingImageMenuCarriesFocusAndPlacementThroughTheRealCallbacks(mode: String) throws {
        let w = try World(); defer { w.close() }
        let before = w.page("before"), source = w.page("source"), after = w.page("after")
        w.browser.lay([before, source, after]); w.browser.activeID = source.id
        let picture = URL(string: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==")!
        let target = OriginalImage(), menu = NSMenu()
        menu.autoenablesItems = false
        let item = NSMenuItem(title: "Open Image in New Tab", action: #selector(OriginalImage.open(_:)), keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierOpenImageInNewWindow")
        item.target = target
        menu.addItem(item)
        let flags: NSEvent.ModifierFlags = mode == "command" ? .command : mode == "shift-command" ? [.command, .shift] : []
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero,
            modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let web = requireNativeWebKitFixture(source, "ImageTodayMenuTests")
        source.pointedImage = (picture, CACurrentMediaTime())
        web.willOpenMenu(menu, with: event)
        web.didCloseMenu(menu, with: event)
        let index = try #require(menu.items.firstIndex { $0 === item })
        menu.performActionForItem(at: index)
        let image = try #require(w.browser.tabs.first { $0 !== before && $0 !== source && $0 !== after })
        #expect(image.address == picture && image.shy && image.store === source.store)
        #expect(image.linkedFrom == source.id && image.from == source.id)
        #expect(w.browser.tabs.map(\.id) == [before.id, source.id, image.id, after.id])
        #expect(w.browser.activeID == (mode == "command" ? source.id : image.id))
        #expect(source.nest != nil && image.nest === source.nest)
        #expect(target.calls == 0, "An image the app identified must use its own action once")
    }

    @Test func anUnknownImageStillForwardsTheOriginalActionWithoutOpeningAnAppTab() throws {
        let w = try World(); defer { w.close() }
        let source = w.page("source")
        let menu = NSMenu(), target = OriginalImage()
        menu.autoenablesItems = false
        let item = NSMenuItem(title: "Open Image", action: #selector(OriginalImage.open(_:)), keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierOpenImageInNewWindow")
        item.target = target; menu.addItem(item)
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero,
            modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        source.pointedImage = nil
        requireNativeWebKitFixture(source, "ImageTodayMenuTests").willOpenMenu(menu, with: event)
        requireNativeWebKitFixture(source, "ImageTodayMenuTests").didCloseMenu(menu, with: event)
        menu.performActionForItem(at: try #require(menu.items.firstIndex { $0 === item }))
        #expect(target.calls == 1 && w.browser.tabs.count == 1 && w.browser.activeID == source.id)
    }
}
