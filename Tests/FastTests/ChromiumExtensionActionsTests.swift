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

    @Test func installWordsAddChromeOnlyGrantsAfterYabsOwn() {
        let manifest: [String: Any] = ["permissions": ["history", "storage", "tabs", "downloads"]]
        let lines = ChromiumInstallWords.lines(manifest: manifest, yab: ["See which tabs you have open, and where"])
        #expect(lines == ["See which tabs you have open, and where", "Read and change your browsing history", "Manage your downloads"])
        let proxy = ChromiumInstallWords.lines(manifest: ["permissions": ["proxy"]], yab: ["Read and change every site you visit"])
        #expect(proxy == ["Read and change every site you visit"])
    }
}
