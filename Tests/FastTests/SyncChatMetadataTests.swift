import Foundation
import Testing
import SyncKit
@testable import Fast

@MainActor
struct SyncChatMetadataTests {
    let device = "metadata-mac"
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    init() { SyncShapes.register() }

    private func agent(_ id: String = "agent") -> Chat {
        Chat(id: id, title: "Generated", began: .newTabs, cli: "claude", items: [], state: "done",
             answer: "First answer", started: now, updated: now)
    }

    private func receive(_ fields: [String: Value], chat id: String, mac: Journal) throws -> [Record] {
        let phone = try Journal(path: nil, device: "metadata-phone")
        _ = try phone.receive(mac.all(SyncChats.chat).map { ($0, Int64(1)) })
        try phone.change(.init(collection: SyncChats.chat, id: id), fields)
        return try mac.receive(phone.pending().map { ($0.record, Int64(2)) })
    }

    private func publish(_ head: [String: Value], id: String, mac: Journal) throws {
        try mac.reconcile(SyncChats.chat, [id: head])
        try mac.sent(mac.pending().map { ($0.record, Int64(1)) })
    }

    @Test func anAgentKeepsRemoteChoicesThroughANewTurnAndRestartWithoutStaleEcho() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = agent()
        let beforeRestart = Chats(folder: folder)
        beforeRestart.keep(original)
        await beforeRestart.flush()
        let chats = Chats(folder: folder)
        #expect(chats.all.isEmpty)
        let id = SyncChats.id(agent: original.id)
        let mac = try Journal(path: nil, device: device)
        try publish(SyncChats.head(original, kind: "agent", device: device), id: id, mac: mac)
        let received = try receive(["title": "Chosen on iPhone", "pinned": true, "archived": true, "unread": true], chat: id, mac: mac)
        #expect(SyncChats.adopt(received, device: device, chats: chats) == [id])
        let chosen = try #require(chats.chat(original.id))
        #expect(chosen.updated == original.updated)
        let firstEcho = try mac.reconcile(SyncChats.chat, [id: SyncChats.head(chosen, kind: "agent", device: device)])
        #expect(firstEcho.isEmpty)
        #expect(mac.pendingCount == 0)
        #expect(SyncChats.adopt(received, device: device, chats: chats).isEmpty)

        var nextTurn = original
        nextTurn.title = "Another generated title"
        nextTurn.answer = "A later answer"
        nextTurn.updated = now.addingTimeInterval(10)
        nextTurn.unread = nil
        chats.keep(nextTurn)
        let kept = try #require(chats.chat(original.id))
        #expect(kept.title == "Chosen on iPhone")
        #expect(kept.pinned && kept.archived == true && kept.unread == true)
        #expect(kept.answer == nextTurn.answer)
        let before = try #require(mac.record(.init(collection: SyncChats.chat, id: id)))
        try mac.reconcile(SyncChats.chat, [id: SyncChats.head(kept, kind: "agent", device: device)])
        let after = try #require(mac.record(before.key))
        for field in ["title", "pinned", "archived", "unread"] {
            #expect(after[field] == before[field])
            #expect(after.stamps[field] == before.stamps[field])
        }
        try mac.sent(mac.pending().map { ($0.record, Int64(3)) })
        let repeated = try mac.reconcile(SyncChats.chat, [id: SyncChats.head(kept, kind: "agent", device: device)])
        #expect(repeated.isEmpty && mac.pendingCount == 0)

        await chats.flush()
        let reopened = try #require(Chats.read(folder, now: now).first)
        #expect(reopened.title == kept.title && reopened.pinned && reopened.archived == true && reopened.unread == true)
        var thirdTurn = nextTurn
        thirdTurn.title = "Regenerated after restart"
        thirdTurn.unread = nil
        let restored = thirdTurn.keepingMetadata(from: reopened)
        #expect(restored.title == kept.title && restored.unread == true)

        let cleared = try receive(["pinned": .null, "archived": .null, "unread": .null], chat: id, mac: mac)
        _ = SyncChats.adopt(cleared, device: device, chats: chats)
        thirdTurn.unread = true
        chats.keep(thirdTurn)
        let read = try #require(chats.chat(original.id))
        #expect(!read.pinned && read.archived == nil && read.unread == nil && read.unreadOverride == false)
        await chats.flush()
        #expect(Chats.read(folder, now: now).first?.unreadOverride == false)
    }

    @Test func thisMacsOwnHeadDoesNotFreezeGeneratedTitlesOrUnreadState() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let chats = Chats(folder: folder)
        let original = agent()
        chats.keep(original)
        let mac = try Journal(path: nil, device: device)
        try publish(SyncChats.head(original, kind: "agent", device: device), id: SyncChats.id(agent: original.id), mac: mac)
        #expect(SyncChats.adopt(mac.all(SyncChats.chat), device: device, chats: chats).isEmpty)
        var next = original
        next.title = "A newer generated title"
        next.unread = true
        chats.keep(next)
        #expect(chats.chat(original.id)?.title == next.title)
        #expect(chats.chat(original.id)?.unread == true)
        #expect(chats.chat(original.id)?.unreadOverride == nil)
    }

    @Test func aReadAgentAnswerDoesNotMaskTheNextIdenticalAnswerOrReplayAnOldRead() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let chats = Chats(folder: folder)
        var first = agent()
        first.items = [ChatItem(id: "q1", kind: .asked, text: "First question"),
                       ChatItem(id: "a1", kind: .message, text: first.answer)]
        first.unread = true
        chats.keep(first)
        let mac = try Journal(path: nil, device: device)
        let id = SyncChats.id(agent: first.id)
        try publish(SyncChats.head(first, kind: "agent", device: device), id: id, mac: mac)
        let read = try receive(["unread": .null], chat: id, mac: mac)
        _ = SyncChats.adopt(read, device: device, chats: chats)
        var projection = first
        projection.updated = now.addingTimeInterval(10)
        chats.keep(projection)
        #expect(chats.chat(first.id)?.unread == nil)
        await chats.flush()
        let restored = try #require(Chats.read(folder, now: now).first)
        let reloaded = Chats(folder: folder)
        reloaded.keep(restored)
        #expect(SyncChats.adopt(read, device: device, chats: reloaded).isEmpty)
        var next = projection
        next.items += [ChatItem(id: "q2", kind: .asked, text: "Another question"),
                       ChatItem(id: "a2", kind: .message, text: first.answer)]
        reloaded.keep(next)
        #expect(reloaded.chat(first.id)?.unread == true)
        #expect(reloaded.chat(first.id)?.unreadOverride == nil)
        #expect(SyncChats.adopt(read, device: device, chats: reloaded).isEmpty)
        let head = SyncChats.head(try #require(reloaded.chat(first.id)), kind: "agent", device: device)
        try mac.reconcile(SyncChats.chat, [id: head])
        #expect(mac.record(.init(collection: SyncChats.chat, id: id))?["unread"]?.bool == true)
        #expect(mac.record(.init(collection: SyncChats.chat, id: id))?.stamps["unread"]?.device == device)
    }

    @Test func aLaterPinDoesNotReplayAnOlderRemoteTitleOverALocalRename() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let chats = Chats(folder: folder)
        let original = agent()
        chats.keep(original)
        let mac = try Journal(path: nil, device: device)
        let id = SyncChats.id(agent: original.id)
        try publish(SyncChats.head(original, kind: "agent", device: device), id: id, mac: mac)
        let title = try receive(["title": "Remote name"], chat: id, mac: mac)
        _ = SyncChats.adopt(title, device: device, chats: chats)
        chats.rename(original.id, "Local name")
        await chats.flush()
        let cold = Chats(folder: folder)
        let pin = try receive(["pinned": true], chat: id, mac: mac)
        _ = SyncChats.adopt(pin, device: device, chats: cold)
        #expect(cold.chat(original.id)?.title == "Local name")
        #expect(cold.chat(original.id)?.pinned == true)
    }

}
