import AppKit
import Testing
@testable import Fast

extension NativeAppleModelTests {
    @Suite(.serialized)
    @MainActor
    struct AppleModelControlTests {
        @Test func nativeMenuDisablesAndReenablesWithoutChangingOtherPreferences() async throws {
            _ = NSApplication.shared
            try #require(Store.testing && Store.world != nil)
            try #require(Store.settings !== UserDefaults.standard)
            let settings = Store.settings
            let keys = [AppleModelAccess.disabledKey, "selection.hint.shown", "mail.sense", "models.commands.cli"]
            let old = keys.map { settings.object(forKey: $0) }
            defer {
                for (key, value) in zip(keys, old) {
                    if let value { settings.set(value, forKey: key) }
                    else { settings.removeObject(forKey: key) }
                }
                NotificationCenter.default.post(name: AppleModelAccess.changed, object: nil)
            }
            settings.set(true, forKey: "selection.hint.shown")
            settings.set(false, forKey: "mail.sense")
            settings.set("codex", forKey: "models.commands.cli")
            AppleModelAccess.enabled = true
            let control = AppleModelControl()
            let commands = SelectionCommands()
            commands.hint = SelectionSnapshot(asking: nil)
            commands.stage = .running
            commands.output = "An explicit command keeps its result"
            commands.command = SelectionCommand(id: "owned", name: "Owned", prompt: "", executor: "agent")
            let menu = SettingsMenu.make(control.menuEntries())
            #expect(menu.items.map(\.title) == ["Disable in Yab"])
            menu.performActionForItem(at: 0)
            #expect(!control.enabled)
            #expect(!FormModel.ready)
            for _ in 0..<50 where commands.hint != nil { try await Task.sleep(for: .milliseconds(10)) }
            #expect(commands.hint == nil)
            #expect(commands.stage == .running)
            #expect(commands.output == "An explicit command keeps its result")
            #expect(commands.command?.executor == "agent")
            #expect(settings.bool(forKey: "selection.hint.shown"))
            #expect(!settings.bool(forKey: "mail.sense"))
            #expect(settings.string(forKey: "models.commands.cli") == "codex")
            let enabled = SettingsMenu.make(control.menuEntries())
            #expect(enabled.items.map(\.title) == ["Enable in Yab"])
            enabled.performActionForItem(at: 0)
            #expect(control.enabled)
            #expect(AppleModelAccess.enabled)
        }

        @Test func aConnectedPlanTurnsTheMacModelOffUntilEnabledByHand() throws {
            let suite = "apple-model-" + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            #expect(AppleModelAccess.enabled(in: defaults))
            defaults.set(["codex"], forKey: "agents.explicit-connections.v1")
            #expect(!AppleModelAccess.enabled(in: defaults))
            defaults.set(["codex"], forKey: "agents.revoked-connections.v1")
            #expect(AppleModelAccess.enabled(in: defaults))
            defaults.removeObject(forKey: "agents.revoked-connections.v1")
            AppleModelAccess.setEnabled(true, in: defaults)
            #expect(AppleModelAccess.enabled(in: defaults))
            AppleModelAccess.setEnabled(false, in: defaults)
            #expect(!AppleModelAccess.enabled(in: defaults))
            defaults.removeObject(forKey: "agents.explicit-connections.v1")
            #expect(!AppleModelAccess.enabled(in: defaults))
        }
    }
}
