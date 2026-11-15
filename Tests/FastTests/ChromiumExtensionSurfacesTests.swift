import Foundation
import Testing
import YabCoreClient
@testable import Fast

/// Gap 10 of RESULT-extensions-parity.md: the button's menu rows an
/// extension adds (contextMenus, context "action") and its omnibox keyword,
/// on Chromium tabs through CEF patch 0124.
struct ChromiumExtensionSurfacesTests {
    private let id = "ennhhnlidajopkaghklalaedfmmmgega"

    @Test func readsChromesActionMenuRows() {
        let rows = ChromiumActionMenu.Row.parse(.array([
            .object(["id": .string("fx-action"), "title": .string("Fixture action item"), "type": .string("normal"), "enabled": .bool(true)]),
            .object(["type": .string("separator")]),
            .object(["id": .string("fx-check"), "title": .string("Fixture check"), "type": .string("checkbox"), "checked": .bool(true)]),
            .object(["id": .string("#3"), "title": .string("More"), "type": .string("normal"),
                     "items": .array([.object(["id": .string("#4"), "title": .string("Inner"), "type": .string("radio")])])]),
            .object(["id": .string("x"), "title": .string("No kind")]),
            .object(["type": .string("normal"), "title": .string("No id")]),
        ]))
        #expect(rows.map(\.id) == ["fx-action", "-", "fx-check", "#3"])
        #expect(rows[1].kind == .separator)
        #expect(rows[2].kind == .checkbox && rows[2].checked)
        #expect(rows[3].rows.map(\.title) == ["Inner"] && rows[3].rows[0].kind == .radio)
        #expect(ChromiumActionMenu.Row.parse(.null).isEmpty)
    }

    @Test func readsTheManifestsKeyword() {
        let plain = Data(#"{"omnibox": {"keyword": "FxK "}}"#.utf8)
        #expect(ExtensionOmnibox.keyword(manifest: plain) { _, _ in nil } == "fxk")
        let localized = Data(#"{"default_locale": "en", "omnibox": {"keyword": "__MSG_kw__"}}"#.utf8)
        #expect(ExtensionOmnibox.keyword(manifest: localized) { locale, name in locale == "en" && name == "kw" ? "rd" : nil } == "rd")
        #expect(ExtensionOmnibox.keyword(manifest: Data(#"{"name": "x"}"#.utf8)) { _, _ in nil } == nil)
        #expect(ExtensionOmnibox.keyword(manifest: nil) { _, _ in nil } == nil)
    }

    @Test func chromiumKeywordIDsAreTheExtensions() {
        #expect(ExtensionOmnibox.chromiumID("chromium:" + id) == id)
        #expect(ExtensionOmnibox.chromiumID(id) == nil)
        #expect(ExtensionOmnibox.chromiumID("chromium:nope") == nil)
    }

    @Test func readsTheSuggestionsEvent() throws {
        let event = try #require(ExtensionOmnibox.chromiumSuggestions([
            "extensionId": .string(id), "requestId": .number(3),
            "suggestions": .array([.object(["content": .string("fx-one hi"), "description": .string("Fixture one <match>hi</match>")]),
                                   .object(["description": .string("no content")])])]))
        #expect(event.extensionID == id && event.request == 3)
        #expect(event.list.map(\.content) == ["fx-one hi"])
        #expect(ExtensionOmnibox.chromiumSuggestions(["extensionId": .string(id)]) == nil)
    }
}
