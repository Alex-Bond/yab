import AppKit
import Testing
@testable import Fast

/// Register 1340: adding a plain-paste command must not silently claim a
/// shortcut somebody already owns. All inputs are local values; this suite
/// never adopts stored app settings or touches the general pasteboard.
extension NativePasteStyleTests {
@MainActor
@Suite
struct PasteStyleShortcutTests {
    private var defaultKey: Hotkey { Hotkey("v", [.option, .shift, .command]) }
    private var oldPasteKey: Hotkey { Hotkey("v", [.shift, .command]) }
    private var remappedKey: Hotkey { Hotkey("p", [.control, .option, .command]) }

    /// The format saved before this command existed, including the absence
    /// of the optional `made` and `hinted` fields. Supplying both history
    /// and stored data keeps QuickActions ephemeral and off History.shared.
    private struct SavedActions: Encodable {
        let actions: [QuickAction]
        let personalized: Set<String> = []
        let dismissed: Set<String> = []
    }

    private func quickActions(_ actions: [QuickAction] = []) throws -> QuickActions {
        let data = try JSONEncoder().encode(SavedActions(actions: actions))
        return QuickActions(history: History([]), stored: data)
    }

    private func existingAction(key: Hotkey, enabled: Bool = true) -> QuickAction {
        QuickAction(id: "existing-paste-test", name: "Existing destination",
                    url: "https://example.invalid/existing", alias: "existing-paste-test",
                    shortcut: key.stored, enabled: enabled, custom: true)
    }

    private func keepsOldPasteKey(_ keys: [Shortcut.Action: Hotkey]) {
        #expect(keys[.pasteAndGo] == oldPasteKey)
        #expect(keys[.answerInsert] == oldPasteKey)
    }

    @Test func defaultsAddANewCommandWithoutChangingShiftCommandV() {
        let keys = Keymap.resolved(chosen: [:])
        #expect(Shortcut.byAction[.pasteAndMatchStyle]?.key == defaultKey)
        #expect(Shortcut.titles[.pasteAndMatchStyle] == "Paste and Match Style")
        #expect(keys[.pasteAndMatchStyle] == defaultKey)
        #expect(Shortcut.context(.pasteAndMatchStyle) == .browser)
        #expect(!Shortcut.first.contains(.pasteAndMatchStyle))
        // The existing ⇧⌘V remains browser-first; the new chord gives
        // registered extensions and page commands their existing turn.
        #expect(Shortcut.reservesPageKey(.pasteAndGo, readAs: oldPasteKey))
        #expect(!Shortcut.reservesPageKey(.pasteAndMatchStyle, readAs: defaultKey))
        keepsOldPasteKey(keys)
    }

    @Test func aSavedCustomActionKeepsTheNewDefaultAcrossContexts() throws {
        for owner in [Shortcut.Action.reload, .newTab, .fieldActions] {
            let data = try JSONEncoder().encode([owner.rawValue: defaultKey.stored])
            let chosen = try JSONDecoder().decode([String: String].self, from: data)
            let keys = Keymap.resolved(chosen: chosen)
            #expect(keys[owner] == defaultKey, "Existing \(owner.rawValue) keeps its saved key")
            #expect(keys[.pasteAndMatchStyle] == nil)
            #expect(chosen == [owner.rawValue: defaultKey.stored])
            keepsOldPasteKey(keys)
        }
    }

    @Test func newCommandCanBeReboundRemovedAndResetWithoutChangingOldPaste() {
        let action = Shortcut.Action.pasteAndMatchStyle
        let moved = Keymap.resolved(chosen: [action.rawValue: remappedKey.stored])
        #expect(moved[action] == remappedKey)
        #expect(!moved.values.contains(defaultKey))
        keepsOldPasteKey(moved)

        let removed = Keymap.resolved(chosen: [action.rawValue: ""])
        #expect(removed[action] == nil)
        #expect(!removed.values.contains(defaultKey))
        keepsOldPasteKey(removed)

        let reset = Keymap.resolved(chosen: [:])
        #expect(reset[action] == defaultKey)
        keepsOldPasteKey(reset)
    }

    @Test func appShortcutsKeepPriorityOverTheNewDefaultAndSavedBindings() {
        let existingSystem: [Shortcut.Action: Hotkey] = [.reload: defaultKey]
        let existing = Keymap.resolved(chosen: [:], system: existingSystem)
        #expect(existing[.reload] == defaultKey)
        #expect(existing[.pasteAndMatchStyle] == nil)
        #expect(Keymap.systemBrowserAction(for: defaultKey, owners: [defaultKey: .reload],
                                          current: existing, system: existingSystem) == .reload)
        keepsOldPasteKey(existing)

        let newSystem: [Shortcut.Action: Hotkey] = [.pasteAndMatchStyle: remappedKey]
        let explicitlyMapped = Keymap.resolved(chosen: [Shortcut.Action.pasteAndMatchStyle.rawValue: "",
                                                       Shortcut.Action.reload.rawValue: remappedKey.stored],
                                               system: newSystem)
        #expect(explicitlyMapped[.pasteAndMatchStyle] == remappedKey)
        #expect(explicitlyMapped[.reload] == nil)
        #expect(Keymap.systemBrowserAction(for: remappedKey, owners: [remappedKey: .pasteAndMatchStyle],
                                          current: explicitlyMapped, system: newSystem) == .pasteAndMatchStyle)
        keepsOldPasteKey(explicitlyMapped)
    }

    @Test func nativeMenuOwnershipIncludesSubmenusAndUppercaseShiftWithoutMutation() {
        let root = NSMenu(title: "Synthetic root")
        let parent = NSMenuItem(title: "Synthetic menu", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Synthetic menu")
        parent.submenu = submenu
        root.addItem(parent)
        let foreign = NSMenuItem(title: "Existing custom command", action: nil, keyEquivalent: "V")
        foreign.keyEquivalentModifierMask = [.option, .command]
        submenu.addItem(foreign)

        #expect(!PasteStyleMenuOrder.permits(defaultKey, in: root))
        #expect(PasteStyleMenuOrder.permits(remappedKey, in: root))
        #expect(foreign.keyEquivalent == "V")
        #expect(foreign.keyEquivalentModifierMask == [.option, .command])
        #expect(submenu.items.count == 1 && submenu.items.first === foreign)

        // An unrelated native Paste command is untouched, and our own row
        // does not incorrectly veto itself when its key is inspected.
        let menu = NSMenu(title: "Synthetic Edit")
        let paste = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        paste.keyEquivalentModifierMask = .command
        let own = NSMenuItem(title: PasteStyleMenuOrder.title, action: nil, keyEquivalent: "v")
        own.identifier = PasteStyleMenuOrder.identifier
        own.keyEquivalentModifierMask = defaultKey.flags
        menu.addItem(paste)
        menu.addItem(own)
        #expect(PasteStyleMenuOrder.permits(defaultKey, in: menu))
        #expect(paste.keyEquivalent == "v" && paste.keyEquivalentModifierMask == .command)
    }

    @Test func enabledSavedQuickActionOwnsTheNewDefaultWithoutLosingItsSavedKey() throws {
        let saved = existingAction(key: defaultKey)
        let actions = try quickActions([saved])
        try #require(actions.action(for: defaultKey)?.id == saved.id)
        #expect(Keymap.pasteStyleKey(defaultKey, chosen: [:], system: [:], quickActions: actions) == nil)
        #expect(actions.action(saved.id) == saved)
        #expect(actions.action(for: defaultKey)?.shortcut == defaultKey.stored)

        let disabled = existingAction(key: defaultKey, enabled: false)
        let disabledActions = try quickActions([disabled])
        #expect(disabledActions.action(for: defaultKey) == nil)
        #expect(Keymap.pasteStyleKey(defaultKey, chosen: [:], system: [:], quickActions: disabledActions) == defaultKey)
        #expect(disabledActions.action(disabled.id) == disabled)

        let unrelated = existingAction(key: remappedKey)
        let otherActions = try quickActions([unrelated])
        #expect(Keymap.pasteStyleKey(defaultKey, chosen: [:], system: [:], quickActions: otherActions) == defaultKey)
        #expect(otherActions.action(unrelated.id) == unrelated)
    }

    @Test func extensionOwnershipVetoesOnlyTheUnchosenNewDefault() throws {
        let actions = try quickActions()
        // These are the effective keys collected from enabled active and
        // sleeping extensions by Keymap.keys. No extension is installed or
        // woken here; the real collection/dispatch requires deferred QA.
        #expect(Keymap.pasteStyleKey(defaultKey, chosen: [:], system: [:],
                                    quickActions: actions, extensionKeys: [defaultKey]) == nil)
        #expect(Keymap.pasteStyleKey(defaultKey, chosen: [:], system: [:],
                                    quickActions: actions, extensionKeys: [remappedKey]) == defaultKey)
        #expect(Keymap.pasteStyleKey(defaultKey, chosen: [:], system: [:],
                                    quickActions: actions, extensionKeys: []) == defaultKey)
    }

    @Test func explicitChoicesUseTheExistingRecorderPolicyRatherThanTheNewDefaultVeto() throws {
        let actions = try quickActions([existingAction(key: remappedKey)])
        let chosen = [Shortcut.Action.pasteAndMatchStyle.rawValue: remappedKey.stored]
        let system: [Shortcut.Action: Hotkey] = [.pasteAndMatchStyle: remappedKey]
        #expect(Keymap.resolved(chosen: chosen)[.pasteAndMatchStyle] == remappedKey)
        #expect(Keymap.pasteStyleKey(remappedKey, chosen: chosen, system: [:],
                                    quickActions: actions, extensionKeys: [remappedKey]) == remappedKey)
        #expect(Keymap.resolved(chosen: [:], system: system)[.pasteAndMatchStyle] == remappedKey)
        #expect(Keymap.pasteStyleKey(remappedKey, chosen: [:], system: system,
                                    quickActions: actions, extensionKeys: [remappedKey]) == remappedKey)
        #expect(actions.action(for: remappedKey)?.shortcut == remappedKey.stored)
    }
}
}
