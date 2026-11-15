import Foundation
import Testing
@testable import Fast

struct ModelChoiceTests {
    @Test @MainActor func aProviderOnlyChoiceNamesAndChecksItsDefault() throws {
        let choice = ModelChoice(cli: "claude")
        let first = try #require(AgentPlan.claude.models.first)
        #expect(ModelField.title(choice) == first.name)
        #expect(ModelField.isChosen(first, choice: choice))
        #expect(!ModelField.isChosen(AgentModels.claude[1], choice: choice))
        #expect(ModelField.title(ModelChoice()) == nil)
        #expect(!ModelField.isChosen(first, choice: ModelChoice()))
        #expect(ModelField.title(ModelChoice(cli: "mac")) == "Apple Intelligence")
        #expect(ModelField.title(ModelChoice(cli: "claude", model: "haiku")) == "Claude Haiku")
        #expect(ModelField.title(ModelChoice(cli: "claude", model: "unlisted")) == "Claude")
        #expect(!ModelField.isChosen(first, choice: ModelChoice(cli: "claude", model: "unlisted")))
    }

    @Test @MainActor func aGeminiProviderOnlyChoiceNamesAndChecksItsDefault() throws {
        let account = GeminiAccount.shared
        let old = (account.binary, account.signedIn, account.models.map(\.model).joined(separator: "\n"))
        defer { account.pretend(binary: old.0, signedIn: old.1, models: old.2) }
        account.pretend(binary: "/fixture/agy", signedIn: true, models: "gemini-3-pro\ngemini-3-flash")
        let first = try #require(account.models.first)
        let choice = ModelChoice(cli: "gemini")
        #expect(ModelField.title(choice) == first.name)
        #expect(ModelField.isChosen(first, choice: choice))
        #expect(!ModelField.isChosen(account.models[1], choice: choice))
    }

    @Test @MainActor func codexNamesReadAsRaycastWritesThem() {
        #expect(AgentModels.title("GPT-6-Astra") == "GPT-6 Astra")
        #expect(AgentModels.title("GPT-5.6-Sol") == "GPT-5.6 Sol")
        #expect(AgentModels.title("GPT-5.5") == "GPT-5.5")
    }

    @Test @MainActor func commandsSavedBeforeModelsStillLoad() throws {
        let old = #"[{"id":"x","name":"X","prompt":"{selection}","executor":"agent","enabled":true,"custom":true,"fieldsOnly":false,"pagesOnly":false,"site":"","applyImmediately":false,"shortcut":"","result":"auto","codeOnly":false}]"#
        let decoded = try JSONDecoder().decode([SelectionCommand].self, from: Data(old.utf8))
        #expect(decoded.first?.model == nil)
        #expect(decoded.first?.effort == nil)
    }

    @Test @MainActor func aCommandsOwnModelBeatsTheDefault() {
        let commands = SelectionCommands()
        var own = SelectionCommand(id: "own", name: "Own", prompt: "{selection}", executor: "codex")
        own.model = "gpt-6-luna"
        own.effort = "high"
        let pick = commands.agent(for: own)
        #expect(pick.cli == "codex")
        #expect(pick.model == "gpt-6-luna")
        #expect(pick.effort == "high")
    }

    @Test @MainActor func aCursorCommandsOwnModelBeatsAnotherPlansDefault() {
        let previous = ModelDefaults.shared[.commands]
        defer { ModelDefaults.shared[.commands] = previous }
        ModelDefaults.shared[.commands] = ModelChoice(cli: "claude", model: "haiku", effort: "low")
        let commands = SelectionCommands()
        var own = SelectionCommand(id: "cursor-own", name: "Cursor own", prompt: "{selection}", executor: "cursor")
        own.model = "composer-2.5"
        own.effort = "high"
        let pick = commands.agent(for: own)
        #expect(pick.cli == "cursor")
        #expect(pick.model == "composer-2.5")
        #expect(pick.effort == "high")
        // The configured Commands default remains another plan's: an
        // explicit command must keep its own provider even when unavailable.
        #expect(ModelDefaults.shared[.commands].cli == "claude")
        commands.command = own
        commands.stage = .running
        #expect(commands.hasAgent)
    }

    @Test @MainActor func aCursorAnswerOffersAnotherModelAndKeepsItsChoice() {
        let id = UUID(), browser = Browser(windowID: id)
        defer { try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json")) }
        browser.selectionCommands.command = SelectionCommand(id: "cursor-answer", name: "Cursor answer", prompt: "", executor: "cursor", model: "composer-2.5")
        browser.selectionCommands.snapshot = SelectionSnapshot(asking: nil)
        browser.selectionCommands.output = "A completed answer"
        browser.selectionCommands.stage = .preview
        let action = browser.answerActions.first { $0.id == "model" }
        #expect(action != nil)
        action?.run()
        #expect(browser.modelPicker?.title == "Answer Again On")
        #expect(browser.modelPicker?.choice.cli == "cursor")
        #expect(browser.modelPicker?.choice.model == "composer-2.5")
    }

    @Test func menuTitlesKeepANamesOwnCapitals() {
        #expect(SelectionCommand.menuTitle("Call with iPhone") == "Call with iPhone")
        #expect(SelectionCommand.menuTitle("fix spelling and grammar") == "Fix Spelling and Grammar")
    }

    @Test @MainActor func claudeModelsAreFoundByAlias() {
        #expect(AgentModels.find("claude", "haiku")?.name == "Claude Haiku")
        #expect(AgentModels.find("mac", nil)?.name == "Apple Intelligence")
        #expect(AgentModels.find(nil, nil) == nil)
        #expect(AgentModels.effortTitle("xhigh") == "Extra high")
    }
}
