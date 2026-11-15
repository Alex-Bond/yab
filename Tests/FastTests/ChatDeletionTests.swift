import AppKit
import Foundation
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct ChatDeletionTests {
    @MainActor private struct World {
        let browsers: [Browser]
        let chats: Chats
        let agents: Agents
        let root: URL

        func keep(_ id: String) {
            let now = Date()
            chats.keep(Chat(id: id, title: id, began: .newTabs, cli: "claude", items: [],
                            state: "done", answer: "Saved answer", started: now, updated: now))
        }

        func session(_ id: String) throws -> Agents.Session {
            // Isolated collection, initially external so benchTask.changed
            // cannot keep anything in Chats.shared. No run/process is started.
            agents.benchTask(id, state: .done)
            let session = try #require(agents.session(id))
            session.cli = "claude"
            return session
        }

        @discardableResult
        func delete(_ id: String, from browser: Browser) -> Bool {
            browser.deleteChat(id, chats: chats, agents: agents, windows: browsers)
        }
    }

    private func world(_ body: @MainActor (World) async throws -> Void) async throws {
        try #require(Store.testing && Store.unitTests && Store.world != nil && Store.settings !== UserDefaults.standard)
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-delete-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let keys = ["mail", "search.suggest", "sidebar", "sidebar.shut", "sidebar.width", "sidebar.flank"]
        let values = keys.map { Store.settings.object(forKey: $0) }
        let dragged = ChatLook.dragged, foldersBrowser = Folders.shared.browser
        Store.settings.set(false, forKey: "mail")
        Store.settings.set(false, forKey: "search.suggest")
        // benchTask's synchronous Folders.refresh is inert for this fixture.
        Folders.shared.browser = nil
        let projects = Projects(folder: root.appendingPathComponent("projects"))
        let chats = Chats(folder: root.appendingPathComponent("chats"), projects: projects)
        let browsers = (0..<3).map { _ in Browser(windowID: UUID()) }
        for browser in browsers { browser.lookForMailSignInLink = {} }
        // Browser.init may make its first fixture the shared folder owner.
        // Keep the benchTask refresh inert after construction as well.
        Folders.shared.browser = nil
        defer {
            for browser in browsers {
                browser.everyTab.forEach { $0.close() }
                browser.dozing?.invalidate()
                browser.stuck.timer?.invalidate()
                browser.pressure?.cancel()
                browser.letGo()
                browser.dropSpare()
                if let id = browser.windowID {
                    try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
                    Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
                }
            }
            ChatLook.dragged = dragged
            for (key, value) in zip(keys, values) {
                if let value { Store.settings.set(value, forKey: key) }
                else { Store.settings.removeObject(forKey: key) }
            }
            Folders.shared.browser = foldersBrowser
        }
        let w = World(browsers: browsers, chats: chats, agents: Agents(), root: root)
        var outcome: Result<Void, Error>
        do { try await body(w); outcome = .success(()) }
        catch { outcome = .failure(error) }
        // Drain every owned transition before disposing its browser/world.
        browsers.forEach { $0.hideChat() }
        for browser in browsers {
            do { try await settle(browser) }
            catch { if case .success = outcome { outcome = .failure(error) } }
        }
        // Join the same serial main queue after its real one-second save
        // debounce, then drain its disk queue before removing the folder.
        // This cleanup still runs when the test body was cancelled/threw.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { continuation.resume() }
        }
        await chats.flush()
        try FileManager.default.removeItem(at: root)
        try outcome.get()
    }

    private func settle(_ browser: Browser) async throws {
        for _ in 0..<300 {
            if !browser.chatMoving { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("chat delete transition did not finish")
    }

    private func show(_ id: String, in browser: Browser) async throws {
        browser.keepChat(id)
        browser.moveChat(open: true)
        try await settle(browser)
        try #require(browser.chatOpen)
    }

    @Test func deletingTheSelectedChatClosesItsRealColumnAndStoreRow() async throws {
        try await world { w in
            let id = "selected-" + UUID().uuidString, browser = w.browsers[0]
            w.keep(id)
            try await show(id, in: browser)
            #expect(w.delete(id, from: browser))
            try await settle(browser)
            #expect(!browser.chatOpen && !browser.chatMoving && browser.chatRestoration == nil)
            #expect(browser.chatPinned == nil && browser.chatShown == nil && !browser.chatFresh)
            #expect(w.chats.chat(id) == nil)
            await w.chats.flush()
            #expect(!Chats.read(w.root.appendingPathComponent("chats")).contains { $0.id == id })
        }
    }

    @Test func deletingAnActiveTabConversationDoesNotReselectItsRetainedTask() async throws {
        try await world { w in
            let id = "tab-chat-" + UUID().uuidString, browser = w.browsers[0]
            w.keep(id)
            let session = try w.session(id)
            let tab = Tab(bench: true)
            tab.agent = id
            browser.lay([tab]); browser.activeID = tab.id
            browser.chatPinned = nil; browser.chatShown = nil
            browser.moveChat(open: true)
            try await settle(browser)
            #expect(browser.chatID(using: w.agents) == id)
            #expect(w.delete(id, from: browser))
            try await settle(browser)
            #expect(!browser.chatOpen && browser.chatFresh)
            #expect(browser.chatID(using: w.agents) == nil)
            #expect(w.agents.session(id) === session && session.state == .done && session.process == nil)
            // Opening the empty composer is still allowed, without bringing
            // back the deleted conversation from that same tab's task.
            browser.moveChat(open: true)
            try await settle(browser)
            #expect(browser.chatOpen && browser.chatID(using: w.agents) == nil)
            #expect(w.chats.chat(id) == nil)
        }
    }

    @Test func everyMatchingWindowClosesWhileAnotherConversationStaysOpen() async throws {
        try await world { w in
            let id = "shared-" + UUID().uuidString, other = "other-" + UUID().uuidString
            w.keep(id); w.keep(other)
            try await show(id, in: w.browsers[0]); try await show(id, in: w.browsers[1])
            try await show(other, in: w.browsers[2])
            let untouched = w.browsers[2], generation = untouched.chatMovement.generation
            #expect(w.delete(id, from: w.browsers[0]))
            for browser in w.browsers { try await settle(browser) }
            #expect(!w.browsers[0].chatOpen && !w.browsers[1].chatOpen)
            #expect(w.browsers[0].chatID(using: w.agents) == nil && w.browsers[1].chatID(using: w.agents) == nil)
            #expect(untouched.chatOpen && untouched.chatPinned == other && untouched.chatShown == other)
            #expect(untouched.chatMovement.generation == generation && w.chats.chat(other) != nil)
        }
    }

    @Test(arguments: ["history", "extension", "hidden"])
    func nonConversationPanesKeepTheirModelTargets(kind: String) async throws {
        try await world { w in
            let id = "protected-" + UUID().uuidString, browser = w.browsers[0]
            w.keep(id)
            if kind == "hidden" { browser.keepChat(id) }
            else { try await show(id, in: browser) }
            if kind == "history" { browser.chatHistory = true }
            if kind == "extension" { browser.panelExtension = "fixture-extension" }
            let open = browser.chatOpen, pinned = browser.chatPinned, shown = browser.chatShown
            let generation = browser.chatMovement.generation, focus = browser.chatFocus
            #expect(w.delete(id, from: browser))
            #expect(browser.chatOpen == open && browser.chatPinned == pinned && browser.chatShown == shown)
            #expect(!browser.chatFresh && browser.chatMovement.generation == generation && browser.chatFocus == focus)
            #expect(browser.chatHistory == (kind == "history"))
            #expect(browser.panelExtension == (kind == "extension" ? "fixture-extension" : nil))
            #expect(w.chats.chat(id) == nil)
            browser.panelExtension = nil
        }
    }

    @Test func deletingABackgroundChatDoesNotCloseTheSelectedConversation() async throws {
        try await world { w in
            let id = "background-" + UUID().uuidString, other = "selected-" + UUID().uuidString
            w.keep(id); w.keep(other)
            let browser = w.browsers[0]
            try await show(other, in: browser)
            let generation = browser.chatMovement.generation
            #expect(w.delete(id, from: browser))
            #expect(browser.chatOpen && browser.chatID(using: w.agents) == other && !browser.chatFresh)
            #expect(browser.chatMovement.generation == generation && w.chats.chat(other) != nil)
        }
    }

    @Test func aPendingOpenIsCancelledAndRepeatedDeleteDoesNotMoveAgain() async throws {
        try await world { w in
            let id = "pending-" + UUID().uuidString, browser = w.browsers[0]
            w.keep(id); browser.keepChat(id)
            browser.moveChat(open: true)
            #expect(browser.chatMovement.target == true)
            #expect(w.delete(id, from: browser))
            try await settle(browser)
            try await Task.sleep(for: .milliseconds(60))
            #expect(!browser.chatOpen && !browser.chatMoving && browser.chatPinned == nil && browser.chatShown == nil)
            let generation = browser.chatMovement.generation, focus = browser.chatFocus
            #expect(w.delete(id, from: browser))
            #expect(browser.chatMovement.generation == generation && browser.chatFocus == focus)
        }
    }

    @Test func liveStateIsRecheckedAtTheActualPostConfirmationDispatch() async throws {
        try await world { w in
            let id = "confirm-" + UUID().uuidString, browser = w.browsers[0]
            w.keep(id)
            let session = try w.session(id)
            try await show(id, in: browser)
            // The menu/confirmation began while finished, then a new turn
            // started. Invoke the same route the confirmed button invokes.
            session.state = .running
            let generation = browser.chatMovement.generation
            #expect(!w.delete(id, from: browser))
            #expect(browser.chatOpen && browser.chatPinned == id && browser.chatShown == id)
            #expect(browser.chatMovement.generation == generation && w.chats.chat(id) != nil)
            #expect(session.state == .running && session.process == nil)
            session.state = .done
            #expect(w.delete(id, from: browser))
            try await settle(browser)
            #expect(!browser.chatOpen && w.chats.chat(id) == nil)
        }
    }

    @Test func thePropertyAndDispatchShareTheExistingSelectionPrecedence() async throws {
        try await world { w in
            let browser = w.browsers[0], id = "precedence-" + UUID().uuidString
            _ = try w.session(id)
            let tab = Tab(bench: true); tab.agent = id
            browser.lay([tab]); browser.activeID = tab.id
            browser.chatShown = "last"; browser.chatPinned = "picked"
            #expect(browser.chatID == "picked" && browser.chatID(using: w.agents) == "picked")
            browser.chatFresh = true
            #expect(browser.chatID == nil && browser.chatID(using: w.agents) == nil)
            browser.chatFresh = false; browser.chatPinned = nil
            #expect(browser.chatID(using: w.agents) == id)
            tab.agent = nil
            #expect(browser.chatID(using: w.agents) == "last")
        }
    }
}
