import AppKit
import Foundation
import Testing
@testable import Fast

@MainActor
@Suite(.serialized)
struct ExtensionToolbarTests {
    @Test func nativeTextButtonsAndCallbacksRouteInsideSettings() throws {
        _ = NSApplication.shared
        let model = SettingsModel()
        model.start(at: .extensions)
        var imported = 0
        let actions = ExtensionToolbar(add: { model.open(extension: "+add") }, bring: { imported += 1 })
        // Item construction and routing need no AppKit toolbar configuration.
        // The prepared-app probe checks actual insertion in Settings itself.
        let items = ExtensionToolbar.identifiers.compactMap { actions.item(for: $0) }
        #expect(items.map(\.itemIdentifier) == ExtensionToolbar.identifiers)
        #expect(actions.item(for: .flexibleSpace) == nil)
        for item in items {
            #expect(!(item is NSMenuToolbarItem))
            #expect(item.view == nil)
            #expect(item.image == nil)
            #expect(item.isBordered)
            #expect(item.title == (item.itemIdentifier == ExtensionToolbar.addID ? "Add" : "Import"))
            #expect(item.isEnabled)
        }
        let bring = try #require(items.first)
        #expect(NSApp.sendAction(try #require(bring.action), to: bring.target, from: bring))
        #expect(imported == 1)
        let add = try #require(items.last)
        #expect(NSApp.sendAction(try #require(add.action), to: add.target, from: add))
        #expect(model.page == .extensions)
        #expect(model.opened == "+add")
    }

    @Test func importIsAbsentOnceTheNativeProfileHasEveryEntry() {
        let entry = Installed(id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", name: "Fixture", version: "1", enabled: true, fromStore: true, permissions: [])
        #expect(ChromiumExtensions.importable([], installed: [], pending: []).isEmpty)
        #expect(ChromiumExtensions.importable([entry], installed: [], pending: []) == [entry])
        #expect(ChromiumExtensions.importable([entry], installed: [entry.id], pending: []).isEmpty)
        #expect(ChromiumExtensions.importable([entry], installed: [entry.id], pending: [entry.id]) == [entry])
    }

    @Test func chromiumLandingGoesStraightToDetailsAndBackSkipsAdding() async throws {
        let model = SettingsModel()
        model.start(at: .extensions)
        let adding = ExtensionAdding()
        let signIn = UUID()
        adding.target = Extensions(signIn: signIn)
        defer { try? FileManager.default.removeItem(at: Extensions.list(of: signIn)) }
        adding.chromium = ChromiumExtensions(profile: "toolbar-test", privateMode: false)
        for ids in [["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"], ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"]] {
            model.start(at: .extensions)
            model.open(extension: "+add")
            model.open(extension: "+add/review")
            await adding.land(ids, model)
            #expect(adding.phase == .idle)
            #expect(adding.landedNames.isEmpty)
            #expect(model.page == .extensions)
            #expect(model.opened == (ids.count == 1 ? ids[0] : nil))
            if ids.count == 1 {
                model.travel(-1)
                #expect(model.opened == nil)
                #expect(!model.canGoBack)
                model.travel(1)
                #expect(model.opened == ids[0])
            }
        }
    }
}
