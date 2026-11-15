import Foundation
import Testing
@testable import Fast

/// ⌘T over text selected on a page lists the selection's commands, the
/// enabled ones ⌘J would offer, and those the typed words name; ⌘L's field
/// stays the address's. Pin the agent path: Apple Intelligence can run
/// some built-in commands without an agent, and differs across farm Macs.
@Suite(.serialized)
struct FieldSelectionRowsTests {
    /// What an earlier suite may have left in the shared test settings:
    /// the Commands default (whose Auto falls to Gemini or Agents.preferred)
    /// and AI in Yab. Pinned here and put back in forget().
    @MainActor private static var saved: (commands: ModelChoice, aiUse: Any?, macDisabled: Any?, agent: Bool?)?

    @MainActor private func world() throws -> (Browser, UUID, SelectionSnapshot) {
        // Exercise the Commands agent on every host. Otherwise an available
        // Mac model still offers its commands with Agents.ready == false,
        // and an earlier suite can change the fallback agent or AI setting.
        Self.saved = (ModelDefaults.shared[.commands], Store.settings.object(forKey: AIUse.key),
                      Store.settings.object(forKey: AppleModelAccess.disabledKey), Agents.assumedInTests)
        Agents.assumedInTests = true
        Store.settings.set(true, forKey: AppleModelAccess.disabledKey)
        #expect(!FormModel.ready)
        ModelDefaults.shared[.commands] = ModelChoice(cli: "claude")
        Store.settings.set(AIUse.Level.on.rawValue, forKey: AIUse.key)
        let id = UUID()
        let browser = Browser(windowID: id)
        browser.selectionCommands.commands = SelectionCommand.builtIn
        let tab = browser.open(URL(string: "about:blank#checkout")!, foreground: true)
        let snap = try #require(SelectionSnapshot([
            "text": "We moved the plan picker ahead of the card form, so people choose what they pay for before they are asked how to pay.",
            "rect": ["x": 40.0, "y": 120.0, "width": 520.0, "height": 48.0],
        ], tab: tab))
        return (browser, id, snap)
    }

    @MainActor private func forget(_ id: UUID) {
        if let saved = Self.saved {
            Agents.assumedInTests = saved.agent
            Store.settings.set(saved.macDisabled, forKey: AppleModelAccess.disabledKey)
            ModelDefaults.shared[.commands] = saved.commands
            Store.settings.set(saved.aiUse, forKey: AIUse.key)
            Self.saved = nil
        }
        try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
    }

    private func commandIDs(_ rows: [Suggestion]) -> [String] {
        rows.compactMap { row in
            if case .page(let what) = row.kind, what.hasPrefix("sel:") { return String(what.dropFirst(4)) }
            return nil
        }
    }

    @MainActor @Test func newTabOverASelectionListsItsCommandsFirst() throws {
        let (browser, id, snap) = try world()
        defer { forget(id) }
        browser.newTab()
        browser.fieldSelection = snap
        let rows = browser.quietRows()
        // A paragraph of twenty-odd words: explained, translated, summed up,
        // as ⌘J's list orders them, four at most, and only enabled ones.
        #expect(commandIDs(rows) == ["explain", "translate", "summarize", "improve"],
                "commands \(ModelDefaults.shared.pickNow(.commands).cli), ready \(Agents.ready), mac \(FormModel.ready)")
        #expect(rows.first.flatMap { browser.quietSection($0) } == "Selection")
        #expect(rows.count <= 8 + browser.favoriteRows(now: Hints.now).count)
    }

    @MainActor @Test func typedWordsNameTheCommandAndReturnRunsIt() throws {
        let (browser, id, snap) = try world()
        defer { forget(id) }
        browser.newTab()
        browser.fieldSelection = snap
        browser.typed = "summ"
        #expect(commandIDs(browser.offers) == ["summarize"])
        #expect(commandIDs(Array(browser.offers.prefix(1))) == ["summarize"])
        #expect(browser.query.lead == 0)
        // Disabled commands are never offered, named or not.
        browser.typed = "short"
        #expect(commandIDs(browser.offers).isEmpty)
    }

    @MainActor @Test func noRunnerAvailableListsNoCommands() throws {
        let (browser, id, snap) = try world()
        defer { forget(id) }
        Agents.assumedInTests = false
        browser.newTab()
        browser.fieldSelection = snap
        #expect(commandIDs(browser.quietRows()).isEmpty)
        browser.typed = "summ"
        #expect(commandIDs(browser.offers).isEmpty)
    }

    @MainActor @Test func addressFieldAndNothingSelectedListNoCommands() throws {
        let (browser, id, snap) = try world()
        defer { forget(id) }
        // ⌘L: the address and the page, never the selection's commands.
        browser.edit()
        browser.fieldSelection = snap
        #expect(commandIDs(browser.quietRows()).isEmpty)
        browser.typed = "summ"
        #expect(commandIDs(browser.offers).isEmpty)
        browser.dismiss()
        // ⌘T with nothing selected.
        browser.newTab()
        #expect(browser.fieldSelection == nil)
        #expect(commandIDs(browser.quietRows()).isEmpty)
        browser.dismiss()
        // Split View's field asks for a page beside, not about the text.
        browser.openFresh(.split)
        browser.fieldSelection = snap
        #expect(commandIDs(browser.quietRows()).isEmpty)
    }
}
