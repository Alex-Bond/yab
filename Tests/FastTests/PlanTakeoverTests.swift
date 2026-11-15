import Foundation
import Testing
@testable import Fast

// Feedback #118, "Any way to disable auto chatgpt take over": a chat never
// changes plan by itself. Only a new chat whose plan has no room starts on
// the other, and only one you connected in Yab, and it says so. A Claude
// Code login kept only in the keychain is signed in.
@MainActor
struct PlanTakeoverTests {
    private func settings() -> (UserDefaults, String) {
        let name = "dev.serafim.fast.test.takeover." + UUID().uuidString
        return (UserDefaults(suiteName: name)!, name)
    }

    private func ten() -> Date {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 10; parts.day = 13; parts.hour = 10
        return Calendar.current.date(from: parts)!
    }

    @Test func aNewChatMovesOnlyToAConnectedPlanWithRoom() {
        let everywhere = { (_: String) in true }
        let claudeOut = { (cli: String) in cli != "claude" }
        // Claude has room: it stays, whatever ChatGPT has.
        #expect(!Agents.startsOnOther("claude", room: everywhere, here: everywhere, connected: everywhere))
        // Claude out, ChatGPT connected with room: ChatGPT takes the new chat.
        #expect(Agents.startsOnOther("claude", room: claudeOut, here: everywhere, connected: everywhere))
        // A codex binary on disk is not a plan you connected in Yab.
        #expect(!Agents.startsOnOther("claude", room: claudeOut, here: everywhere, connected: { $0 == "claude" }))
        // Not on this Mac, or out too: it stays and is turned away in words.
        #expect(!Agents.startsOnOther("claude", room: claudeOut, here: { $0 == "claude" }, connected: everywhere))
        #expect(!Agents.startsOnOther("claude", room: { _ in false }, here: everywhere, connected: everywhere))
    }

    @Test func theChatSaysWhyAndWhenClaudeIsBack() {
        let now = ten()
        let back = now.addingTimeInterval(5 * 3600 + 40 * 60)
        #expect(Agents.handoverWords(from: "claude", to: "codex", signedOut: false, until: back, now: now)
                == "Claude is out of room, back 3:40 PM, so ChatGPT took this chat.")
        #expect(Agents.handoverWords(from: "claude", to: "codex", signedOut: false, until: nil, now: now)
                == "Claude is out of room, so ChatGPT took this chat.")
        #expect(Agents.handoverWords(from: "claude", to: "codex", signedOut: true, until: back, now: now)
                == "Claude isn\u{2019}t signed in, so ChatGPT took this chat.")
        // Partway through a chat it stays, and says so.
        #expect(Agents.outOfRoomWords("claude", until: back, otherReady: true, now: now)
                == "Claude is out of room, back 3:40 PM. A new chat can go on ChatGPT meanwhile.")
        #expect(Agents.outOfRoomWords("claude", until: nil, otherReady: false, now: now) == "Claude is out of room.")
    }

    @Test func roomAgainIsWhenTheSoonestAccountIsBack() {
        let (settings, name) = settings()
        defer { settings.removePersistentDomain(forName: name) }
        let accounts = PlanAccounts(settings: settings)
        let now = Date()
        #expect(accounts.roomAgain("claude", now: now) == nil)
        let resets = now.addingTimeInterval(2 * 3600)
        accounts.heard(claude: [
            "status": "rejected", "rateLimitType": "five_hour", "resetsAt": resets.timeIntervalSince1970,
            "unifiedWindows": ["five_hour": ["utilization": 1.0, "resetsAt": resets.timeIntervalSince1970]],
        ], on: "claude")
        #expect(!accounts.hasRoom("claude"))
        #expect(accounts.roomAgain("claude", now: now).map { abs($0.timeIntervalSince(resets)) < 1 } == true)
        #expect(!accounts.allSignedOut("claude"))
    }

    @Test func aKeychainOnlyClaudeLoginIsSignedIn() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("yab-keychain-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let env = ["CLAUDE_CONFIG_DIR": home.path]
        let service = PlanAccounts.keychainService(configDir: home.path)
        // No .claude.json account, no credentials file, no key: only the keychain says.
        #expect((await PlanAccounts.read("claude", env: env, keychain: { $0 == service })).signedIn)
        #expect(!(await PlanAccounts.read("claude", env: env, keychain: { _ in false })).signedIn)
        // The usual folder's item is Claude Code's plain name.
        #expect((await PlanAccounts.read("claude", env: [:], keychain: { $0 == "Claude Code-credentials" })).signedIn)
    }

    @Test func theKeychainServiceIsNamedAsClaudeCodeNamesIt() {
        #expect(PlanAccounts.keychainService(configDir: nil) == "Claude Code-credentials")
        #expect(PlanAccounts.keychainService(configDir: "") == "Claude Code-credentials")
        #expect(PlanAccounts.keychainService(configDir: "/Users/me/Library/Application Support/Yab/plans/claude.3fa9c1")
                == "Claude Code-credentials-8c3fdec9")
    }

    /// Asking the keychain never prompts and never throws: an item that
    /// surely isn't there is simply not there.
    @Test func askingTheKeychainForAMissingItemIsQuiet() async {
        #expect(!(await PlanAccounts.keychainPresence("Yab test-" + UUID().uuidString, read: PlanAccounts.inKeychain)))
    }

    /// Claude Code's get_usage says nothing at the weekly limit, so a new
    /// chat may start on Claude and be turned away on its first words: then
    /// it starts over on the other plan, as choose would have sent it. Once
    /// a step was taken, or a second message said, it stays and says so.
    @Test func aChatTurnedAwayBeforeAnythingRanStartsOver() {
        let asked = ChatItem(id: "a", kind: .asked, text: "can you sort my mail", state: .done)
        let refusal = ChatItem(id: "r", kind: .message,
                               text: "You've hit your weekly limit · resets 10pm (America/Los_Angeles)", state: .done)
        #expect(Agents.untouched([asked, refusal]))
        #expect(!Agents.untouched([asked, ChatItem(id: "t", kind: .tool, name: "tabs", state: .done), refusal]))
        #expect(!Agents.untouched([asked, ChatItem(id: "m", kind: .message, text: "Done.", state: .done),
                                   ChatItem(id: "b", kind: .asked, text: "and then?", state: .done), refusal]))
    }

    /// The plan's refusal said as the agent's words stands once, in the
    /// card, not again as a bubble over it.
    @Test func theRefusalIsNotSaidTwice() {
        let words = "You've hit your weekly limit · resets 10pm (America/Los_Angeles)"
        let refusal = ChatItem(id: "r", kind: .message, text: words, state: .done)
        #expect(!Chat.visibleMessage(refusal, failed: true, failure: words))
    }
}
