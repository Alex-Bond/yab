import AppKit
import Testing
@testable import Fast

// Keep the real key-router checks under the shared modal fixture's owner.
extension QuestionKeysTests {
    @MainActor @Suite(.serialized)
    struct FieldPlaceShortcutTests {
        private let additions: [FieldPlace] = [.clipboard, .emoji, .autofill, .chats, .routines, .store, .now, .purchases]

        @Test func everyStandaloneDestinationHasARecordableShortcut() throws {
            for place in FieldPlace.allCases where !place.names.isEmpty && place != .mail {
                let action = try #require(place.shortcut, "Missing shortcut for \(place)")
                #expect(Shortcut.byAction[action] != nil)
                #expect(Shortcut.context(action) == .browser)
                #expect(FieldPlace.opened(by: action) == place)
            }
            // These are entered with a page selection or a file request.
            for place in FieldPlace.allCases where place.names.isEmpty { #expect(place.shortcut == nil) }
            #expect(Shortcut.byAction[.mail] != nil, "Mail keeps its space toggle")
        }

        @Test func newDestinationsStartUnboundAndSavedKeysCanBeChangedRemovedAndReset() throws {
            let defaults = Keymap.resolved(chosen: [:])
            for place in additions {
                let action = try #require(place.shortcut)
                #expect(Shortcut.byAction[action]?.key == nil)
                #expect(defaults[action] == nil)
                for key in [Hotkey("v", [.control, .option, .command]), Hotkey("e", [.control, .option, .command])] {
                    let encoded = try JSONEncoder().encode([action.rawValue: key.stored])
                    let saved = try JSONDecoder().decode([String: String].self, from: encoded)
                    let resolved = Keymap.resolved(chosen: saved)
                    #expect(resolved[action] == key)
                    #expect(resolved[.pasteAndGo] == defaults[.pasteAndGo])
                    #expect(Keymap.mappedBrowserAction(for: key, owners: [key: action]) == action)
                    #expect(Shortcut.reservesPageKey(action, readAs: key))
                }
                #expect(Keymap.resolved(chosen: [action.rawValue: ""])[action] == nil)
                #expect(!Keymap.valid(Hotkey("e", []), for: action))
            }
            let key = Hotkey("r", .command)
            let replaced = Keymap.resolved(chosen: [Shortcut.Action.clipboard.rawValue: key.stored])
            #expect(replaced[.clipboard] == key && replaced[.reload] == nil)
            #expect(defaults[.reload] == key)
        }

        @Test func recordedKeysOpenAndTogglePlacesThroughTheWindowRouter() throws {
            _ = NSApplication.shared
            let map = Keymap.shared
            let system = Hotkeys.userKeys()
            let saved = map.chosen
            let browser = Browser(windowID: UUID())
            let suggest = browser.prefs.searchSuggest
            let requests = browser.prefs.fieldRequests
            browser.prefs.searchSuggest = false
            browser.prefs.fieldRequests = false
            map.take(system: [:])
            defer {
                for place in additions {
                    guard let action = place.shortcut else { continue }
                    if let value = saved[action.rawValue] { map.set(Hotkey(stored: value), for: action) }
                    else { map.reset(action) }
                }
                map.take(system: system)
                browser.dismiss()
                browser.letGo()
                browser.dozing?.invalidate()
                browser.stuck.timer?.invalidate()
                browser.pressure?.cancel()
                browser.prefs.searchSuggest = suggest
                browser.prefs.fieldRequests = requests
                if let id = browser.windowID {
                    try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
                }
            }
            for place in additions { map.reset(try #require(place.shortcut)) }
            browser.openFresh()
            let view = ContentView(browser: browser)
            let key = Hotkey("v", [.control, .option, .command])
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: key.flags,
                                                     timestamp: 0, windowNumber: 0, context: nil,
                                                     characters: "v", charactersIgnoringModifiers: "v",
                                                     isARepeat: false, keyCode: 9))
            for place in additions where place.offered {
                let action = try #require(place.shortcut)
                map.set(key, for: action)
                browser.openFresh()
                let entries = ShortcutFilter.catalog(groups: Shortcut.all, snippets: [])
                #expect(ShortcutFilter.visible(entries, search: place.title).contains { $0.action == action })
                browser.replaceTyped(place.names[0])
                let row = try #require(browser.offers.first)
                #expect(row.kind == .place(place))
                #expect(browser.fieldActions.first?.shownKeys == key.text)
                #expect(view.take(event))
                #expect(browser.query.place == place)
                #expect(view.take(event))
                #expect(browser.query.place == nil)
                map.reset(action)
            }
            if !FieldPlace.purchases.offered {
                #expect(!browser.openPlace(shortcut: .purchases))
                #expect(browser.query.place == nil)
            }
        }
    }
}
