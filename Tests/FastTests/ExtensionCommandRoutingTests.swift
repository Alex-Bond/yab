import AppKit
import Testing
import WebKit
@testable import Fast

@MainActor
@Suite(.serialized)
struct ExtensionCommandRoutingTests {
    @MainActor
    private final class Answers: NSObject, WKWebExtensionControllerDelegate {
        weak var owner: Extensions?
        var heard: [String] = []

        func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any,
                                    toApplicationWithIdentifier applicationIdentifier: String?,
                                    for extensionContext: WKWebExtensionContext) async throws -> Any? {
            if applicationIdentifier == "shortcut-test", let text = message as? String {
                heard.append(text)
                return true
            }
            return try await owner?.webExtensionController(controller, sendMessage: message,
                toApplicationWithIdentifier: applicationIdentifier, for: extensionContext)
        }
    }

    @MainActor
    private final class Fixture {
        let space = UUID()
        let id = "shortcut" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("extension-commands-\(UUID())")
        let browser: Browser
        let owner: Extensions
        let answers = Answers()
        let savedShortcuts: Any?
        let savedSystem: [String: String]
        let savedTaken: String

        init() throws {
            try #require(Store.testing)
            _ = NSApplication.shared
            savedShortcuts = Store.settings.object(forKey: "shortcuts")
            savedSystem = Hotkeys.userKeys()
            savedTaken = Extensions.lastTaken
            browser = Browser(windowID: UUID())
            owner = Extensions.of(space: space)
            browser.spaceID = space
            _ = browser.open(URL(string: "about:blank")!, foreground: true, rowNow: true)
            browser.editing = false
            owner.browser = browser
            owner.follow(browser)
            answers.owner = owner
            owner.controller.delegate = answers
            Keymap.shared.take(system: [:])
            Store.settings.set([String: String](), forKey: "shortcuts")
            Keymap.shared.adoptStored()
        }

        func load(version: Int = 3, suggested: String = "Ctrl+Shift+S") async throws -> WKWebExtensionContext {
            let action = version == 2 ? "browser_action" : "action"
            let command = version == 2 ? "_execute_browser_action" : "_execute_action"
            let staged = root.appendingPathComponent("staged")
            let background: [String: Any] = version == 2 ? ["scripts": ["worker.js"]] : ["service_worker": "worker.js"]
            try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: Extensions.folder, withIntermediateDirectories: true)
            let manifest: [String: Any] = [
                "manifest_version": version, "name": "Command routing fixture", "version": "1.0",
                "permissions": ["nativeMessaging", "activeTab"], action: [:],
                "background": background,
                "commands": [command: ["suggested_key": ["default": suggested]],
                             "save_page": ["description": "Save page"]]
            ]
            try JSONSerialization.data(withJSONObject: manifest).write(to: staged.appendingPathComponent("manifest.json"))
            try """
            const report = text => chrome.runtime.sendNativeMessage('shortcut-test', text);
            chrome.commands.onCommand.addListener(name => report('command:' + name));
            (chrome.action || chrome.browserAction).onClicked.addListener(() => report('action'));
            report('ready');
            """.write(to: staged.appendingPathComponent("worker.js"), atomically: true, encoding: .utf8)
            let loaded = try await owner.admit(staged, as: id, fromStore: false,
                finalFolder: Extensions.folder(for: id), confirm: false, quiet: true)
            try #require(loaded)
            let context = try #require(owner.contexts[id])
            try #require(try await Loaded.until(10) { self.answers.heard.contains("ready") })
            try #require(try await Loaded.until(5) { self.owner.activeAdapter != nil })
            owner.controller.didFocusWindow(try #require(owner.window))
            return context
        }

        func close() {
            owner.remove(id)
            owner.controller.delegate = owner
            owner.shutDown()
            browser.tabs.forEach { $0.close() }
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            Spaces.erase(space)
            Session.erase(space: space)
            try? FileManager.default.removeItem(at: root)
            if let savedShortcuts { Store.settings.set(savedShortcuts, forKey: "shortcuts") }
            else { Store.settings.removeObject(forKey: "shortcuts") }
            Keymap.shared.adoptStored()
            Keymap.shared.take(system: savedSystem)
            Extensions.lastTaken = savedTaken
        }

        func event(_ key: String = "s", code: UInt16 = 1, flags: NSEvent.ModifierFlags = [.shift, .command],
                   type: NSEvent.EventType = .keyDown) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil, characters: key,
                charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
        }

        func assign(_ key: Hotkey, command: String) throws {
            let own = try #require(owner.contexts[id]?.commands.first { $0.id == command })
            switch Keymap.shared.clash(key, for: nil, command: own) {
            case .taken(_, let free): free()
            case .refused(let words): try #require(false, "Unexpected refusal: \(words)")
            case nil: break
            }
            owner.setKey(key, extension: id, command: command)
        }

        func expect(_ text: String) async throws {
            try #require(try await Loaded.until(10) { self.answers.heard.contains(text) })
            #expect(answers.heard.filter { $0 == text }.count == 1)
        }
    }

    @Test func browserOwnershipMatchesTheExistingSettingsClash() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let context = try await fixture.load()
        let key = Hotkey("s", [.shift, .command])
        let command = try #require(context.commands.first { $0.id == "_execute_action" })
        #expect(Keymap.shared.action(for: key) == .sidebarTabs)
        #expect(command.activationKey == nil)
        #expect(fixture.owner.buttons.first { $0.id == fixture.id }?.keys == nil)
        #expect(fixture.owner.commandGroups().first?.commands.first { $0.command == command.id }?.keys == nil)
        #expect(fixture.owner.tipFacts[fixture.id]?.keys.isEmpty == true)
        guard case .taken(let words, _) = Keymap.shared.clash(key, for: nil, command: command) else {
            Issue.record("The existing extension recorder must identify Yab's owner")
            return
        }
        #expect(words.contains("Tabs in a sidebar"))
        #expect(!fixture.owner.take(try fixture.event()))
        #expect(fixture.answers.heard == ["ready"])
        try fixture.assign(key, command: command.id)
        #expect(Keymap.shared.action(for: key) == nil)
        #expect(fixture.owner.buttons.first { $0.id == fixture.id }?.keys == key.text)
        #expect(fixture.owner.take(try fixture.event()))
        try await fixture.expect("action")
        #expect(!fixture.answers.heard.contains { $0.hasPrefix("command:") })
    }

    @Test(arguments: [2, 3])
    func rejectedSuggestionsStayUnassignedUntilTheUserRecordsAKey(version: Int) async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let context = try await fixture.load(version: version)
        let id = version == 2 ? "_execute_browser_action" : "_execute_action"
        let command = try #require(context.commands.first { $0.id == id })
        let saved = Store.settings.dictionary(forKey: "extensions.keys.\(fixture.id)")
        #expect((saved?[id] as? [String: Any])?["key"] as? String == "")
        // Neither another manifest read nor freeing Yab's key assigns it.
        Keymap.shared.set(nil, for: .sidebarTabs)
        fixture.owner.refreshTipFacts(fixture.id)
        #expect(fixture.owner.tipFacts[fixture.id]?.keys.isEmpty == true)
        #expect(command.activationKey == nil)
        #expect(!fixture.owner.take(try fixture.event()))
        try fixture.assign(Hotkey("s", [.shift, .command]), command: id)
        #expect(fixture.owner.take(try fixture.event()))
        try await fixture.expect("action")
    }

    @Test func aFreeSuggestionIsAssignedAndASystemOwnerHidesItsTip() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        // Use a valid manifest suggestion. WebKit drops the action command
        // for the old three-modifier MacCtrl+Alt+Command default.
        let context = try await fixture.load(suggested: "Ctrl+Shift+Y")
        let key = Hotkey("y", [.shift, .command])
        let command = try #require(context.commands.first { $0.id == "_execute_action" })
        #expect(fixture.owner.routedKey(command) == key)
        #expect(fixture.owner.buttons.first { $0.id == fixture.id }?.keys == key.text)
        Keymap.shared.take(system: ["Reload Page": "@$y"])
        #expect(fixture.owner.routedKey(command) == nil)
        #expect(fixture.owner.buttons.first { $0.id == fixture.id }?.keys == nil)
        #expect(!fixture.owner.take(try fixture.event("y", code: 16, flags: key.flags)))
        // The user's assignment is retained while App Shortcuts owns it.
        Keymap.shared.take(system: [:])
        #expect(fixture.owner.routedKey(command) == key)
        #expect(fixture.owner.take(try fixture.event("y", code: 16, flags: key.flags)))
        try await fixture.expect("action")
    }

    @Test(arguments: [2, 3])
    func actionShortcutsUseTheButtonRoute(version: Int) async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        _ = try await fixture.load(version: version)
        let command = version == 2 ? "_execute_browser_action" : "_execute_action"
        try fixture.assign(Hotkey("s", [.shift, .command]), command: command)
        #expect(ContentView(browser: fixture.browser).take(try fixture.event()))
        try await fixture.expect("action")
        #expect(Extensions.lastTaken == fixture.id + "/" + command)
        #expect(!fixture.answers.heard.contains { $0.hasPrefix("command:") })
    }

    @Test func keptCommandKeyDeliversOnCommandAndHonorsOffAndRemoval() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let context = try await fixture.load()
        let key = Hotkey("y", [.control, .option, .command])
        try fixture.assign(key, command: "save_page")
        let event = try fixture.event("y", code: 16, flags: key.flags)
        #expect(fixture.owner.commandGroups().first?.commands.first { $0.command == "save_page" }?.keys == key)
        #expect(!fixture.owner.take(try fixture.event("y", code: 16, flags: key.flags, type: .keyUp)))
        let tab = try #require(fixture.owner.activeAdapter)
        #expect(!context.hasActiveUserGesture(in: tab))
        #expect(ContentView(browser: fixture.browser).take(event))
        #expect(context.hasActiveUserGesture(in: tab))
        try await fixture.expect("command:save_page")
        #expect(Extensions.lastTaken == fixture.id + "/save_page")
        fixture.owner.setCommand(.init(off: true), extension: fixture.id, command: "save_page")
        #expect(!fixture.owner.take(event))
        fixture.owner.setCommand(.init(), extension: fixture.id, command: "save_page")
        fixture.owner.setKey(nil, extension: fixture.id, command: "save_page")
        #expect(!fixture.owner.take(event))
        #expect(fixture.answers.heard.filter { $0 == "command:save_page" }.count == 1)
    }

    @Test func appShortcutsKeepTheirKeyWithoutErasingTheExtensionBinding() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        _ = try await fixture.load()
        let key = Hotkey("y", [.control, .option, .command])
        try fixture.assign(key, command: "save_page")
        Keymap.shared.take(system: ["Reload Page": "@~^y"])
        #expect(Keymap.shared.systemBrowserAction(for: key) == .reload)
        let event = try fixture.event("y", code: 16, flags: key.flags)
        #expect(!fixture.owner.take(event))
        #expect(fixture.owner.commandGroups().first?.commands.first { $0.command == "save_page" }?.keys == key)
        Keymap.shared.take(system: [:])
        #expect(fixture.owner.take(event))
        try await fixture.expect("command:save_page")
    }
}
