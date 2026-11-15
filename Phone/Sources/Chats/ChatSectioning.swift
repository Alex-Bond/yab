import Foundation

/// Your chats, as New Tab's Chats page lists them, and search, quick for
/// two thousand chats: one pass to section, a cached lowercase text per
/// chat to search.
@MainActor
enum ChatSectioning {
    struct Section {
        var title: String
        var chats: [Chat]
    }

    static func sections(_ all: [Chat], sheet: ChatSheet) -> [Section] {
        var pinned: [Chat] = [], today: [Chat] = [], yesterday: [Chat] = [], earlier: [Chat] = []
        for chat in all where sheet.isListed(chat) {
            if chat.pinned { pinned.append(chat); continue }
            switch chat.day {
            case .today: today.append(chat)
            case .yesterday: yesterday.append(chat)
            case .earlier: earlier.append(chat)
            }
        }
        return [Section(title: "Pinned", chats: pinned), Section(title: "Today", chats: today),
                Section(title: "Yesterday", chats: yesterday), Section(title: "Earlier", chats: earlier)].filter { !$0.chats.isEmpty }
    }

    /// The rows in order without the section headings: pinned first, then
    /// by day. Within each bucket, source order stays intact, including the
    /// latest synced activity.
    static func listed(_ all: [Chat], sheet: ChatSheet) -> [Chat] {
        sections(all, sheet: sheet).flatMap(\.chats)
    }

    // MARK: - projects

    /// A card on the Chats page: a chat on its own, or a project not
    /// pinned, as a group among them at its newest chat's place.
    enum Card: Identifiable {
        case chat(Chat)
        case project(ChatProject, [Chat])

        var id: String {
            switch self {
            case let .chat(chat): chat.id
            case let .project(project, _): project.id
            }
        }
    }

    /// The listed chats split by project: those on their own, and each
    /// known project's (a chat of a project this iPhone doesn't have, or an
    /// archived one, stays on its own, so nothing is ever out of sight).
    static func byProject(_ listed: [Chat], projects: [ChatProject]) -> (loose: [Chat], within: [ChatProject.ID: [Chat]]) {
        let known = Set(projects.filter { !$0.archived }.map(\.id))
        var loose: [Chat] = [], within: [ChatProject.ID: [Chat]] = [:]
        for chat in listed {
            if let project = chat.project, known.contains(project) { within[project, default: []].append(chat) }
            else { loose.append(chat) }
        }
        return (loose, within)
    }

    /// The person's own cards: their chats and the projects not pinned, each
    /// project where its newest chat stands in `listed`; one with no chats
    /// yet at the end.
    static func cards(_ yours: [Chat], listed: [Chat], projects: [ChatProject], within: [ChatProject.ID: [Chat]]) -> [Card] {
        var rank: [String: Int] = [:]
        for (index, chat) in listed.enumerated() where rank[chat.id] == nil { rank[chat.id] = index }
        var out: [(Int, Card)] = yours.map { (rank[$0.id] ?? Int.max, .chat($0)) }
        for project in projects where !project.pinned && !project.archived {
            let chats = within[project.id] ?? []
            let place = chats.compactMap { rank[$0.id] }.min() ?? Int.max
            out.append((place, .project(project, chats)))
        }
        // Stable: equal places keep their order (projects with no chats, last).
        return out.enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }.map(\.element.1)
    }

    /// Chats whose title, status words or messages hold `query`, listed and
    /// archived alike (quick answers never continued are not chats yet).
    static func search(_ query: String, in all: [Chat], sheet: ChatSheet, app: AppModel) -> [Chat] {
        let words = query.lowercased()
        guard !words.isEmpty else { return [] }
        let visible = all.filter { app.chats.isVisible($0.id) }
        let listed = visible.filter { sheet.isListed($0) }
        let archived = visible.filter(\.archived)
        // Foundation's search over each chat's cached lowercase words: a few
        // milliseconds for two thousand long chats.
        return (listed + archived).filter { text(of: $0, app: app).range(of: words, options: .literal).location != NSNotFound }
    }

    /// Each chat's words, kept while the chat says the same: a typing turn
    /// replaced by its answer in place, or a task's next step, is read again.
    private struct Cached {
        var count: Int
        var title: String
        var last: Message?
        var task: String
        var text: NSString
    }

    private static var cache: [Chat.ID: Cached] = [:]

    private static func text(of chat: Chat, app: AppModel) -> NSString {
        // A chat's status words come from its messages; a task's from its run.
        let task = chat.task.flatMap { app.tasks.run($0) }.map { "\($0.status) \($0.step)" } ?? ""
        if let hit = cache[chat.id], hit.count == chat.messages.count, hit.title == chat.title,
           hit.last == chat.messages.last, hit.task == task {
            return hit.text
        }
        let words = ([chat.title, ChatWords.status(chat, app: app).text] + chat.messages.map(\.plain)).joined(separator: " ").lowercased() as NSString
        cache[chat.id] = Cached(count: chat.messages.count, title: chat.title, last: chat.messages.last, task: task, text: words)
        return words
    }
}
