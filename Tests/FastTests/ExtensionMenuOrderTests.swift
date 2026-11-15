import AppKit
import Foundation
import Testing
@testable import Fast

@MainActor
struct ExtensionMenuOrderTests {
    private func installed(_ id: String, pinned: Bool? = nil, enabled: Bool = true) -> Installed {
        Installed(id: id, name: "Same name", version: "1", enabled: enabled, fromStore: false,
                  permissions: [], pinned: pinned)
    }

    private func row(_ title: String) -> NSMenuItem {
        NSMenuItem(title: title, action: nil, keyEquivalent: "")
    }

    private func permutations(_ ids: [String]) -> [[String]] {
        guard !ids.isEmpty else { return [[]] }
        return ids.flatMap { id in
            permutations(ids.filter { $0 != id }).map { [id] + $0 }
        }
    }

    @Test func everyLoadOrderUsesSavedPinAndInstallOrder() {
        let saved = [installed("older"), installed("pin-b", pinned: true),
                     installed("newer", pinned: false), installed("pin-a", pinned: true)]
        for order in permutations(saved.map(\.id)) {
            let contexts = Dictionary(uniqueKeysWithValues: order.map { ($0, $0) })
            var asked: [String] = []
            let items = Extensions.orderedMenuItems(installed: saved, contexts: contexts) { id in
                asked.append(id)
                return [row(id + "/first"), row(id + "/second")]
            }
            #expect(asked == ["pin-b", "pin-a", "older", "newer"])
            #expect(items.map(\.title) == ["pin-b/first", "pin-b/second", "pin-a/first", "pin-a/second",
                                          "older/first", "older/second", "newer/first", "newer/second"])
        }
    }

    @Test func savedListRoundTripKeepsReorderedPinsAndLegacyUnpinnedItems() throws {
        let saved = [installed("pin-c", pinned: true), installed("older"),
                     installed("pin-a", pinned: true), installed("newer")]
        let restored = try JSONDecoder().decode([Installed].self, from: JSONEncoder().encode(saved))
        #expect(restored == saved)
        for order in permutations(saved.map(\.id)) {
            let contexts = Dictionary(uniqueKeysWithValues: order.map { ($0, $0) })
            let items = Extensions.orderedMenuItems(installed: restored, contexts: contexts) { [row($0)] }
            #expect(items.map(\.title) == ["pin-c", "pin-a", "older", "newer"])
        }
        let unpinned = restored.filter { $0.pinned != true }
        let items = Extensions.orderedMenuItems(installed: unpinned, contexts: ["newer": "newer", "older": "older"]) { [row($0)] }
        #expect(items.map(\.title) == ["older", "newer"])
    }

    @Test func missingDisabledAndRemovedContextsDoNotDisturbRemainingItems() {
        let saved = [installed("missing", pinned: true), installed("disabled", pinned: true, enabled: false),
                     installed("empty", pinned: true), installed("present")]
        let first = row("Same title"), second = row("Same title")
        let target = NSObject(), submenu = NSMenu()
        first.target = target
        first.action = NSSelectorFromString("extensionAction:")
        first.representedObject = "context"
        first.submenu = submenu
        let separator = NSMenuItem.separator()
        let contexts: [String: [NSMenuItem]] = ["removed": [row("Removed")], "disabled": [row("Disabled")],
                                               "empty": [], "present": [first, separator, second]]
        let items = Extensions.orderedMenuItems(installed: saved, contexts: contexts) { $0 }
        #expect(items.count == 3)
        #expect(items[0] === first && items[1] === separator && items[2] === second)
        #expect(first.target === target && first.submenu === submenu)
        #expect(first.action == NSSelectorFromString("extensionAction:"))
        #expect(first.representedObject as? String == "context")
        #expect(Extensions.orderedMenuItems(installed: [], contexts: contexts) { $0 }.isEmpty)
        #expect(Extensions.orderedMenuItems(installed: saved, contexts: [String: [NSMenuItem]]()) { $0 }.isEmpty)
    }
}
