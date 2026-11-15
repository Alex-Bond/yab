import Foundation
import Testing
import WebKit
@testable import Fast

/// Every window's pages run extensions' scripts, so each window and every
/// page in it is told to WebKit: a tab in a second window, one moved there,
/// and a page outside the row, a peek's or a small window's. A page WebKit
/// has no tab for answers its scripts "Tab not found", and one that asks
/// again at once (React Developer Tools) asks forever.
@MainActor
@Suite(.serialized)
struct ExtensionWindowsTests {
    private static func page(_ name: String) -> URL {
        URL(string: "data:text/html,%3Ctitle%3E\(name)%3C/title%3E")!
    }

    @Test func everyWindowAndEveryPageOutsideTheRowIsTold() async throws {
        // Followed, not started: the first window (`browser`) is another
        // suite's to set while this one runs beside it.
        let owner = Extensions.shared
        let one = Browser(windowID: UUID()), two = Browser(windowID: UUID())
        owner.follow(one)
        owner.follow(two)
        defer {
            owner.unfollow(one)
            owner.unfollow(two)
            for browser in [one, two] {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(browser.windowID!.uuidString).json"))
            }
        }
        let a = one.open(Self.page("A"), foreground: true)
        let b = two.open(Self.page("B"), foreground: true)
        let outside = one.blankTab()
        one.outside.append(outside)
        try await Task.sleep(for: .milliseconds(250))

        #expect(owner.told(a) == one.windowID)
        #expect(owner.told(b) == two.windowID)
        #expect(owner.told(outside) == one.windowID)
        #expect(owner.window(of: b)?.browser === two)
        #expect(owner.visibleTabs(in: two).map(\.id) == [b.id])
        // Outside the row, at no place in it, as a parked tab.
        #expect(!owner.visibleTabs(in: one).contains { $0 === outside })

        // Moved to the second window: the same tab to WebKit, there now.
        let before = owner.adapter(for: a)
        #expect(BrowserWindows.shared.move(a, from: one, to: two, announce: false))
        try await Task.sleep(for: .milliseconds(250))
        #expect(owner.adapter(for: a) === before)
        #expect(owner.told(a) == two.windowID)
        #expect(owner.window(of: a)?.browser === two)

        // Leaving the outside list closes it, to WebKit too.
        one.outside.removeAll { $0 === outside }
        try await Task.sleep(for: .milliseconds(250))
        #expect(owner.told(outside) == nil)

        // A window let go: none of its tabs is told any more.
        owner.unfollow(two)
        #expect(owner.told(a) == nil)
        #expect(owner.told(b) == nil)
    }

    @Test func firstNavigationRegistersTabBeforeTheRowBatch() {
        let owner = Extensions.shared
        let browser = Browser(windowID: UUID())
        owner.follow(browser)
        defer {
            owner.unfollow(browser)
            try? FileManager.default.removeItem(at: Store.file("session-window-\(browser.windowID!.uuidString).json"))
        }
        // No yield to the row's coalescing timer: document-start scripts
        // must already have a tab when they call runtime.connect.
        let front = browser.open(Self.page("First"), foreground: true)
        #expect(owner.told(front) == browser.windowID)
        let background = browser.open(Self.page("Background"), foreground: false)
        #expect(owner.told(background) == browser.windowID)
        let outside = browser.blankTab()
        browser.outside.append(outside)
        outside.go(to: Self.page("Outside"))
        #expect(owner.told(outside) == browser.windowID)
        #expect(owner.adapter(for: front) !== owner.adapter(for: background))
    }

    @Test func aDiscardedPageIsClosedNotOnlyLetGo() async throws {
        let tab = Tab(configuration: Web.configuration(extensions: false), factory: .webKitOnly)
        let web = requireNativeWebKitFixture(tab, "ExtensionWindowsTests")
        tab.go(to: Self.page("Kept"))
        try await Task.sleep(for: .milliseconds(200))
        // Something still holds the view, as an animation or a closure can.
        #expect((web.value(forKey: "_isClosed") as? Bool) == false)
        tab.close()
        // Seen off first (Farewell): taken to about:blank so its unload is
        // heard, and only then ended, 1.5 s at most after that.
        let deadline = Date().addingTimeInterval(3)
        while (web.value(forKey: "_isClosed") as? Bool) != true, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect((web.value(forKey: "_isClosed") as? Bool) == true)
    }

    /// A kept tab brought back asleep is a saved link, as Arc's is: not a
    /// tab to extensions until it is opened, and one again once put down.
    /// A loose tab asleep stays one (feedback #1039).
    @Test func aKeptTabPutDownIsNoTabToExtensions() async throws {
        let owner = Extensions.shared
        let one = Browser(windowID: UUID())
        owner.follow(one)
        defer {
            owner.unfollow(one)
            try? FileManager.default.removeItem(at: Store.file("session-window-\(one.windowID!.uuidString).json"))
        }
        let front = one.open(Self.page("Front"), foreground: true)
        let kept = one.open(Self.page("Kept"), foreground: false)
        let loose = one.open(Self.page("Loose"), foreground: false)
        kept.kept = true
        kept.restore(url: Self.page("Kept"), title: "Kept")
        loose.restore(url: Self.page("Loose"), title: "Loose")
        try await Task.sleep(for: .milliseconds(250))
        #expect(Set(owner.visibleTabs(in: one).map(\.id)) == [front.id, loose.id])
        #expect(owner.told(kept) == nil)
        #expect(owner.told(loose) == one.windowID)
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: Self.blank()))
        #expect(owner.window(of: front)?.tabs(for: context).count == 2)

        kept.wake()
        try await Task.sleep(for: .milliseconds(250))
        #expect(owner.told(kept) == one.windowID)
        #expect(owner.visibleTabs(in: one).contains { $0 === kept })

        kept.rest()
        try await Task.sleep(for: .milliseconds(250))
        #expect(owner.told(kept) == nil)
    }

    private static func blank() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-kept-ext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #"{"manifest_version": 3, "name": "Blank", "version": "1.0"}"#.write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        return folder
    }

    @Test func aBoostRoomCarriesNoExtensions() {
        #expect(Web.configuration(extensions: false).webExtensionController == nil)
        #expect(Web.configuration().webExtensionController != nil)
    }
}
