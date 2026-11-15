import WebKit
import SyncKit
import XCTest
@testable import YabPhone

@MainActor
final class LocalChatProfileTests: XCTestCase {
    private var root: URL!
    private var stores = Set<UUID>()

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalChatProfileTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for id in stores { try await WKWebsiteDataStore.remove(forIdentifier: id) }
        stores.removeAll()
        try FileManager.default.removeItem(at: root)
    }

    private func world() -> World {
        let snapshot = BrowserProfile.Snapshot.empty()
        return World(name: "local-test", space: snapshot.spaceID, spaces: snapshot.spaces, mac: World.Mac(joined: false))
    }

    private func conversation(_ id: String = UUID().uuidString, text: String = "A real local answer") -> Chat {
        Chat(id: id, title: "Local discussion", by: .iphone,
             messages: [Message(role: .you, text: "Explain this page"), Message(role: .answer, text: text, by: .iphone)])
    }

    private func liveApp(allowPrivateForThisTest: Bool = false) -> AppModel {
        let profile = BrowserProfile(folder: root)
        if let id = profile.dataStoreID { stores.insert(id) }
        if allowPrivateForThisTest {
            // Only this storage-boundary test disables its injected gate.
            return AppModel(world: profile.world, fixturesEnabled: false, profile: profile, privateLockEnabled: { false })
        }
        return AppModel(world: profile.world, fixturesEnabled: false, profile: profile)
    }

    func testRetiredRemoteChatsCannotReturnFromWorldOrLocalHistory() throws {
        var bootstrap = world()
        bootstrap.chats = [conversation("a:kept"), conversation("c:retired")]
        let local = conversation("local-kept")
        let retired = LocalChatProfile.Entry(chat: conversation("local-retired"), draft: "Old draft", remoteChat: "c:retired")
        let entries = [retired, LocalChatProfile.Entry(chat: local, draft: "Local draft")]
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entries))
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "entries": encoded])
        try data.write(to: root.appendingPathComponent("local-chats.json"))
        let profile = LocalChatProfile(folder: root)
        XCTAssertNil(profile.lastWriteError)
        let store = ChatStore(world: bootstrap, local: profile.entries)
        XCTAssertEqual(Set(store.chats.map(\.id)), ["a:kept", "local-kept"])
        XCTAssertEqual(store.draft(in: local.id), "Local draft")
        XCTAssertEqual(store.localEntries.map { $0.chat.id }, [local.id])
        XCTAssertFalse(store.linkLocalHistory(local.id, to: "c:retired"))
    }

    func testPublicConversationMetadataAndDraftSurviveBackCloseAndRelaunch() async throws {
        let app = liveApp()
        let chat = conversation()
        app.chats.add(chat)
        app.openChat(chat.id)
        app.chatSheet.draft = "Follow up after reopening"
        app.setPinned(chat.id, true)
        app.rename(chat.id, to: "Saved local title")
        app.openHistory()
        XCTAssertEqual(app.surfaces.field, .newTab, "‹ goes to New Tab's Chats page")
        app.hideSheet()
        app.openChat(chat.id)
        XCTAssertEqual(app.chatSheet.draft, "Follow up after reopening")
        app.archive(chat.id)
        app.chats.setUnread(chat.id, true)
        let original = try XCTUnwrap(app.chats.chat(chat.id))
        let identity = try Data(contentsOf: root.appendingPathComponent("website-data-store.json"))
        await app.flushProfile()
        XCTAssertNil(app.localChatProfile?.lastWriteError)

        let reopened = liveApp()
        XCTAssertEqual(reopened.chats.chat(chat.id), original)
        XCTAssertEqual(reopened.chats.archived.map(\.id), [chat.id])
        XCTAssertTrue(reopened.chats.listed.isEmpty)
        XCTAssertEqual(reopened.chats.draft(in: chat.id), "Follow up after reopening")
        reopened.chats.setArchived(chat.id, false)
        reopened.openChat(chat.id)
        XCTAssertEqual(reopened.chatSheet.draft, "Follow up after reopening")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("website-data-store.json")), identity)
        XCTAssertNil(reopened.sync.engine)
    }

    func testPrivateOriginNeverBecomesPersistableAfterSwitchingToPublic() async throws {
        let app = liveApp(allowPrivateForThisTest: true)
        app.browser.showSpace("local.private")
        app.newChat(focus: false)
        let id = try XCTUnwrap(app.chatSheet.chatID)
        app.chatSheet.draft = "private-only-draft"
        app.chats.update(id) { chat in
            chat.ephemeral = false
            chat.title = "private-only-title"
            chat.messages = [Message(role: .you, text: "private-only-question"), Message(role: .answer, text: "private-only-answer", by: .iphone)]
        }
        app.browser.showSpace("local.personal")
        app.setPinned(id, true)
        app.archive(id)
        let publicChat = conversation(text: "public-answer-retained")
        app.chats.add(publicChat)
        await app.flushProfile()
        let bytes = try Data(contentsOf: root.appendingPathComponent("local-chats.json"))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("private-only"))
        let reopened = liveApp()
        XCTAssertNil(reopened.chats.chat(id))
        XCTAssertEqual(reopened.chats.chat(publicChat.id)?.lastAnswer?.text, "public-answer-retained")
        XCTAssertNil(reopened.sync.engine)
    }

    func testSyncAdoptionTakesOwnershipWithoutDuplicatingOrOverwritingRemoteHistory() async throws {
        let local = LocalChatProfile(folder: root)
        let pending = conversation("pending-local-id", text: "Earlier local answer")
        let store = ChatStore(world: world())
        store.add(pending)
        local.capture(store.localEntries)
        await local.flush()
        let restored = ChatStore(world: world(), local: LocalChatProfile(folder: root).entries)
        var accepted = pending
        accepted.messages.append(Message(role: .answer, text: "Journal's newer answer", by: .claude))
        restored.adopt([accepted])
        let remote = Chat(id: "a:remote", title: "Remote", messages: [Message(role: .answer, text: "Remote full history", by: .claude)])
        restored.adopt([remote])
        XCTAssertEqual(restored.chats.filter { $0.id == pending.id }.count, 1)
        XCTAssertEqual(restored.chat(pending.id)?.lastAnswer?.text, "Journal's newer answer")
        XCTAssertEqual(restored.chat(remote.id), remote)
        XCTAssertTrue(restored.localEntries.isEmpty)
        local.capture(restored.localEntries)
        await local.flush()
        XCTAssertTrue(LocalChatProfile(folder: root).entries.isEmpty)
        // Loading an empty local file never replaces the sync bootstrap.
        var bootstrap = world()
        bootstrap.chats = [remote, accepted]
        let reopened = ChatStore(world: bootstrap, local: LocalChatProfile(folder: root).entries)
        XCTAssertEqual(reopened.chats, [remote, accepted])
    }

    func testUnreadableLocalFileIsKeptByteForByteAndNotReplacedWithEmptyState() async throws {
        let file = root.appendingPathComponent("local-chats.json")
        let original = Data("{broken-but-recoverable".utf8)
        try original.write(to: file)
        let profile = LocalChatProfile(folder: root)
        XCTAssertNotNil(profile.lastWriteError)
        XCTAssertTrue(profile.entries.isEmpty)
        let store = ChatStore(world: world())
        store.add(conversation())
        profile.capture(store.localEntries)
        await profile.flush()
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertNotNil(profile.lastWriteError)
    }

    func testOldBrowserProfileNeedsNoMigrationAndItsIdentityAndSyncFilesStayUntouched() async throws {
        let browser = root.appendingPathComponent("profile.json")
        let identity = root.appendingPathComponent("website-data-store.json")
        let syncMarker = root.appendingPathComponent("sync-journal-marker")
        let oldBrowser = try JSONEncoder().encode(BrowserProfile.Snapshot.empty())
        let oldIdentity = Data("existing-identity-marker".utf8)
        let oldSync = Data("existing-sync-marker".utf8)
        try oldBrowser.write(to: browser)
        try oldIdentity.write(to: identity)
        try oldSync.write(to: syncMarker)
        let profile = LocalChatProfile(folder: root)
        XCTAssertTrue(profile.entries.isEmpty)
        let store = ChatStore(world: world())
        store.add(conversation())
        profile.capture(store.localEntries)
        await profile.flush()
        XCTAssertEqual(try Data(contentsOf: browser), oldBrowser)
        XCTAssertEqual(try Data(contentsOf: identity), oldIdentity)
        XCTAssertEqual(try Data(contentsOf: syncMarker), oldSync)
        XCTAssertEqual(LocalChatProfile(folder: root).entries.count, 1)
    }

    func testInterruptedLocalTurnRestoresQuestionAndDraftWithoutTypingOrAutomaticSend() async throws {
        let app = liveApp()
        var chat = conversation()
        chat.messages = [Message(role: .you, text: "Still unanswered"), Message(role: .typing, by: .iphone)]
        app.chats.add(chat)
        app.chats.setDraft("Next question stays unsent", in: chat.id)
        await app.flushProfile()
        XCTAssertEqual(app.chats.chat(chat.id)?.messages.last?.role, .typing)
        let reopened = liveApp()
        let restored = try XCTUnwrap(reopened.chats.chat(chat.id))
        XCTAssertEqual(restored.messages.first?.text, "Still unanswered")
        XCTAssertEqual(restored.messages.last?.role, .note)
        XCTAssertTrue(restored.messages.last?.text.contains("interrupted") == true)
        XCTAssertFalse(restored.messages.contains { $0.role == .typing || $0.role == .wait })
        XCTAssertEqual(reopened.chats.draft(in: chat.id), "Next question stays unsent")
        XCTAssertNil(reopened.sync.engine)
        XCTAssertTrue(reopened.chatSheet.sendingToMac.isEmpty)
        XCTAssertTrue(reopened.chatSheet.answeringHere.isEmpty)
    }

    func testEphemeralAnswersTasksAndFixtureLaunchesStayOutOfLocalStorage() async throws {
        let store = ChatStore(world: world())
        var quick = conversation("quick")
        quick.ephemeral = true
        store.add(quick)
        store.add(Chat(id: "task", title: "Task", task: "task"))
        store.add(conversation("c:known-remote"))
        XCTAssertTrue(store.localEntries.isEmpty)
        let profile = LocalChatProfile(folder: root)
        profile.capture(store.localEntries)
        await profile.flush()
        XCTAssertTrue(LocalChatProfile(folder: root).entries.isEmpty)
        let injected = BrowserProfile(folder: root)
        if let id = injected.dataStoreID { stores.insert(id) }
        let fixture = AppModel(world: world(), fixturesEnabled: true, profile: injected)
        XCTAssertNil(fixture.localChatProfile)
        // The existing draft callback retains every conversation only in memory.
        // Fixture launches have no local profile or disk observer to receive it.
        XCTAssertNotNil(fixture.chatSheet.onDraftChange)
        let id = "owned.fixture.memory.draft"
        fixture.chats.add(conversation(id))
        fixture.chatSheet.onDraftChange?(id, "Owned fixture draft stays in memory")
        XCTAssertEqual(fixture.chats.draft(in: id), "Owned fixture draft stays in memory")
        await fixture.flushProfile()
        XCTAssertTrue(LocalChatProfile(folder: root).entries.isEmpty)
    }

    func testLatestCheckpointWinsOverQueuedOlderMessagesAndMetadata() async throws {
        let profile = LocalChatProfile(folder: root)
        let store = ChatStore(world: world())
        let chat = conversation()
        store.add(chat)
        profile.capture(store.localEntries)
        store.append(Message(role: .answer, text: "Newest answer", by: .iphone), to: chat.id)
        store.rename(chat.id, to: "Newest title")
        store.setDraft("Newest draft", in: chat.id)
        profile.capture(store.localEntries)
        await profile.flush()
        let entry = try XCTUnwrap(LocalChatProfile(folder: root).entries.first)
        XCTAssertEqual(entry.chat.title, "Newest title")
        XCTAssertEqual(entry.chat.lastAnswer?.text, "Newest answer")
        XCTAssertEqual(entry.draft, "Newest draft")
    }

    func testLocalPrefixSurvivesPendingRestartAndRemoteRebindWithoutCopyingRemoteSecrets() async throws {
        let profile = LocalChatProfile(folder: root)
        let localID = "own-local-prefix"
        let store = ChatStore(world: world())
        let own = conversation(localID, text: "Actual previous local answer")
        store.add(own)
        store.append(Message(role: .you, text: "Continue on Mac"), to: localID)
        store.append(Message(role: .typing, by: .claude), to: localID)
        store.setDraft("Draft beyond the pending question", in: localID)
        let send = try XCTUnwrap(SyncSend(Record(collection: "send", id: "owned-send", fields: [
            "device": "owned-mac", "clientDevice": "owned-phone", "clientChat": .string(localID),
            "text": "REMOTE-PROMPT-SECRET", "question": "Continue on Mac", "at": 1
        ])))
        let pending = try XCTUnwrap(SyncMapping.pendingChat(send, old: store.chat(localID), macAsleep: false))
        store.adopt([pending], preservingLocalHistory: true)
        profile.capture(store.localEntries)
        await profile.flush()
        let restarted = ChatStore(world: world(), local: LocalChatProfile(folder: root).entries)
        XCTAssertEqual(restarted.chat(localID)?.messages.filter { $0.text == "Actual previous local answer" }.count, 1)
        let pendingAgain = try XCTUnwrap(SyncMapping.pendingChat(send, old: restarted.chat(localID), macAsleep: false))
        restarted.adopt([pendingAgain], preservingLocalHistory: true)
        XCTAssertEqual(restarted.chat(localID)?.messages.filter { $0.role == .you && $0.text == "Continue on Mac" }.count, 1)
        XCTAssertTrue(restarted.linkLocalHistory(localID, to: "a:owned-return"))
        restarted.remove(localID)
        let remote = Chat(id: "a:owned-return", title: "Current remote title", pinned: true, unread: true,
                          messages: [Message(role: .you, text: "Continue on Mac"),
                                     Message(role: .answer, text: "REMOTE-ANSWER-SECRET", by: .claude)])
        restarted.adopt([remote])
        restarted.adopt([remote])
        XCTAssertEqual(restarted.chats.count, 1)
        XCTAssertNil(restarted.chat(localID))
        XCTAssertEqual(restarted.chat(remote.id)?.messages.filter { $0.text == "Actual previous local answer" }.count, 1)
        XCTAssertEqual(restarted.chat(remote.id)?.messages.filter { $0.role == .you && $0.text == "Continue on Mac" }.count, 1)
        XCTAssertEqual(restarted.chat(remote.id)?.lastAnswer?.text, "REMOTE-ANSWER-SECRET")
        XCTAssertEqual(restarted.chat(remote.id)?.title, "Current remote title")
        profile.capture(restarted.localEntries)
        await profile.flush()
        let disk = try Data(contentsOf: profile.file)
        XCTAssertFalse(String(decoding: disk, as: UTF8.self).contains("REMOTE-PROMPT-SECRET"))
        XCTAssertFalse(String(decoding: disk, as: UTF8.self).contains("REMOTE-ANSWER-SECRET"))
        let rebound = ChatStore(world: world(), local: LocalChatProfile(folder: root).entries)
        XCTAssertNil(rebound.chat(localID))
        rebound.adopt([remote])
        XCTAssertEqual(rebound.chats.count, 1)
        XCTAssertEqual(rebound.chat(remote.id)?.messages.filter { $0.text == "Actual previous local answer" }.count, 1)
        XCTAssertEqual(rebound.chat(remote.id)?.messages.filter { $0.role == .you && $0.text == "Continue on Mac" }.count, 1)
        XCTAssertEqual(rebound.draft(in: remote.id), "Draft beyond the pending question")
        rebound.setDraft("", in: remote.id)
        rebound.adopt([remote])
        profile.capture(rebound.localEntries)
        await profile.flush()
        XCTAssertEqual(LocalChatProfile(folder: root).entries.first?.draft, "")
        rebound.remove(remote.id)
        profile.capture(rebound.localEntries)
        await profile.flush()
        XCTAssertTrue(LocalChatProfile(folder: root).entries.isEmpty)
    }

    func testOversizeCheckpointAndReadPreserveThePreviousFile() async throws {
        let profile = LocalChatProfile(folder: root, maximumBytes: 1024)
        let store = ChatStore(world: world())
        let chat = conversation()
        store.add(chat)
        profile.capture(store.localEntries)
        await profile.flush()
        XCTAssertNil(profile.lastWriteError)
        let before = try Data(contentsOf: profile.file)
        store.append(Message(role: .answer, text: String(repeating: "x", count: 2048), by: .iphone), to: chat.id)
        profile.capture(store.localEntries)
        await profile.flush()
        XCTAssertNotNil(profile.lastWriteError)
        XCTAssertEqual(try Data(contentsOf: profile.file), before)
        XCTAssertEqual(LocalChatProfile(folder: root).entries.first?.chat.lastAnswer?.text, "A real local answer")
        let limitedRead = LocalChatProfile(folder: root, maximumBytes: 32)
        XCTAssertNotNil(limitedRead.lastWriteError)
        limitedRead.capture([])
        await limitedRead.flush()
        XCTAssertEqual(try Data(contentsOf: profile.file), before)
    }

    func testASecondLocalPrefixCannotOverwriteAnExistingRemoteAssociation() {
        let store = ChatStore(world: world())
        store.add(conversation("first-local", text: "First local history"))
        store.add(conversation("second-local", text: "Earlier version"))
        store.add(conversation("second-local", text: "Second local history"))
        XCTAssertEqual(store.chats.filter { $0.id == "second-local" }.count, 1)
        XCTAssertTrue(store.linkLocalHistory("first-local", to: "a:one-return"))
        store.remove("first-local")
        XCTAssertFalse(store.linkLocalHistory("second-local", to: "a:one-return"))
        XCTAssertNotNil(store.chat("second-local"))
        XCTAssertEqual(store.localEntries.first { $0.remoteChat == "a:one-return" }?.chat.lastAnswer?.text, "First local history")
        XCTAssertEqual(store.localEntries.first { $0.chat.id == "second-local" }?.chat.lastAnswer?.text, "Second local history")
    }

}
