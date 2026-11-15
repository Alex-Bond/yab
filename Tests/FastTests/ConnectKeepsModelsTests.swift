import Foundation
import Testing
@testable import Fast

/// The owner's report of 2026-10-30: connecting Gemini put Tasks, Chats and
/// Commands on Gemini. A connect never moves a default you chose, or one that
/// already runs on a connected plan. A new plan fills a default only when no
/// other plan is connected, and never one chosen by hand.
@Suite(.serialized)
@MainActor
struct ConnectKeepsModelsTests {
    private static let works: [ModelDefaults.Work] = [.tasks, .chats, .commands]
    private static let keys = ModelDefaults.Work.allCases.flatMap { work in
        ["cli", "model", "effort", "source"].map { "models.\(work.rawValue).\($0)" }
    } + ["models.chats.configured"]
    private static let consentKeys = ["agents.explicit-connections.v1", "agents.revoked-connections.v1", "agents.consent-migrated.v1"]
        + AgentPlan.clis.map { "agents.connection-generation." + $0 }
    private static let opus = ModelChoice(cli: "claude", model: "opus", effort: "high")

    /// Defaults never touched and no plan connected, Claude Code on this Mac.
    private func world(_ body: () throws -> Void) rethrows {
        let defaults = ModelDefaults.shared, consent = ProviderConsent.shared, account = GeminiAccount.shared
        let saved = Self.keys.map { Store.settings.object(forKey: $0) }
        let savedConsent = Self.consentKeys.map { Store.settings.object(forKey: $0) }
        let choices = ModelDefaults.Work.allCases.map { defaults[$0] }
        let old = (account.binary, account.signedIn, account.enabled, account.models.map(\.model).joined(separator: "\n"))
        let oldShell = Shell.cached
        let oldCursor = Store.settings.object(forKey: CursorRunner.connectionKey)
        defer {
            for cli in AgentPlan.clis { consent.revoke(cli) }
            for (key, value) in zip(Self.consentKeys, savedConsent) { Store.settings.set(value, forKey: key) }
            account.enabled = old.2
            account.pretend(binary: old.0, signedIn: old.1, models: old.3)
            Shell.cached = oldShell
            for (work, choice) in zip(ModelDefaults.Work.allCases, choices) { defaults[work] = choice }
            for (key, value) in zip(Self.keys, saved) { Store.settings.set(value, forKey: key) }
            Store.settings.set(oldCursor, forKey: CursorRunner.connectionKey)
        }
        for cli in AgentPlan.clis { consent.revoke(cli) }
        account.enabled = true
        account.pretend(binary: "/fixture/agy", signedIn: true, models: "gemini-3.8-flash-medium")
        Shell.cached = Shell.Found(claude: "/fixture/claude", codex: "/fixture/codex", cursor: "/fixture/cursor-agent", gemini: "/fixture/agy", env: [:])
        for work in ModelDefaults.Work.allCases { defaults[work] = ModelChoice() }
        for key in Self.keys { Store.settings.removeObject(forKey: key) }
        Store.settings.set(true, forKey: "models.chats.configured")
        try body()
    }

    /// What Connect does the moment a plan's sign-in lands.
    private func connect(_ cli: String) {
        if cli == "cursor" { Store.settings.set(true, forKey: CursorRunner.connectionKey) }
        ProviderConsent.shared.grant(cli)
        ModelDefaults.shared.useProvider(cli)
    }

    private func remove(_ cli: String) {
        if cli == "cursor" { Store.settings.set(false, forKey: CursorRunner.connectionKey) }
        ProviderConsent.shared.revoke(cli)
    }

    /// The report itself, for each plan connected beside each other plan.
    @Test func connectingAnotherPlanKeepsWhatYouChose() {
        for first in AgentPlan.clis {
            for second in AgentPlan.clis where second != first {
                world {
                    let defaults = ModelDefaults.shared
                    connect(first)
                    let chosen = ModelChoice(cli: first, model: "chosen-model", effort: "high")
                    for work in Self.works { defaults[work] = chosen }
                    connect(second)
                    for work in Self.works { #expect(defaults[work] == chosen, "\(second) beside \(first) moved \(work.rawValue)") }
                    #expect(ModelDefaults()[.chats] == chosen, "and it stays so after a restart")
                }
            }
        }
    }

    /// Defaults on Auto already run on the plan that is connected.
    @Test func connectingAnotherPlanLeavesAutoOnAuto() {
        world {
            let defaults = ModelDefaults.shared
            ProviderConsent.shared.grant("claude")
            connect("gemini")
            for work in Self.works { #expect(defaults[work].cli == nil) }
            #expect(defaults.pick(.chats).cli == "claude")
        }
    }

    /// A plan filled in by an earlier first connect is no more moved than
    /// one you chose: it is connected and it runs.
    @Test func aSecondConnectKeepsWhatTheFirstFilledIn() {
        world {
            let defaults = ModelDefaults.shared
            connect("claude")
            connect("gemini")
            for work in Self.works { #expect(defaults[work].cli == "claude") }
        }
    }

    @Test func theFirstConnectFillsOnlyWhatYouDidNotChoose() {
        for provider in AgentPlan.clis {
            world {
                let defaults = ModelDefaults.shared
                defaults[.commands] = Self.opus
                connect(provider)
                #expect(defaults[.chats].cli == provider)
                #expect(defaults[.tasks].cli == provider)
                #expect(defaults[.commands] == Self.opus)
            }
        }
    }

    /// Auto picked in the list is a choice like any other.
    @Test func autoChosenByHandStaysThroughTheFirstConnect() {
        world {
            let defaults = ModelDefaults.shared
            defaults[.chats] = ModelChoice(cli: nil, model: nil, effort: "low")
            defaults[.tasks] = ModelChoice()
            connect("gemini")
            #expect(defaults[.chats] == ModelChoice(cli: nil, model: nil, effort: "low"))
            #expect(defaults[.tasks] == ModelChoice())
            #expect(defaults[.commands].cli == "gemini")
        }
    }

    /// Yab from before this rule: a plan stored with no word on who put it
    /// there is taken as yours.
    @Test func aPlanStoredBeforeThisRuleCountsAsChosen() {
        world {
            for key in ["cli", "model"] {
                Store.settings.set(key == "cli" ? "claude" : "opus", forKey: "models.chats.\(key)")
            }
            let defaults = ModelDefaults()
            #expect(defaults[.chats].cli == "claude")
            let shared = ModelDefaults.shared
            shared[.chats] = ModelChoice(cli: "claude", model: "opus")
            Store.settings.removeObject(forKey: "models.chats.source")
            connect("gemini")
            #expect(shared[.chats] == ModelChoice(cli: "claude", model: "opus"))
        }
    }

    /// What the first connect filled in gives way when that plan was removed
    /// and another comes first.
    @Test func filledInDefaultsFollowTheNextFirstConnect() {
        world {
            let defaults = ModelDefaults.shared
            connect("gemini")
            remove("gemini")
            connect("claude")
            for work in Self.works { #expect(defaults[work].cli == "claude") }
        }
    }

    /// Reconnecting the plan of a choice: the choice is simply back, and
    /// the plan's own renewal moves nothing either.
    @Test func removingAndReconnectingBringsYourChoiceBack() {
        world {
            let defaults = ModelDefaults.shared
            connect("claude")
            for work in Self.works { defaults[work] = Self.opus }
            connect("gemini")
            remove("gemini")
            connect("gemini")
            for work in Self.works { #expect(defaults[work] == Self.opus) }
            // Claude out, Gemini alone: the choice is kept, Gemini does the work.
            remove("claude")
            #expect(defaults[.chats] == Self.opus)
            #expect(defaults.pick(.chats).cli == "gemini")
            #expect(defaults.pick(.tasks).cli == "gemini")
            // Claude back: there it is, with its model and effort.
            connect("claude")
            for work in Self.works {
                #expect(defaults[work] == Self.opus)
                #expect(defaults.pick(work).cli == "claude" && defaults.pick(work).model == "opus")
            }
        }
    }

    /// Signing the only plan in again is not a choice either.
    @Test func renewingTheOnlyPlanKeepsYourChoice() {
        world {
            let defaults = ModelDefaults.shared
            connect("claude")
            defaults[.chats] = Self.opus
            connect("claude")
            #expect(defaults[.chats] == Self.opus)
        }
    }

    /// With no plan connected at all, a choice still says what it says.
    @Test func nothingConnectedLeavesPickAsItWas() {
        world {
            let defaults = ModelDefaults.shared
            defaults[.chats] = Self.opus
            #expect(defaults.pick(.chats).cli == "claude" && defaults.pick(.chats).model == "opus")
        }
    }
}
