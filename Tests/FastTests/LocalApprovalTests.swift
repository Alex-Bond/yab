import Foundation
import SyncKit
import Testing
@testable import Fast
@testable import SyncKit

/// A local agent's question goes to the person's other devices only when
/// it is a yes or no (or a sign-in's account) that needs nothing of this Mac, asked by a task
/// someone follows (AssistantApprovals, docs/approvals.md).
@MainActor struct LocalApprovalTests {
    private func permit(_ kind: AgentPermit.Kind, _ session: Agents.Session) -> AgentPermit {
        AgentPermit(kind: kind, session: session.id, detail: "")
    }

    @Test func aPayOrSendOfAnAttachedAgentGoesElsewhere() {
        let agents = Agents()
        let session = agents.attach(name: "claude-code")
        for kind: AgentPermit.Kind in [.press(label: "Pay", ref: "e1"), .sendMail(to: "ann@example.com", mail: "k"),
                                       .sendMessage(to: "Ann"), .upload(files: [], ref: "e2"), .use, .messages,
                                       .address(host: "example.com"), .saveSkill(name: "s", key: "k"),
                                       .signIn(host: "example.com", users: ["a", "b"])] {
            let asker = agents.asker(permit(kind, session))
            #expect(asker == .init(id: "local.external", name: session.planName, local: true), "\(kind)")
        }
    }

    @Test func whatNeedsThisMacStaysHere() {
        let agents = Agents()
        let session = agents.attach(name: "claude-code")
        for kind: AgentPermit.Kind in [.computer, .unlockManager(provider: "1password"),
                                       .native(label: "Add", operation: "op")] {
            #expect(agents.asker(permit(kind, session)) == nil, "\(kind)")
        }
    }

    @Test func nobodyFollowingOrASubagentAsksNobodyElsewhere() {
        let agents = Agents()
        let quiet = agents.attach(name: "claude-code")
        quiet.quiet = true
        #expect(agents.asker(permit(.press(label: "Pay", ref: "e1"), quiet)) == nil)
        let sub = agents.attach(name: "claude-code")
        sub.parent = agents.attach(name: "claude-code").id
        #expect(agents.asker(permit(.press(label: "Pay", ref: "e1"), sub)) == nil)
        #expect(agents.asker(AgentPermit(kind: .press(label: "Pay", ref: "e1"), session: "gone", detail: "")) == nil)
    }

    @Test func onUnlessTurnedOff() {
        let key = "agents.ask-elsewhere"
        let was = Store.settings.object(forKey: key)
        defer { Store.settings.set(was, forKey: key) }
        Store.settings.removeObject(forKey: key)
        #expect(Preferences().agentsAskElsewhere)
        Store.settings.set(false, forKey: key)
        #expect(!Preferences().agentsAskElsewhere)
    }
}

/// Version 2 of the sealed records: a sign-in's accounts to pick among,
/// and an answer proven on the device that gave it.
struct ApprovalChoiceTests {
    private func request(choices: [String]?) throws -> AssistantApprovalRecords.Request {
        try AssistantApprovalRecords.Request(
            id: "3f2c6f0e-2b1a-4c55-9a77-0d6c1b1e7a10", account: "account", mac: "mac", assistant: "local.external",
            session: "session", tab: "0b8f0c3e-5c55-4bd8-8f5e-3cb6f7a1e2d4", permit: "signin:example.com", title: "Claude: Sign in to example.com?",
            lines: ["example.com"], issued: Date(), expires: Date().addingTimeInterval(300), choices: choices)
    }

    @Test func aPlainQuestionReadsAsVersionOne() throws {
        // No choices: the same bytes, so the same digest, as before them.
        let plain = try request(choices: nil)
        let body = try #require(plain.fields()["body"]?.string)
        #expect(!body.contains("choices"))
        let answer = try AssistantApprovalRecords.Answer(request: plain, device: "phone", yes: true)
        #expect(answer.choice == nil && answer.proved == nil)
        #expect(throws: (any Error).self) {
            _ = try AssistantApprovalRecords.Answer(request: plain, device: "phone", yes: true, choice: "ann")
        }
    }

    @Test func aYesPicksOneOfItsChoices() throws {
        let signIn = try request(choices: ["ann@example.com", "bob@example.com"])
        let at = Date()
        let picked = try AssistantApprovalRecords.Answer(request: signIn, device: "phone", yes: true, at: at, choice: "bob@example.com", proved: true)
        #expect(picked.choice == "bob@example.com" && picked.proved == true)
        try picked.validate(request: signIn, now: at)
        for wrong in [nil, "eve@example.com"] as [String?] {
            #expect(throws: (any Error).self) {
                _ = try AssistantApprovalRecords.Answer(request: signIn, device: "phone", yes: true, at: at, choice: wrong)
            }
        }
        // A no picks nothing.
        _ = try AssistantApprovalRecords.Answer(request: signIn, device: "phone", yes: false, at: at)
        #expect(throws: (any Error).self) { _ = try request(choices: []) }
        #expect(throws: (any Error).self) { _ = try request(choices: ["a", "b", "c", "d"]) }
        #expect(throws: (any Error).self) { _ = try request(choices: ["a", "a"]) }
    }

    @Test func aVersionOneDeviceAnswersButDoesNotChoose() {
        func cap(_ version: Double) -> Record {
            Record(collection: OpenOnMac.capability, id: "phone", fields: [AssistantApprovalRecords.field: .number(version)],
                   stamps: [AssistantApprovalRecords.field: Stamp(wall: 1, device: "phone")])
        }
        #expect(AssistantApprovalRecords.answers(cap(1), device: "phone") && !AssistantApprovalRecords.chooses(cap(1), device: "phone"))
        #expect(AssistantApprovalRecords.answers(cap(2), device: "phone") && AssistantApprovalRecords.chooses(cap(2), device: "phone"))
        #expect(!AssistantApprovalRecords.answers(cap(2), device: "other"))
    }

    /// A manager that asked the person for the password itself (Apple
    /// Passwords' Touch ID) is the one question: Yab puts none, and the
    /// grace starts from it, so Yab's own fill a moment later isn't asked
    /// either. Forgotten (the Mac locked), the yes is gone again.
    @MainActor @Test func aManagersOwnTouchIDIsTheOnlyQuestion() {
        let was = Store.settings.object(forKey: Vault.proveKey)
        defer { Store.settings.set(was, forKey: Vault.proveKey); Vault.forgetProof(cancelling: false) }
        Store.settings.set(true, forKey: Vault.proveKey)
        Vault.forgetProof(cancelling: false)
        #expect(!Vault.yesStands)
        let before = Vault.questions
        var picked: Vault.Proven?
        Vault.proveToFill(on: "login.example.com", already: true) { picked = $0 }
        #expect(picked == .yes)
        #expect(Vault.asking == nil && Vault.questions == before)
        #expect(Vault.yesStands)
        var own: Vault.Proven?
        Vault.proveToFill(on: "other.example.org") { own = $0 }
        #expect(own == .yes)
        #expect(Vault.questions == before)
        Vault.forgetProof(cancelling: false)
        #expect(!Vault.yesStands)
    }

    /// Who is asked: a manager's yes counts only for a pick the person made;
    /// an agent's fill, Yab's own vault and a manager that asked nobody
    /// (Bitwarden opened with the saved password) still ask.
    @Test func whoIsStillAsked() {
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(!Vault.asks(agent: false, already: true, provenAt: nil, now: now))
        #expect(Vault.asks(agent: true, already: true, provenAt: nil, now: now))
        #expect(Vault.asks(agent: false, already: false, provenAt: nil, now: now))
        #expect(!Vault.asks(agent: false, already: false, provenAt: now - 299, now: now))
        #expect(Vault.asks(agent: false, already: false, provenAt: now - 301, now: now))
        #expect(Vault.asks(agent: true, already: false, provenAt: now - 10, now: now))
    }

    @MainActor @Test func aYesProvenElsewhereFillsOnceWithoutAsking() {
        let was = Store.settings.object(forKey: Vault.proveKey)
        defer { Store.settings.set(was, forKey: Vault.proveKey); Vault.provenElsewhere = nil }
        Store.settings.set(true, forKey: Vault.proveKey)
        Vault.provenElsewhere = (Vault.registrable("www.example.com"), Date())
        var got: Vault.Proven?
        Vault.proveToFill(on: "login.example.com", agent: true) { got = $0 }
        #expect(got == .yes)
        #expect(Vault.provenElsewhere == nil)
    }
}
