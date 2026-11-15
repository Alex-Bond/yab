import Foundation
import Testing
@testable import Fast

@MainActor
struct ProviderConsentTests {
    private func isolated(_ body: (ProviderConsent, UserDefaults) throws -> Void) rethrows {
        let domain = "consent-policy-" + UUID().uuidString
        let settings = UserDefaults(suiteName: domain)!
        defer { settings.removePersistentDomain(forName: domain) }
        try body(ProviderConsent(settings: settings, history: []), settings)
    }

    @Test func disconnectWinsOverHistoryAndAnOldQueuedLaunchEvenAfterReconnect() throws {
        try isolated { consent, settings in
            consent.grant("claude")
            let old = try #require(consent.permit("claude"))
            consent.revoke("claude")
            #expect(!consent.allows("claude"))
            consent.grant("claude")
            #expect(!old.valid)
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            #expect(try old.start(process) == false)
            #expect(!process.isRunning)
            consent.revoke("claude")
            #expect(!ProviderConsent(settings: settings, history: []).allows("claude"))
        }
    }

    @Test func completedManualQuietFieldChatCountsButAutomaticContextDoesNot() {
        let asked = ChatItem(id: "a", kind: .asked, text: "Explain these words", state: .done)
        let answer = ChatItem(id: "b", kind: .message, text: "An explanation.", state: .done)
        var chat = Chat(id: "fixture", title: "Explain", began: .field, cli: "claude", items: [asked, answer], state: "done", answer: "An explanation.", started: Date(), updated: Date())
        chat.providerBackground = true
        #expect(ProviderConsent.manualUse(chat))
        chat.knowing = true
        #expect(!ProviderConsent.manualUse(chat))
        chat.knowing = nil; chat.routine = "auto"
        #expect(!ProviderConsent.manualUse(chat))
        chat.routine = nil; chat.source = "agent"
        #expect(!ProviderConsent.manualUse(chat))
        chat.source = nil; chat.began = .other
        #expect(!ProviderConsent.manualUse(chat))
    }

    @Test func morningNeedsItsSpecificOptIn() {
        isolated { _, settings in
            settings.set(true, forKey: "bench"); settings.set(true, forKey: "agents.watch")
            #expect(!BackgroundConsent.canStartMorning(settings: settings))
            BackgroundConsent.enableMorning(settings: settings)
            #expect(BackgroundConsent.canStartMorning(settings: settings))
            BackgroundConsent.revokeMorning(settings: settings)
            #expect(!BackgroundConsent.canStartMorning(settings: settings))
        }
    }

    @Test func revokedMorningAndOldTurnNeverBorrowARegrant() throws {
        try isolated { consent, settings in
            consent.grant("claude")
            let provider = try #require(consent.permit("claude"))
            BackgroundConsent.enableMorning(settings: settings)
            let old = try #require(BackgroundConsent.permit(settings: settings))
            BackgroundConsent.revokeMorning(settings: settings)
            BackgroundConsent.enableMorning(settings: settings)
            #expect(!old.valid)
            #expect(BackgroundConsent.permit(settings: settings)?.valid == true)
            let turn = AgentTurnPermit()
            turn.revoke()
            #expect(!turn.valid && provider.valid)
        }
    }

    @Test func completedProducerCannotBorrowReconnectedAuthorityForAFollowup() throws {
        try isolated { consent, _ in
            consent.grant("claude")
            let turn = AgentTurnPermit()
            let producer = AgentAdmission(turn: turn, provider: try #require(consent.permit("claude")), external: false,
                background: nil, epoch: ContextPrivacy.shared.epoch, context: nil)
            turn.revoke()
            #expect(!producer.valid && producer.authorityValid)
            consent.revoke("claude"); consent.grant("claude")
            #expect(!producer.authorityValid)
        }
    }

    @Test func cancellingOneConnectTerminatesOnlyItsOwnRunningHelper() throws {
        try isolated { consent, _ in
            consent.grant("claude")
            func child() -> Process {
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/cat")
                process.environment = ["PATH": "/usr/bin:/bin"]
                process.standardInput = Pipe(); process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                return process
            }
            let manual = child(), connecting = child()
            defer { for process in [manual, connecting] where process.isRunning { process.terminate() }; consent.cancelConnections() }
            #expect(try #require(consent.permit("claude")).start(manual))
            consent.beginConnection("claude")
            let old = try #require(consent.connectionPermit("claude"))
            #expect(try old.start(connecting))
            consent.beginConnection("claude")
            connecting.waitUntilExit()
            #expect(!old.valid && !connecting.isRunning)
            #expect(manual.isRunning && consent.connectionPermit("claude")?.valid == true)
            consent.endConnection("claude", permit: old)
            #expect(consent.connectionPermit("claude")?.valid == true, "An old completion cannot cancel its replacement")
        }
    }

    @Test func quietAndResumedContextPromptsCannotBypassAllow() {
        let agents = Agents()
        agents.benchTask("fixture-ended", state: .done)
        for quiet in [true, false] {
            for resume in [nil, "fixture-ended"] as [String?] {
                let refused = agents.run(prompt: Agents.setUpMemoryPrompt, cli: "claude", quiet: quiet, resume: resume)
                #expect(refused.state == .failed && refused.result == ContextConsent.refusal)
                #expect(refused.process == nil)
            }
        }
    }

    @Test func scopedSessionsCanAdvertiseMCPWithoutAcquiringBroaderTools() throws {
        try isolated { consent, _ in
            consent.grant("claude")
            let session = Agents.Session(id: "caps-fixture", cli: "claude", name: "Fixture", prompt: "", state: .running)
            session.providerPermit = try #require(consent.permit("claude"))
            session.knowing = true
            session.contextGrant = ContextPrivacy.shared.begin()
            let lookup: (String) -> Agents.Session? = { $0 == session.id ? session : nil }
            @MainActor func preflight(_ verb: String) -> String? { ContextConsent.preflight(["session": session.id, "do": verb], lookup: lookup) }
            #expect(preflight("agent-caps") == nil)
            #expect(preflight("agent-history") == nil)
            #expect(preflight("agent-know-report") == nil)
            #expect(preflight("agent-act") != nil)
            session.quiet = true; session.contextGrant = ContextPrivacy.shared.derivation()
            #expect(preflight("agent-caps") == nil)
            #expect(preflight("agent-profile") == nil)
            #expect(preflight("agent-history") != nil && preflight("agent-know-report") != nil)
            session.memoryOnly = true
            #expect(preflight("agent-caps") == nil)
            #expect(preflight("agent-profile") != nil && preflight("open") != nil)
            consent.revoke("claude")
            #expect(preflight("agent-caps") != nil)
        }
    }

    @Test func contextNavigationRejectsPrivilegedURLs() {
        for raw in ["file:///tmp/private", "data:text/html,<script>1</script>", "about:blank", "yab://you", "javascript:1", "https://user:password@example.test/"] {
            #expect(!ContextConsent.webReadURL(raw))
        }
        #expect(ContextConsent.webReadURL("https://example.test/read"))
    }

    @Test func localSetupAllowsOnlyOneExactRegistrationAndNeverGrantsAI() throws {
        try isolated { consent, _ in
            let permit = LocalAgentSetupPermit.userSetupClaude(binary: "/usr/bin/true")
            defer { permit.revoke() }
            func process(_ args: [String]) -> Process {
                let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/true"); child.arguments = args
                return child
            }
            #expect(try !permit.start(process(["-p", "synthetic prompt"])))
            let args = try #require(AgentSetup.localClaudeSetupArguments.first)
            let registered = process(args)
            #expect(try permit.start(registered))
            registered.waitUntilExit()
            #expect(try !permit.start(process(args)), "Each exact argv is single-use")
            #expect(!consent.allows("claude"))
            let replacement = LocalAgentSetupPermit.userSetupClaude(binary: "/usr/bin/true")
            defer { replacement.revoke() }
            #expect(!permit.valid)
        }
    }

    @Test func mailAheadAndMorningHaveIndependentConsent() {
        isolated { _, settings in
            BackgroundConsent.enableMorning(settings: settings)
            #expect(!BackgroundConsent.canStartMailReply(settings: settings))
            settings.set(true, forKey: MailConsent.agentsKey)
            #expect(!BackgroundConsent.canStartMailReply(settings: settings))
            settings.set(true, forKey: MailConsent.aheadKey)
            BackgroundConsent.revokeMorning(settings: settings)
            #expect(BackgroundConsent.canStartMailReply(settings: settings))
            #expect(!BackgroundConsent.canStartMorning(settings: settings))
        }
    }
}
