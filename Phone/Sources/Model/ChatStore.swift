import Foundation
import Observation

/// Chats with the agent, the same list as on the Mac: pinned first, then by
/// day. Archive takes a chat out of the list, search still finds it;
/// Delete Chat (ChatFlow.deleteChat) removes it.
@MainActor
@Observable
final class ChatStore {
    private(set) var chats: [Chat]
    /// Ownership is chosen at creation, not from the currently selected page.
    private var localIDs: Set<Chat.ID> = []
    private var privateIDs: Set<Chat.ID> = []
    /// Private-origin words may be shown only inside unlocked Private.
    @ObservationIgnored var mayRevealPrivate: (() -> Bool)?
    private var syncedIDs: Set<Chat.ID> = []
    private var drafts: [Chat.ID: String] = [:]
    private var pendingLocalPrefixes: [Chat.ID: [Message]] = [:]
    private var linkedLocalPrefixes: [Chat.ID: LocalChatProfile.Entry] = [:]
    /// An answer or a chat put away into the Now line: tap brings it back,
    /// a swipe aside lets it go.
    var parked: Parked?

    struct Parked: Equatable, Sendable {
        enum Mode: Sendable { case answer, chat }
        var chat: Chat.ID
        var mode: Mode
    }

    init(world: World, local: [LocalChatProfile.Entry] = []) {
        chats = world.chats.filter { !$0.id.hasPrefix("c:") }
        for entry in local where entry.remoteChat?.hasPrefix("c:") != true && !chats.contains(where: { $0.id == entry.chat.id }) {
            var display = entry.chat
            if let remote = entry.remoteChat {
                linkedLocalPrefixes[remote] = entry
                display.id = remote
            } else { localIDs.insert(entry.chat.id) }
            if !chats.contains(where: { $0.id == display.id }) { chats.append(display) }
            if !entry.draft.isEmpty { drafts[display.id] = entry.draft }
        }
    }

    /// Only locally created public conversations belong in the browser folder.
    /// Synced heads and pending Mac sends belong to sync's journal instead.
    var localEntries: [LocalChatProfile.Entry] {
        let local: [LocalChatProfile.Entry] = chats.compactMap { chat in
            guard localIDs.contains(chat.id), !privateIDs.contains(chat.id), !syncedIDs.contains(chat.id),
                  !chat.ephemeral, chat.task == nil, LocalChatProfile.isLocalID(chat.id) else { return nil }
            var owned = chat
            if let prefix = pendingLocalPrefixes[chat.id] { owned.messages = prefix }
            return LocalChatProfile.Entry(chat: owned, draft: drafts[chat.id] ?? "")
        }
        let linked = linkedLocalPrefixes.sorted { $0.key < $1.key }.map { remote, original in
            var owned = original
            owned.draft = drafts[remote] ?? drafts[original.chat.id] ?? original.draft
            return owned
        }
        return local + linked
    }

    func draft(in id: Chat.ID) -> String { drafts[id] ?? "" }

    func setDraft(_ text: String, in id: Chat.ID) {
        guard chat(id) != nil else { return }
        drafts[id] = text
    }

    func chat(_ id: Chat.ID) -> Chat? { chats.first { $0.id == id } }

    func isPrivate(_ id: Chat.ID) -> Bool { privateIDs.contains(id) }

    func isVisible(_ id: Chat.ID) -> Bool { !isPrivate(id) || mayRevealPrivate?() == true }

    /// Raw records remain available to the local answer lifecycle, not UI.
    var visibleChats: [Chat] { chats.filter { isVisible($0.id) } }

    /// Your Chats: everything not archived, quick answers never continued left out.
    var listed: [Chat] { visibleChats.filter { !$0.archived && !$0.ephemeral } }
    var archived: [Chat] { visibleChats.filter(\.archived) }
    /// The number on the Chats button.
    var unreadCount: Int { listed.filter(\.unread).count }

    /// Your Chats in sections, as the list shows them: Pinned, Today,
    /// Yesterday, Earlier; empty sections left out.
    var sections: [(title: String, chats: [Chat])] {
        let list = listed
        var out: [(title: String, chats: [Chat])] = []
        func put(_ title: String, _ chats: [Chat]) { if !chats.isEmpty { out.append((title, chats)) } }
        put("Pinned", list.filter(\.pinned))
        put("Today", list.filter { !$0.pinned && $0.day == .today })
        put("Yesterday", list.filter { !$0.pinned && $0.day == .yesterday })
        put("Earlier", list.filter { !$0.pinned && $0.day == .earlier })
        return out
    }

    /// Chats whose title or words have `query` in them, archived ones too.
    func search(_ query: String) -> [Chat] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return visibleChats.filter { chat in
            !chat.ephemeral && (chat.title.lowercased().contains(q) || chat.messages.contains { $0.plain.lowercased().contains(q) })
        }
    }

    // MARK: - changing

    private func edit(_ id: Chat.ID, _ change: (inout Chat) -> Void) {
        guard let i = chats.firstIndex(where: { $0.id == id }) else { return }
        change(&chats[i])
    }

    func add(_ chat: Chat, isPrivate: Bool = false) {
        if let index = chats.firstIndex(where: { $0.id == chat.id }) { chats[index] = chat }
        else { chats.insert(chat, at: 0) }
        localIDs.insert(chat.id)
        if isPrivate { privateIDs.insert(chat.id) }
    }

    /// Chats as sync has them (Sync/SyncBridge): each takes the place of the
    /// one with its id, or comes in at the top; the others stay, unless
    /// `replacingAll` (a person's launch shows only the account's chats).
    func adopt(_ incoming: [Chat], replacingAll: Bool = false, preservingLocalHistory: Bool = false) {
        let ids = Set(incoming.map(\.id))
        if preservingLocalHistory {
            for id in ids where localIDs.contains(id) && !privateIDs.contains(id) && pendingLocalPrefixes[id] == nil {
                // Freeze only this iPhone's existing turns, before adoption.
                // Remote prompt/context and incoming messages never enter it.
                pendingLocalPrefixes[id] = chat(id)?.messages.filter { $0.role != .typing && $0.role != .wait } ?? []
            }
        }
        let journalOwned = ids.subtracting(preservingLocalHistory ? Set(pendingLocalPrefixes.keys) : [])
        syncedIDs.formUnion(journalOwned)
        localIDs.subtract(journalOwned)
        let synced = incoming.map { remote in
            guard let own = linkedLocalPrefixes[remote.id] else { return remote }
            if drafts[remote.id] == nil { drafts[remote.id] = drafts[own.chat.id] ?? own.draft }
            chats.removeAll { $0.id == own.chat.id && $0.id != remote.id }
            var prefix = own.chat.messages
            // The handoff's last local question becomes the Mac's first turn.
            // Deduplicate only that boundary, never repeated earlier questions.
            if let first = remote.messages.first, first.role == .you,
               prefix.last?.role == .you, prefix.last?.text == first.text { prefix.removeLast() }
            var merged = remote
            merged.messages = prefix + remote.messages
            return merged
        }
        if replacingAll { chats = synced; return }
        // By id, once: an account brings thousands of chats at a time.
        let at = Dictionary(chats.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        var all = chats
        var fresh: [Chat] = []
        for chat in synced {
            if let i = at[chat.id] { all[i] = chat } else { fresh.append(chat) }
        }
        chats = fresh + all
    }
    /// Called only after SyncBridge validates the returning head's Mac owner.
    /// This is local display history, not a second remote journal or send.
    @discardableResult
    func linkLocalHistory(_ local: Chat.ID, to remote: Chat.ID) -> Bool {
        guard LocalChatProfile.isRemoteID(remote) else { return false }
        let originalID = linkedLocalPrefixes[local]?.chat.id ?? local
        if let existing = linkedLocalPrefixes[remote], existing.chat.id != originalID { return false }
        if var linked = linkedLocalPrefixes.removeValue(forKey: local) {
            linked.remoteChat = remote
            linkedLocalPrefixes[remote] = linked
        } else if localIDs.contains(local), !privateIDs.contains(local), var own = chat(local), !own.ephemeral, own.task == nil {
            own.messages = pendingLocalPrefixes[local] ?? own.messages.filter { $0.role != .typing && $0.role != .wait }
            linkedLocalPrefixes[remote] = LocalChatProfile.Entry(chat: own, draft: drafts[local] ?? "", remoteChat: remote)
            localIDs.remove(local)
            pendingLocalPrefixes.removeValue(forKey: local)
        }
        if let draft = drafts[local], !draft.isEmpty { drafts[remote] = draft }
        return true
    }

    func setPinned(_ id: Chat.ID, _ on: Bool) { edit(id) { $0.pinned = on } }
    func setUnread(_ id: Chat.ID, _ on: Bool) { edit(id) { $0.unread = on } }
    func setArchived(_ id: Chat.ID, _ on: Bool) { edit(id) { $0.archived = on } }
    func rename(_ id: Chat.ID, to title: String) { edit(id) { $0.title = title } }
    func append(_ message: Message, to id: Chat.ID) { edit(id) { $0.messages.append(message) } }
    /// Any change to one chat (the chats branch: a typing turn becoming its answer).
    func update(_ id: Chat.ID, _ change: (inout Chat) -> Void) { edit(id, change) }
    /// A quick answer let go, never continued, or a chat deleted: it leaves
    /// nothing.
    func remove(_ id: Chat.ID) {
        chats.removeAll { $0.id == id }
        localIDs.remove(id)
        privateIDs.remove(id)
        pendingLocalPrefixes.removeValue(forKey: id)
        linkedLocalPrefixes.removeValue(forKey: id)
        drafts.removeValue(forKey: id)
        if parked?.chat == id { parked = nil }
    }

    /// What the Now line says for the chat put away.
    var parkedItem: NowItem? {
        guard let parked, isVisible(parked.chat), let chat = chat(parked.chat) else { return nil }
        switch parked.mode {
        case .answer:
            let question = chat.messages.last { $0.role == .you }?.text ?? chat.title
            return NowItem(id: chat.id, kind: .parked, title: "Answer", subtitle: question, action: nil, short: "Answer",
                           icon: .glyph(.sparkle), more: nil)
        case .chat:
            return NowItem(id: chat.id, kind: .parked, title: chat.title, subtitle: chat.lastAnswer?.plain ?? "", action: nil,
                           short: "Chat", icon: .face, more: nil)
        }
    }
}
