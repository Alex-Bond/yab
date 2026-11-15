import AppKit
import Foundation
import Testing
@testable import Fast

@MainActor
@Suite(.serialized)
struct ChatProjectPresentationTests {
    private func world(_ body: (Browser, Projects, Chats) throws -> Void) async rethrows {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("project-ui-" + UUID().uuidString)
        let projects = Projects(folder: root.appendingPathComponent("projects"))
        let chats = Chats(folder: root.appendingPathComponent("chats"), projects: projects)
        let browser = Browser(windowID: UUID())
        browser.chatProjects = projects
        browser.chatOpen = true
        let tab = Tab(bench: true)
        tab.restore(url: URL(string: "https://project-search.example.test/")!, title: "Projects")
        browser.lay([tab])
        browser.activeID = tab.id
        let suggestions = browser.prefs.searchSuggest
        let requests = browser.prefs.fieldRequests
        let enabled = browser.prefs.menuCommands
        let setting = Store.settings.object(forKey: MenuCommands.key)
        let under = FieldUnder.shared.commands
        browser.prefs.searchSuggest = false
        browser.prefs.fieldRequests = false
        browser.prefs.menuCommands = true
        FieldUnder.shared.commands = true
        defer {
            browser.dismiss()
            browser.letGo()
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            browser.prefs.searchSuggest = suggestions
            browser.prefs.fieldRequests = requests
            browser.prefs.menuCommands = enabled
            Store.settings.set(setting, forKey: MenuCommands.key)
            FieldUnder.shared.commands = under
            if let id = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            }
        }
        try body(browser, projects, chats)
        await projects.flush()
        await chats.flush()
        try? FileManager.default.removeItem(at: root)
    }

    @Test func projectNamesLeadComposedHistoryAndWebAndAppearInActions() async throws {
        try await world { browser, projects, chats in
            let project = projects.add(name: "Lisbon Research", in: chats)
            let destination = "openChatProject:" + project.id
            let url = URL(string: "https://lisbon.example.test/research")!
            browser.history = History([Visit(url: url.absoluteString, key: Address.pretty(url),
                title: "Lisbon Research", count: 200, last: Date(), typed: 100)])
            for words in ["lis", "Lisbon Research", "Open Project Lisbon Research"] {
                browser.replaceTyped(words)
                #expect(browser.ending == nil)
                #expect(browser.offers.first?.menuTargetID == destination, "\(words)")
                #expect(browser.query.lead == 0)
                let web = Suggestion(key: words + " flights", title: "", url: nil, kind: .suggested)
                let merged = SearchSuggestions.merge([web], into: browser.offers, lead: browser.query.lead)
                #expect(merged.list.first?.menuTargetID == destination)
                #expect(merged.lead == 0)
                #expect(browser.fieldActions.contains { $0.title == "Ask in Project" })
            }
            browser.prefs.menuCommands = false
            browser.replaceTyped("Lisbon Research")
            #expect(browser.offers.first?.menuTargetID == destination)
            browser.query.actionsPage = true
            browser.replaceTyped("Lisbon Research")
            #expect(browser.offers.contains { $0.menuTargetID == destination })
        }
    }

    @Test func projectActionsTrackPinMemoryArchiveAndRemappedKeys() async throws {
        try await world { browser, projects, chats in
            let project = projects.add(name: "Project commands", in: chats)
            browser.chatHistory = true
            browser.chatProject = project.id
            for pinned in [false, true] {
                projects.pin(project.id, pinned)
                #expect(Command.pinChatProject.available(in: browser) == !pinned)
                #expect(Command.unpinChatProject.available(in: browser) == pinned)
                let command: Command = pinned ? .unpinChatProject : .pinChatProject
                browser.replaceTyped(command.title)
                #expect(browser.offers.first?.kind == .command(command))
                let web = Suggestion(key: command.title + " app", title: "", url: nil, kind: .suggested)
                #expect(SearchSuggestions.merge([web], into: browser.offers, lead: browser.query.lead).list.first?.kind == .command(command))
            }
            for on in [false, true] {
                var next = try #require(projects.project(project.id))
                next.memoryOn = on
                projects.update(next)
                let command: Command = on ? .disableProjectMemory : .enableProjectMemory
                #expect(command.available(in: browser))
                browser.replaceTyped(command.title)
                #expect(browser.offers.first?.kind == .command(command))
                command.run(in: browser)
                #expect(projects.project(project.id)?.memoryOn == !on)
            }
            #expect(Command.archiveChatProject.available(in: browser))
            #expect(!Command.unarchiveChatProject.available(in: browser))
            projects.archive(project.id, true)
            #expect(!Command.archiveChatProject.available(in: browser))
            #expect(Command.unarchiveChatProject.available(in: browser))
            #expect(!Command.moveChatToProject.available(in: browser))
            let oldKeys = Keymap.shared.keys(.moveToProject)
            let changedKeys = Hotkey("p", [.command, .option, .control])
            Keymap.shared.set(changedKeys, for: .moveToProject)
            #expect(Command.moveChatToProject.keys == changedKeys.text)
            Keymap.shared.set(oldKeys, for: .moveToProject)
            browser.query.actionsPage = true
            browser.replaceTyped("New Project")
            #expect(browser.offers.contains { $0.kind == .command(.newChatProject) })
        }
    }

    @Test func staleAndArchivedProjectTargetsCannotRunOrStartNewChats() async throws {
        try await world { browser, projects, chats in
            let project = projects.add(name: "Gone soon", in: chats)
            let id = "openChatProject:" + project.id
            #expect(MenuCommands.targets(in: browser).contains { $0.id == id })
            browser.openProject(project.id)
            #expect(browser.chatProject == project.id && browser.chatHistory)
            projects.archive(project.id, true)
            #expect(!MenuCommands.runTarget(id, in: browser))
            browser.newChat(in: project.id)
            #expect(browser.chatNewProject == nil)
            projects.archive(project.id, false)
            browser.newChat(in: project.id)
            #expect(browser.chatNewProject == project.id && !browser.chatHistory)
            browser.newChat()
            #expect(browser.chatNewProject == nil)
            projects.delete(project.id, chats: chats)
            #expect(!MenuCommands.runTarget(id, in: browser))
        }
    }

    @Test func projectWorkspaceRequiresMacAccessAndKeepsCursorApprovalSeparate() {
        let project = Project(id: "prj-room0001", name: "Work", emoji: "W", tint: "blue",
            created: Date(), updated: Date(), order: "m")
        for cli in ["claude", "codex"] {
            #expect(Agents.workingFolder(cli: cli, id: "test", full: true, folder: nil, project: project) == project.files)
            #expect(Agents.workingFolder(cli: cli, id: "test", full: false, folder: nil, project: project) != project.files)
        }
        #expect(Agents.workingFolder(cli: "cursor", id: "test", full: true, folder: nil, project: project) != project.files)
    }

    @Test func projectsMergeBetweenChatsByRecencyWithPinnedChatsFirst() {
        let now = Date()
        func chat(_ id: String, _ ago: Double, pinned: Bool = false) -> Chat {
            Chat(id: id, title: id, began: .newTabs, cli: "claude", items: [], pinned: pinned,
                 state: "done", answer: "", started: now.addingTimeInterval(-ago), updated: now.addingTimeInterval(-ago))
        }
        let pinned = chat("pinned", 900, pinned: true)
        let newest = chat("newest", 10)
        let oldest = chat("oldest", 60)
        let project = Project(id: "prj-order001", name: "Work", emoji: "W", tint: "blue",
            created: now.addingTimeInterval(-100), updated: now.addingTimeInterval(-30), order: "m")
        let merged = ChatListEntry.merge([pinned, newest, oldest], projects: [(project, nil)])
        #expect(merged.map(\.id) == [pinned.listed, newest.listed, "project:" + project.id, oldest.listed])
        #expect(ProjectListRow.preview(nil) == "No chats yet")
    }
}
