import AppKit
import Testing
@testable import Fast

@MainActor
struct ExtensionContextMenuTests {
    private func row(_ id: String, title: String = "Same title", action: String = "first:") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: NSSelectorFromString(action), keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier(id)
        return item
    }

    @Test func attachedOwnerKeepsNativeRowsAndNeverBuildsTheSecondSet() {
        let owner = NSObject(), target = NSObject(), menu = NSMenu()
        let first = row("extension-a/action-one"), second = row("extension-b/action-two", action: "second:")
        first.target = target
        first.representedObject = "native context"
        let submenu = NSMenu()
        let child = row("extension-a/child")
        submenu.addItem(child)
        first.submenu = submenu
        let separator = NSMenuItem.separator()
        menu.addItem(first); menu.addItem(separator); menu.addItem(second)
        var calls = 0
        PageExtensionMenus.append(to: menu, nativeController: owner, owner: owner) {
            calls += 1
            return [row("extension-a/action-one")]
        }
        #expect(calls == 0)
        #expect(menu.items.count == 3)
        #expect(menu.items[0] === first && menu.items[1] === separator && menu.items[2] === second)
        #expect(first.target === target)
        #expect(first.representedObject as? String == "native context")
        #expect(first.submenu === submenu && submenu.items[0] === child)
        #expect(second.action == NSSelectorFromString("second:"))
    }

    @Test func unattachedFallbackPreservesDistinctActionsAndExtensionsWithIdenticalTitles() {
        let menu = NSMenu(), owner = NSObject()
        let normal = row("browser/action"), first = row("extension-a/action-one")
        let second = row("extension-a/action-two", action: "second:")
        let other = row("extension-b/action-one")
        menu.addItem(normal)
        PageExtensionMenus.append(to: menu, nativeController: nil, owner: owner) { [first, second, other] }
        #expect(menu.items.count == 5 && menu.items[1].isSeparatorItem)
        #expect(menu.items[0] === normal && menu.items[2] === first && menu.items[3] === second && menu.items[4] === other)
        #expect(second.action == NSSelectorFromString("second:"))
    }

    @Test func anotherControllerStillUsesFallbackAndEmptyFallbackAddsNoSeparator() {
        let menu = NSMenu(), owner = NSObject(), other = NSObject()
        let native = row("native/other-owner"), fallback = row("fallback/this-owner")
        menu.addItem(native)
        PageExtensionMenus.append(to: menu, nativeController: other, owner: owner) { [fallback] }
        #expect(menu.items.count == 3 && menu.items[0] === native && menu.items[2] === fallback)
        let empty = NSMenu()
        PageExtensionMenus.append(to: empty, nativeController: nil, owner: owner) { [] }
        #expect(empty.items.isEmpty)
    }

    @Test func newMenuGenerationUsesItsOwnControllerAndCurrentRows() {
        let firstOwner = NSObject(), nextOwner = NSObject()
        let first = NSMenu(), next = NSMenu()
        let oldRow = row("generation-one"), current = row("generation-two")
        first.addItem(oldRow); next.addItem(current)
        var calls = 0
        PageExtensionMenus.append(to: first, nativeController: firstOwner, owner: firstOwner) { calls += 1; return [] }
        PageExtensionMenus.append(to: next, nativeController: nextOwner, owner: nextOwner) { calls += 1; return [] }
        #expect(calls == 0)
        #expect(first.items.count == 1 && first.items[0] === oldRow)
        #expect(next.items.count == 1 && next.items[0] === current)
    }
}
