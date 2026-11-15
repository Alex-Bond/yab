import Foundation
import Testing
import YabCoreClient
@testable import Fast

@Suite(.serialized)
@MainActor
struct ChromiumExtensionActionsTests {
    private let id = String(repeating: "a", count: 32)

    @Test func nativeActionStateKeepsChromesBadgeTitleAndIcon() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
        let row: JSONValue = .object([
            "id": .string(id), "action": .bool(true), "tabId": .number(7), "title": .string("Dark Reader: on"),
            "badge": .string("12"), "countHidden": .bool(false), "enabled": .bool(true), "popup": .bool(true),
            "icon": .string("data:image/png;base64," + png),
        ])
        let state = try #require(ChromiumColumn.Native.parse(row, id: id))
        #expect(state.title == "Dark Reader: on")
        #expect(state.badge == "12")
        #expect(state.nativeTab == 7)
        #expect(state.popup && state.enabled)
        #expect(state.icon == Data([0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func hiddenCountsAndErrorsNeverBecomeABadge() throws {
        let hidden = try #require(ChromiumColumn.Native.parse(.object([
            "id": .string(id), "action": .bool(true), "badge": .string(""), "countHidden": .bool(true),
        ]), id: id))
        #expect(hidden.badge.isEmpty && hidden.countHidden)
        let failed = try #require(ChromiumColumn.Native.parse(.object([
            "id": .string(id), "error": .string("No running extension worker"),
        ]), id: id))
        #expect(failed.badge.isEmpty && failed.error != nil && failed.icon == nil)
        // Another extension's row or one with no action is not this button's.
        #expect(ChromiumColumn.Native.parse(.object(["id": .string(String(repeating: "b", count: 32)), "action": .bool(true)]), id: id) == nil)
        #expect(ChromiumColumn.Native.parse(.object(["id": .string(id), "action": .bool(false)]), id: id) == nil)
    }

    @Test func aLongBadgeIsCutAndANonPNGIconIsRefused() throws {
        let state = try #require(ChromiumColumn.Native.parse(.object([
            "id": .string(id), "action": .bool(true), "badge": .string("1234567890"),
            "icon": .string("data:image/svg+xml;base64,PHN2Zy8+"), "enabled": .bool(false),
        ]), id: id))
        #expect(state.badge == "1234")
        #expect(state.icon == nil)
        #expect(!state.enabled)
    }

    @Test func pinsAreKeptInOrderAndPasswordManagersPinOnceOnArrival() throws {
        let native = ChromiumExtensions(profile: "test-" + UUID().uuidString, privateMode: false)
        defer { try? FileManager.default.removeItem(at: Store.file("ChromiumImports").appendingPathComponent(native.profile + ".json")) }
        let b = String(repeating: "b", count: 32)
        try native.setPinned(id, true)
        try native.setPinned(b, true)
        #expect(native.pinnedIDs == [id, b])
        try native.setPinned(id, false)
        #expect(native.pinnedIDs == [b])
        let onePassword = "aeblfdkhhhdcdjpifhhbdiojplfjncoa"
        #expect(Extensions.passwordManagers.contains(onePassword))
        native.pinOnArrival(onePassword)
        #expect(native.pinnedIDs == [onePassword, b])
        try native.setPinned(onePassword, false)
        native.pinOnArrival(onePassword)
        #expect(native.pinnedIDs == [b])
        native.pinOnArrival(id)
        #expect(native.pinnedIDs == [b])
        #expect(throws: (any Error).self) { try native.setPinned("not-an-id", true) }
    }

    /// The row of pinned extensions over a Chromium tab is its profile's: on
    /// a switch to a tab whose page has no native tab yet (one brought back
    /// from last time, made as it is looked at) it went empty until the
    /// helper answered, while the column kept its room (owner, 2026-11-05).
    @Test func theRowIsTheProfilesPinsBeforeThePageHasItsNativeTab() throws {
        guard #available(macOS 15.4, *) else { return }
        let factory = PageEngineFactory(kinds: [.chromium]) { tab, _ in ChromiumPage(tab: tab) }
        let column = ChromiumColumn.shared
        let (a, b, c, off) = (id, String(repeating: "b", count: 32), String(repeating: "c", count: 32), String(repeating: "d", count: 32))
        func item(_ id: String, _ state: String = "ENABLED") throws -> ChromiumExtensions.Item {
            try ChromiumExtensions.Item(.object(["id": .string(id), "name": .string("Fixture " + id.prefix(1)), "state": .string(state)]))
        }
        var tabs: [Tab] = [], profiles: [String] = []
        func made(_ items: [ChromiumExtensions.Item], pins: [String]) throws -> (Tab, ChromiumPage) {
            let profile = "row-" + UUID().uuidString.prefix(8).lowercased()
            profiles.append(profile)
            let tab = Tab(engine: .chromium, factory: factory)
            tabs.append(tab)
            let page = try #require(tab.prepareChromiumPageForAdoption(profile: profile))
            page.extensions.listedForTest(items)
            for pin in pins { try page.extensions.setPinned(pin, true) }
            return (tab, page)
        }
        defer {
            for tab in tabs {
                (tab.builtPage as? ChromiumPage)?.retire(call: false, pictureInPicture: false)
                tab.close()
            }
            for profile in profiles {
                try? FileManager.default.removeItem(at: Store.file("ChromiumImports").appendingPathComponent(profile + ".json"))
            }
        }

        // The tab just switched to: its page made, the helper not answered.
        let (shown, page) = try made([item(a), item(b), item(c), item(off, "DISABLED")], pins: [c, a, off])
        #expect(page.remoteID == nil)
        #expect(column.buttons(for: shown).map(\.id) == [c, a])
        #expect(column.buttons(for: shown, all: true).map(\.id) == [c, a, b])
        #expect(column.pinnedIDs(for: shown) == [c, a], "The room the column keeps is the row's own")

        // A tab of the same profile whose page went: the same row, and
        // drawing it builds no page.
        let away = Tab(engine: .chromium, factory: factory)
        tabs.append(away)
        _ = try #require(away.prepareChromiumPageForAdoption(profile: page.profile))
        away.unbuildForEngineTest()
        #expect(away.builtPage == nil)
        #expect(column.buttons(for: away).map(\.id) == [c, a])
        #expect(column.pinnedIDs(for: away) == [c, a])
        #expect(away.builtPage == nil, "The row never builds a page")

        // Another profile keeps its own set; one with nothing pinned shows none.
        let (other, _) = try made([item(b), item(c)], pins: [b])
        #expect(column.buttons(for: other).map(\.id) == [b])
        #expect(column.buttons(for: shown).map(\.id) == [c, a])
        let (bare, _) = try made([item(a)], pins: [])
        #expect(column.buttons(for: bare).isEmpty && column.pinnedIDs(for: bare).isEmpty)

        // WebKit and private tabs are not this column's.
        let webKit = Tab(engine: .webKit, factory: PageEngineFactory(kinds: [.webKit]) { tab, _ in tab.buildWebKitPage() })
        let shy = Tab(shy: true, engine: .chromium, factory: factory)
        tabs += [webKit, shy]
        #expect(column.buttons(for: webKit).isEmpty && column.buttons(for: shy).isEmpty)
        #expect(column.pinnedIDs(for: webKit).isEmpty && column.pinnedIDs(for: shy).isEmpty)
    }

    @Test func nativeRoutesStayVisibleWithoutRequestingAnExtensionWorker() throws {
        let connected = ApplePasswordExtensionRoute.isConnected
        defer { ApplePasswordExtensionRoute.isConnected = connected }
        let apple = PasswordManagers.apple
        let off = String(repeating: "b", count: 32)
        func item(_ id: String, _ state: String) throws -> ChromiumExtensions.Item {
            try ChromiumExtensions.Item(.object(["id": .string(id), "name": .string("Fixture"), "state": .string(state)]))
        }
        let rows = try [item(apple, "DISABLED"), item(id, "ENABLED"), item(off, "DISABLED")]
        let pins = [apple, off, id]
        ApplePasswordExtensionRoute.isConnected = { false }
        #expect(ChromiumColumn.members(rows, pinnedIDs: pins, all: false).pinned.map(\.id) == [apple, id])
        #expect(ChromiumColumn.actionIDs(rows, pinnedIDs: pins) == [id])
        #expect(ChromiumColumn.actionIDs(rows, pinnedIDs: [apple]) == [])
        ApplePasswordExtensionRoute.isConnected = { true }
        #expect(ChromiumColumn.members(rows, pinnedIDs: pins, all: false).pinned.map(\.id) == [id])
        #expect(ChromiumColumn.actionIDs(rows, pinnedIDs: pins) == [id])
        // Even a list read from before launch disabled Apple's worker is
        // the native route, never a Chromium action.
        #expect(ChromiumColumn.actionIDs(try [item(apple, "ENABLED")], pinnedIDs: [apple]) == [])
        #expect(ChromiumColumn.actionIDs(rows, pinnedIDs: []) == [])
    }

    @Test func installWordsAddChromeOnlyGrantsAfterYabsOwn() {
        let manifest: [String: Any] = ["permissions": ["history", "storage", "tabs", "downloads"]]
        let lines = ChromiumInstallWords.lines(manifest: manifest, yab: ["See which tabs you have open, and where"])
        #expect(lines == ["See which tabs you have open, and where", "Read and change your browsing history", "Manage your downloads"])
        let proxy = ChromiumInstallWords.lines(manifest: ["permissions": ["proxy"]], yab: ["Read and change every site you visit"])
        #expect(proxy == ["Read and change every site you visit"])
    }
}
