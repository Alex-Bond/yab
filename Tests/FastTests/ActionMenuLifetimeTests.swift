import AppKit
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct ActionMenuLifetimeTests {
    @MainActor final class Target: NSObject {
        var calls: [String] = []
        @objc func run(_ sender: NSMenuItem) { calls.append(sender.title) }
    }

    private func fixture() -> (NSMenu, Target, ActionMenuList) {
        _ = NSApplication.shared
        let target = Target()
        let menu = NSMenu()
        menu.autoenablesItems = false
        for title in ["First", "Second"] {
            let item = NSMenuItem(title: title, action: #selector(Target.run(_:)), keyEquivalent: "")
            item.target = target
            menu.addItem(item)
        }
        return (menu, target, ActionMenuList(menu: menu, falls: true, compact: false))
    }

    @Test func removedRowsRemainSafeToRender() {
        let (menu, _, list) = fixture()
        let row = list.lines[1]
        menu.removeAllItems()
        #expect(row.detail == nil)
        #expect(row.context == nil)
        list.take(1)
    }

    @Test func reorderedRowPerformsItsOriginalCommand() {
        let (menu, target, list) = fixture()
        let first = menu.items[0]
        menu.removeItem(first)
        menu.addItem(first)
        list.take(0)
        #expect(target.calls == ["First"])
    }

    @Test func replacementAtSamePositionDoesNotRun() {
        let (menu, target, list) = fixture()
        menu.removeItem(at: 0)
        list.take(0)
        #expect(target.calls.isEmpty)
    }

    @Test func closingCanInvalidatePendingCommand() {
        let (menu, target, list) = fixture()
        list.close = { menu.removeAllItems() }
        list.take(0)
        #expect(target.calls.isEmpty)
    }

    @Test func closingCanDisablePendingCommand() {
        let (menu, target, list) = fixture()
        list.close = { menu.items[0].isEnabled = false }
        list.take(0)
        #expect(target.calls.isEmpty)
    }
}
