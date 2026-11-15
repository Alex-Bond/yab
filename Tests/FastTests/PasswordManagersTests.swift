import Foundation
import Testing
@testable import Fast

@MainActor
@Suite(.serialized)
struct PasswordManagersTests {
    typealias M = PasswordManagers

    private func keeping(_ keys: [String], _ body: () throws -> Void) rethrows {
        let previous = keys.map { Store.settings.object(forKey: $0) }
        defer { for (key, value) in zip(keys, previous) { Store.settings.set(value, forKey: key) } }
        try body()
    }

    // Nothing changes until someone connects a manager: Yab fills and
    // saves, nobody else is asked.
    @Test func emptySettingsAreAsBefore() {
        keeping(["passwords.yab", M.Connections.key, M.Connections.lastKey]) {
            for key in ["passwords.yab", M.Connections.key, M.Connections.lastKey] { Store.settings.removeObject(forKey: key) }
            let prefs = Preferences()
            #expect(prefs.usesYabPasswords)
            #expect(M.Connections().list.isEmpty)
            let source = M.Source(yab: prefs.usesYabPasswords, saver: nil)
            #expect(source.yabSaves && source.yabFillsAlone)
            #expect(!M.Source(yab: true, saver: M.bitwarden).yabSaves)
            #expect(!M.Source(yab: false, saver: nil).yabSaves)
        }
    }

    @Test func strongboxOwnsFieldsWithoutPrivacyOptOut() {
        let id = "mnilpkfepdibngheginihjpknnopchbn"
        let unrelated = "test-unrelated-strongbox"
        keeping(["extensions.settings.\(id)", "extensions.settings.\(unrelated)"]) {
            for key in [id, unrelated] { Extensions.setSettings([:], for: key) }
            func extensionItem(_ id: String) -> Installed {
                Installed(id: id, name: "Strongbox AutoFill", version: "1.2.3", enabled: true,
                          fromStore: true, permissions: ["tabs", "nativeMessaging", "webNavigation", "storage", "favicon"])
            }
            let manager = extensionItem(id)
            #expect(M.isManager(manager))
            let source = M.Source(yab: true, saver: M.isManager(manager) ? manager.id : nil)
            #expect(!source.yabSaves)
            #expect(!source.yabFillsAlone)
            // A matching name and native-messaging permission do not take fields.
            #expect(!M.isManager(extensionItem(unrelated)))
            #expect(!M.yabMayUnlock(id))
        }
    }

    @Test func connectionsAreKeptInOrderOnThisMac() {
        keeping([M.Connections.key, M.Connections.lastKey]) {
            Store.settings.removeObject(forKey: M.Connections.key)
            let connections = M.Connections()
            #expect(connections.connect(M.bitwarden, mode: .you))
            #expect(connections.connect(M.onePasswordBeta, mode: .you))
            #expect(connections.connect(M.bitwarden, mode: .you))
            #expect(M.Connections().list.map(\.provider) == [M.bitwarden, M.onePassword])
            connections.unlocked(M.bitwarden, ok: false)
            #expect(M.Connections().failed == [M.bitwarden])
            connections.disconnect(M.bitwarden)
            #expect(M.Connections().list.map(\.provider) == [M.onePassword])
            #expect(M.Connections().failed.isEmpty)
            #expect(connections.described == "1Password (you unlock)")
        }
    }

    // Table 5, a row each.
    @Test func everyRowStateAndItsOneAction() {
        func row(installed: Bool = true, enabled: Bool = true, refused: Bool = false, mode: M.Mode = .yab,
                 kept: Bool = true, failed: Bool = false) -> M.Row {
            M.row(installed: installed, enabled: enabled, refused: refused, mode: mode, hasPassword: kept, lastFailed: failed)
        }
        #expect(row() == .yabUnlocks)
        #expect(row().words == "Connected · Yab unlocks it" && row().action == nil)
        #expect(row(mode: .you, kept: false) == .youUnlock)
        #expect(row(mode: .you).words == "Connected · You unlock it")
        #expect(row(installed: false) == .noExtension)
        #expect(M.Row.noExtension.words == "Its extension isn't in Yab" && M.Row.noExtension.action == "Add Extension")
        #expect(row(enabled: false) == .off)
        #expect(M.Row.off.words == "Its extension is off" && M.Row.off.action == "Turn On")
        #expect(row(refused: true) == .notAllowed)
        #expect(M.Row.notAllowed.words == "1Password hasn't allowed Yab yet. In 1Password: Settings › Browser › Add Browser.")
        #expect(M.Row.notAllowed.action == "Open 1Password")
        #expect(row(failed: true) == .wrongPassword)
        #expect(M.Row.wrongPassword.words == "The saved unlock password didn't work" && M.Row.wrongPassword.action == "Change…")
        #expect(row(kept: false) == .passwordMissing)
        #expect(M.Row.passwordMissing.words == "Its unlock password is missing on this Mac" && M.Row.passwordMissing.action == "Save Again…")
        // What a person must do first comes first.
        #expect(row(installed: false, enabled: false, refused: true, failed: true) == .noExtension)
        #expect(row(refused: true, failed: true) == .notAllowed)
        #expect(row(mode: .you, failed: true) == .youUnlock)
    }

    // Yab's login first (sign_in), then connected managers whose
    // extension is on, in the order connected; Apple Passwords never.
    @Test func agentTriesManagersInTheOrderConnected() {
        let list = [M.Connection(provider: M.onePassword, since: .now), M.Connection(provider: M.bitwarden, since: .now),
                    M.Connection(provider: M.nordPass, since: .now), M.Connection(provider: M.apple, since: .now)]
        #expect(M.agentOrder(list, on: [M.bitwarden, M.onePassword, M.apple]) == [M.onePassword, M.bitwarden])
        #expect(M.agentOrder(list, on: []).isEmpty)
        #expect(M.slug(M.protonPass) == "proton-pass" && M.slug(M.onePassword) == "1password")
        #expect(M.provider(M.onePasswordBeta)?.name == "1Password")
        #expect(M.providers.first { $0.id == M.nordPass }?.unlockPage == "app.html")
        #expect(M.providers.first { $0.id == M.dashlane }?.unlockPage == "index.html")
    }

    // Yab types an unlock password only into the unlock pages seen working
    // end to end: Bitwarden's and NordPass's.
    @Test func yabUnlocksOnlyCheckedManagers() {
        #expect(M.yabMayUnlock(M.bitwarden) && M.yabMayUnlock(M.nordPass))
        for id in [M.onePassword, M.onePasswordBeta, M.protonPass, M.dashlane, M.lastPass, M.apple, ManagerVault.keeper, ManagerVault.enpass] {
            #expect(!M.yabMayUnlock(id), "\(M.name(id))")
        }
    }

    // An unlock password goes in and comes back out the same, and is gone
    // after Forget.
    @Test func unlockPasswordKeychainRoundTrip() {
        let id = "test-manager-\(UUID().uuidString.prefix(8))"
        defer { ManagerUnlock.forget(id) }
        #expect(!ManagerUnlock.has(id))
        #expect(ManagerUnlock.save(id, "fixture unlock \"value\" ✓"))
        #expect(ManagerUnlock.has(id))
        #expect(ManagerUnlock.read(id) == "fixture unlock \"value\" ✓")
        #expect(ManagerUnlock.save(id, "second fixture"))
        #expect(ManagerUnlock.read(id) == "second fixture")
        ManagerUnlock.forget(id)
        #expect(ManagerUnlock.fetch(id) == .missing)
        #expect(!ManagerUnlock.save(id, ""))
    }

    // Only a real change of who fills or saves is told; an agent's
    // sign-ins in progress are kept through it.
    @Test func sourceChangesAreToldOnceAndKeepAgentSignIns() {
        keeping(["passwords.yab"]) {
            let id = UUID(), browser = Browser(windowID: id)
            defer {
                for tab in browser.tabs { tab.close() }
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            }
            browser.prefs.usesYabPasswords = true
            browser.passwordSourceMaybeChanged()
            let key = "test-session" + "signin:example.com"
            AgentFiles.shared.signIns[key] = ("person@example.com", Date())
            defer { AgentFiles.shared.signIns[key] = nil }
            #expect(!browser.passwordSourceMaybeChanged())
            browser.prefs.usesYabPasswords = false
            #expect(browser.passwordSourceMaybeChanged())
            #expect(!browser.passwordSourceMaybeChanged())
            #expect(AgentFiles.shared.signIns[key]?.user == "person@example.com")
            browser.prefs.usesYabPasswords = true
        }
    }

    @Test func unlockScriptsTakeThePasswordAsAnArgument() {
        #expect(ManagerUnlock.fillScript.contains("secret"))
        #expect(!ManagerUnlock.fillScript.contains("\\("))
        #expect(ManagerUnlock.boxScript.contains("input[type=password]"))
    }

    // Another browser's extension is found in the profiles its Local State
    // lists, and in Default when it lists none, without walking its folders.
    @Test func extensionsInOtherBrowsersAreFoundByLocalState() throws {
        let files = FileManager.default
        let top = files.temporaryDirectory.appendingPathComponent("pm-browsers-" + UUID().uuidString)
        defer { try? files.removeItem(at: top) }
        func source(_ name: String) -> Chromium.Source {
            Chromium.Source(name: name, folder: name, service: "", account: "", bundle: "test." + name,
                            dataRoot: top.appendingPathComponent(name))
        }
        let arc = top.appendingPathComponent("Arc")
        try files.createDirectory(at: arc.appendingPathComponent("Profile 3/Extensions/\(M.bitwarden)"), withIntermediateDirectories: true)
        let state = #"{"profile":{"info_cache":{"Default":{"name":"Personal"},"Profile 3":{"name":"Work"}}}}"#
        try Data(state.utf8).write(to: arc.appendingPathComponent("Local State"))
        let dia = top.appendingPathComponent("Dia")
        try files.createDirectory(at: dia.appendingPathComponent("Default/Extensions/\(M.onePassword)"), withIntermediateDirectories: true)
        try files.createDirectory(at: dia.appendingPathComponent("Default/Extensions/\(M.bitwarden)"), withIntermediateDirectories: true)
        let found = M.inBrowsers([M.bitwarden, M.onePassword, M.nordPass], in: [source("Arc"), source("Gone"), source("Dia")])
        #expect(found == [M.bitwarden: "Arc", M.onePassword: "Dia"])
    }
}
