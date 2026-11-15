import Foundation
import Testing
@testable import Fast

/// ⌘T over text selected on a page lists the selection's commands, the
/// enabled ones ⌘J would offer, and those the typed words name; ⌘L's field
/// stays the address's. The commands go to an agent, and since d885455a
/// none is offered without one connected, so the world has one; the Macs
/// that run the tests may have no agent signed in.
struct FieldSelectionRowsTests {
    /// What an earlier suite may have left in the shared test settings:
    /// the Commands default (whose Auto falls to Gemini or Agents.preferred)
    /// and AI in Yab. Pinned here and put back in forget().
    @MainActor private static var saved: (commands: ModelChoice, aiUse: Any?)?

    @MainActor private func world() throws -> (Browser, UUID, SelectionSnapshot) {
        Agents.assumedInTests = true
        // On a Mac without Apple Intelligence (m4) these commands go to the
        // Commands default's agent, not this Mac's model, so the result
        // depended on whatever an earlier suite left there (0.44.0 QA: no
        // rows in the full batch, all four alone). The agent is Claude here.
        Self.saved = (ModelDefaults.shared[.commands], Store.settings.object(forKey: AIUse.key))
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
        Agents.assumedInTests = nil
        if let saved = Self.saved {
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

    @MainActor @Test func noAgentConnectedListsNoCommands() throws {
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
