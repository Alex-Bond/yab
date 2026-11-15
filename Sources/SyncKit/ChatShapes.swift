import CryptoKit
import Foundation

// Chats that run on a Mac, words for them from another device, and what a
// device says of itself while its line is up, as plain values
// (docs/sync.md, "Chats and words from the iPhone").

// MARK: - Chats

/// A chat with Claude or ChatGPT that runs on one Mac: an agent's chat in Yab
/// (`a:<id>`). Its steps are SyncChatItems.
public struct SyncChat: Equatable, Sendable, Identifiable {
    public var id: String
    /// "agent".
    public var kind: String
    /// The Mac that runs it: words for it go to this device.
    public var device: String
    public var title: String
    /// "running", "done" or "failed".
    public var state: String
    /// Its last answer, up to 4000 characters.
    public var answer: String
    /// "claude" or "codex".
    public var cli: String
    public var model: String?
    /// How hard its agent thinks now ("high"…); absent: the agent's own.
    public var effort: String? = nil
    public var started: Double
    public var updated: Double
    public var pinned: Bool
    public var archived: Bool
    public var unread: Bool
    /// Still in sync. A chat that left it (older than two weeks and not
    /// pinned) is shown from what it last said.
    public var synced: Bool
    /// Who began it: the person (nil, as every older Mac says), or
    /// "agent" (an outside agent's task), "routine" or "cli" (a command).
    public var origin: String?
    /// The routine whose run it is, for one row per routine.
    public var routine: String?
    /// The project it is in (SyncProject's id), absent for a chat on its
    /// own. A phone moves a chat by writing this field (ChatProjects).
    public var project: String? = nil
    /// What it waits for you to pick from now (its question is its last
    /// message, ChatItem.question); written only while it is going, so
    /// read only then (`asks`). An answer in words picks too (SyncCenter.say).
    public var choices: [String] = []
    /// The states of a chat still going: it waits on you while it asks.
    public static let going: Set<String> = ["starting", "running", "waiting", "signing-in"]
    /// What it asks you to pick from, if it is still going.
    public var asks: [String] { Self.going.contains(state) ? choices : [] }

    /// What `origin` says.
    public enum Origin: String, Sendable { case agent, routine, cli }

    public init(id: String, kind: String = "agent", device: String, title: String, state: String, answer: String, cli: String,
                model: String? = nil, started: Double, updated: Double, pinned: Bool = false, archived: Bool = false, unread: Bool = false,
                origin: String? = nil, routine: String? = nil) {
        self.id = id; self.kind = kind; self.device = device; self.title = title; self.state = state; self.answer = answer
        self.cli = cli; self.model = model; self.started = started; self.updated = updated
        self.pinned = pinned; self.archived = archived; self.unread = unread; synced = true
        self.origin = origin; self.routine = routine
    }

    /// Reads what it last said even once it left sync: a removal keeps the
    /// fields as they were.
    public init?(_ record: Record) {
        let f = record.alive() ? record.visible : record.fields.filter { !$0.value.isNull }
        guard let device = f["device"]?.string, record.id.hasPrefix("a:"),
              f["kind"]?.string == nil || f["kind"]?.string == "agent" else { return nil }
        id = record.id
        kind = "agent"
        self.device = device
        title = f["title"]?.string ?? ""
        state = f["state"]?.string ?? "done"
        answer = f["answer"]?.string ?? ""
        cli = f["cli"]?.string ?? "claude"
        model = f["model"]?.string
        effort = f["effort"]?.string
        started = f["started"]?.number ?? 0
        updated = f["updated"]?.number ?? started
        pinned = f["pinned"]?.bool == true
        archived = f["archived"]?.bool == true
        unread = f["unread"]?.bool == true
        synced = record.alive()
        origin = f["origin"]?.string
        routine = f["routine"]?.string
        project = f["project"]?.string
        choices = f["choices"]?.array?.compactMap(\.string) ?? []
    }

    /// As the Mac writes a chat's head (SyncChats.head): what a list of
    /// chats shows, its last answer cut to 4000 characters.
    public var fields: SyncFields {
        var out: SyncFields = [
            "kind": .string(kind),
            "device": .string(device),
            "title": .string(title),
            "state": .string(state),
            "answer": .string(String(answer.prefix(4000))),
            "cli": .string(cli),
            "model": Value(model),
            "started": .number(started),
            "updated": .number(updated),
            "pinned": pinned ? .bool(true) : .null,
            "archived": archived ? .bool(true) : .null,
            "unread": unread ? .bool(true) : .null,
        ]
        // Only when said: a person's chat is written as before (SyncWireTests).
        if let origin { out["origin"] = .string(origin) }
        if let routine { out["routine"] = .string(routine) }
        if let project { out["project"] = .string(project) }
        if let effort { out["effort"] = .string(effort) }
        // Only while it runs, cleared as the pick is made; a chat done is
        // written as before, and a phone reads choices only while it runs.
        if Self.going.contains(state) { out["choices"] = choices.isEmpty ? .null : .array(choices.map(Value.string)) }
        return out
    }
}

/// One step of a chat: what was asked, an answer, a tool, a command...
/// A row of Now handed to the agent (Do It), as its chat shows it over
/// "Do It": the row's words, what is under them, and where it came from.
/// It goes with the message as one line of the item's `detail`
/// ("w:" and four fields apart by tabs), so the Mac and the iPhone draw the
/// same card from the same line.
public struct SyncHanded: Equatable, Hashable, Sendable, Codable {
    /// The site its icon is, or empty for mail and Yab's own.
    public var host: String
    public var title: String
    public var detail: String
    /// "From Now · 3 Gmail threads".
    public var from: String

    public init(host: String, title: String, detail: String, from: String) {
        self.host = host; self.title = title; self.detail = detail; self.from = from
    }

    static let mark = "w:"

    /// Its line in a message's detail: no tab or line break inside a field.
    public var label: String {
        let clean = { (words: String) in words.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
        return Self.mark + [host, title, detail, from].map(clean).joined(separator: "\t")
    }

    /// The card a message's detail carries, if it carries one.
    public static func parse(_ detail: String) -> SyncHanded? {
        guard let line = detail.split(separator: "\n").first(where: { $0.hasPrefix(mark) }) else { return nil }
        let parts = line.dropFirst(mark.count).split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, !parts[1].isEmpty else { return nil }
        return SyncHanded(host: parts[0], title: parts[1], detail: parts[2], from: parts[3])
    }
}

public struct SyncChatItem: Equatable, Sendable, Identifiable {
    /// `<chat id>/<item id>`.
    public var id: String
    public var chat: String
    /// Its place in the chat: steps before the last 150 are not synced.
    public var n: Int
    /// asked, message, thinking, tool, command, edit, plan, subagent, chose.
    public var kind: String
    public var name: String
    public var detail: String
    public var text: String
    /// running, done or failed.
    public var state: String
    public var began: Double?
    public var ended: Double?

    /// How many of a chat's last steps sync. 150 of them, with a command's
    /// whole output, filled an account's 50 MB on 2026-10-10 (180 chats,
    /// 19,521 steps, 40 MB, 26 of it commands' output): sync stopped, and
    /// the iPhone's words never reached the Mac.
    public static let kept = 80

    /// How much of a step's words sync: a command's last lines (what the
    /// iPhone shows of it), a thought's or a tool's start, the rest longer.
    public static func cut(_ text: String, kind: String) -> String {
        switch kind {
        case "command": text.count > 1500 ? "\u{2026}" + String(text.suffix(1500)) : text
        case "thinking", "tool": String(text.prefix(2000))
        default: String(text.prefix(8000))
        }
    }

    public init(id: String, chat: String, n: Int, kind: String, name: String = "", detail: String = "", text: String = "",
                state: String, began: Double? = nil, ended: Double? = nil) {
        self.id = id; self.chat = chat; self.n = n; self.kind = kind; self.name = name; self.detail = detail; self.text = text
        self.state = state; self.began = began; self.ended = ended
    }

    /// Yab's own words to the agent after Mac access was allowed: part of
    /// the turn, not something you said (ChatItem.isInternalContinuation).
    public var isInternal: Bool {
        kind == "asked" && text.hasPrefix("Mac access was allowed for this task. Continue the original request: ")
    }

    public init?(_ record: Record) {
        let f = record.alive() ? record.visible : record.fields.filter { !$0.value.isNull }
        guard let chat = f["chat"]?.string else { return nil }
        id = record.id
        self.chat = chat
        n = Int(f["n"]?.number ?? 0)
        kind = f["kind"]?.string ?? "message"
        name = f["name"]?.string ?? ""
        detail = f["detail"]?.string ?? ""
        text = f["text"]?.string ?? ""
        state = f["state"]?.string ?? "done"
        began = f["began"]?.number
        ended = f["ended"]?.number
    }

    /// As the Mac writes a step (SyncChats.items), its words cut short.
    public var fields: SyncFields {
        [
            "chat": .string(chat),
            "n": .number(Double(n)),
            "kind": .string(kind),
            "name": .string(String(name.prefix(200))),
            "detail": .string(String(detail.prefix(500))),
            "text": .string(Self.cut(text, kind: kind)),
            "state": .string(state),
            "began": Value(began),
            "ended": Value(ended),
        ]
    }
}

/// Words from this iPhone for a chat on a Mac, or for a new one there. The
/// Mac named in `device` says them in the chat as if typed there and marks
/// the record: taken, failed (with a reason) or expired (12 hours late).
public struct SyncSend: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case agent, open }
    public enum State: Equatable, Sendable { case waiting, taken, failed(String), expired, cancelled }

    public var id: String
    public var device: String
    /// The chat they go into; nil for a new one (until the Mac names the
    /// chat it started).
    public var chat: String?
    public var text: String
    /// An answer to the chat's question by its number, instead of words.
    public var choice: Int?
    /// For a new chat.
    public var kind: Kind?
    public var project: String?
    /// An explicitly requested provider for a new agent chat.
    public var cli: String?
    /// An explicit web URL for Open on Mac, never an agent prompt.
    public var url: String?
    public var at: Double
    public var state: State
    public var took: Double?
    /// Correlation owned by the sending iPhone. Older Macs ignore these
    /// extra fields and preserve them when marking the send as taken.
    public var clientChat: String?
    public var clientDevice: String?
    public var question: String?
    /// Instead of words, what to do to the chat: "stop" its run or
    /// "delete" it, sent only to a Mac whose `chatControl` names it.
    public var action: Action?
    /// Photos and files attached to the words, their bytes in `sendpart`
    /// records; sent only to a Mac whose capability says `attachments`.
    public var files: [SyncSendFile] = []
    /// The model and effort picked for these words (ModelPick): a new chat
    /// starts on them, a chat switches to them before it hears the words.
    /// Sent only to a Mac whose capability says `modelPick`.
    public var model: String?
    public var effort: String?

    public enum Action: String, Sendable { case stop, delete }

    public init?(_ record: Record) {
        guard record.alive(), let device = record["device"]?.string else { return nil }
        id = record.id
        self.device = device
        chat = record["chat"]?.string
        text = record["text"]?.string ?? record["agentText"]?.string ?? ""
        let choiceField = record["choice"]
        choice = SyncChoice.index(choiceField)
        kind = record["kind"]?.string.flatMap(Kind.init(rawValue:))
        project = record["project"]?.string
        cli = record["cli"]?.string
        url = record["url"]?.string
        at = record["at"]?.number ?? 0
        took = record["took"]?.number
        clientChat = record["clientChat"]?.string
        clientDevice = record["clientDevice"]?.string
        question = record["question"]?.string
        action = record["action"]?.string.flatMap(Action.init(rawValue:))
        files = SyncSendFile.list(record["files"])
        model = record["model"]?.string
        effort = record["effort"]?.string
        if (choiceField != nil && choice == nil) || record["answerIndex"] != nil || record["choiceQuestion"] != nil {
            state = .failed(SyncChoice.invalidReason)
            return
        }
        switch record["state"]?.string {
        case "taken"?: state = .taken
        case "failed"?: state = .failed(record["reason"]?.string ?? "")
        case "expired"?: state = .expired
        // Taken back on the phone while it still waited (Don't Send, Ask
        // on another Mac): a Mac's consume passes over any state but none.
        case "cancelled"?: state = .cancelled
        default: state = .waiting
        }
    }

    /// What the iPhone writes: only what it knows, the Mac adds the rest.
    public static func fields(device: String, chat: String?, text: String?, choice: Int?, kind: Kind?, project: String?, at: Double, agent: ChatAgent? = nil,
                              action: Action? = nil, files: [SyncSendFile] = [], model: String? = nil, effort: String? = nil) -> SyncFields {
        var out: SyncFields = ["device": .string(device), "at": .number(at)]
        if let model, !model.isEmpty { out["model"] = .string(model) }
        if let effort, !effort.isEmpty { out["effort"] = .string(effort) }
        if let action { out["action"] = .string(action.rawValue) }
        if !files.isEmpty { out["files"] = .array(files.map(\.value)) }
        if let chat { out["chat"] = .string(chat) }
        // Older Macs ignore the explicit-agent envelope rather than using their default.
        if let text, !text.isEmpty { out[agent == nil ? "text" : "agentText"] = .string(text) }
        // A new chat with an agent chosen and only files: its envelope still says so.
        else if agent != nil, !files.isEmpty { out["agentText"] = .string("") }
        if let choice { out["choice"] = .number(Double(choice)) }
        if let kind { out["kind"] = .string(kind.rawValue) }
        if let project { out["project"] = .string(project) }
        if let agent { out["cli"] = .string(agent.rawValue) }
        return out
    }
}

// MARK: - Attachments

/// A photo or file an iPhone attached to its words for a Mac's chat. Its
/// bytes travel as `sendpart` records of at most `partSize` bytes each,
/// named `<send id>/<file index>/<n>`, written before the send itself; the
/// Mac puts the file together once every part is there (checking `size`
/// and `digest`, a SHA-256 in hex), attaches it as the Mac's own chat
/// attaches a file, and the iPhone removes the parts once the send is taken,
/// failed or expired.
public struct SyncSendFile: Equatable, Sendable {
    /// What a part holds at most, before base64: as a plugin's parts.
    public static let partSize = 48_000
    /// The most one file may be, and all of one send's together.
    public static let most = 10_000_000, mostTogether = 20_000_000, mostCount = 10

    /// The file's name as the Mac will save it (no folders).
    public var name: String
    /// Its MIME type, "image/jpeg" for a photo.
    public var type: String
    public var size: Int
    public var digest: String
    /// Its parts' record ids, in order.
    public var parts: [String]

    public init(name: String, type: String, size: Int, digest: String, parts: [String]) {
        self.name = name; self.type = type; self.size = size; self.digest = digest; self.parts = parts
    }

    public var value: Value {
        .object(["name": .string(name), "type": .string(type), "size": .number(Double(size)), "digest": .string(digest),
                 "parts": .array(parts.map(Value.string))])
    }

    public init?(_ value: Value) {
        guard let o = value.object, let name = o["name"]?.string, let size = o["size"]?.number, let digest = o["digest"]?.string,
              let parts = o["parts"]?.array?.compactMap(\.string), !parts.isEmpty else { return nil }
        let clean = (name as NSString).lastPathComponent
        guard !clean.isEmpty, clean != ".", clean != "..", size.isFinite, size >= 0, size <= Double(Self.most),
              size == size.rounded() else { return nil }
        self.init(name: clean, type: o["type"]?.string ?? "application/octet-stream", size: Int(size), digest: digest, parts: parts)
    }

    static func list(_ value: Value?) -> [SyncSendFile] {
        Array((value?.array ?? []).compactMap(SyncSendFile.init).prefix(mostCount))
    }

    /// What a Mac names in its capability record (collection `commandcap`)
    /// when it takes files with words: an iPhone attaches them only then.
    public static let capability = "attachments", version = 1

    public static func supports(_ record: Record?, device: String) -> Bool {
        guard let record, record.collection == OpenOnMac.capability,
              record.id == device, record.alive(), record["device"]?.string == device else { return false }
        return record[capability]?.number == Double(version)
    }

    /// A send's files as a Mac takes them: none when the field isn't
    /// there, nil when it is but isn't what an iPhone writes (a file it
    /// can't read, too many or too much, parts that aren't the send's own
    /// or don't add up to the file's size).
    public static func read(_ value: Value?, send: String) -> [SyncSendFile]? {
        guard let value, !value.isNull else { return [] }
        guard let items = value.array, items.count <= mostCount else { return nil }
        var files: [SyncSendFile] = []
        for (index, item) in items.enumerated() {
            guard let file = SyncSendFile(item), file.parts.count == max(1, (file.size + partSize - 1) / partSize),
                  file.parts.allSatisfy({ $0.hasPrefix("\(send)/\(index)/") }) else { return nil }
            files.append(file)
        }
        guard files.reduce(0, { $0 + $1.size }) <= mostTogether else { return nil }
        return files
    }

    /// The part records' ids and fields for a file's bytes.
    public static func parts(of data: Data, send: String, index: Int) -> [(id: String, fields: SyncFields)] {
        stride(from: 0, to: max(data.count, 1), by: partSize).enumerated().map { n, start in
            let piece = data.subdata(in: start..<min(start + partSize, data.count))
            return ("\(send)/\(index)/\(n)", ["send": .string(send), "data": .string(piece.base64EncodedString())])
        }
    }

    /// What a file's parts make: its bytes, not all there yet, or not
    /// what was sent (a part that isn't one, the wrong size or digest).
    public enum Assembly: Equatable, Sendable {
        case data(Data)
        case missing
        case wrong
    }

    /// Whether every part's record is there, read or not.
    public func arrived(_ part: (String) -> Record?) -> Bool {
        parts.allSatisfy { part($0)?.alive() == true }
    }

    /// The file's bytes from its parts' records (SyncCollection.sendPart).
    public func assembled(_ part: (String) -> Record?) -> Assembly {
        guard arrived(part) else { return .missing }
        var data = Data()
        for id in parts {
            guard let encoded = part(id)?["data"]?.string, let piece = Data(base64Encoded: encoded),
                  piece.count <= Self.partSize else { return .wrong }
            data.append(piece)
            if data.count > size { return .wrong }
        }
        guard data.count == size, Self.hex(data) == digest.lowercased() else { return .wrong }
        return .data(data)
    }

    /// The file's bytes from its parts' records, or nil while one is missing
    /// or when what came isn't what was sent.
    public func assemble(_ part: (String) -> Record?) -> Data? {
        if case .data(let data) = assembled(part) { return data }
        return nil
    }

    /// SHA-256 in lowercase hex.
    public static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Presence

/// What a device says of itself about once a minute while its line is up:
/// never stored by the server, relayed to the others.
public struct SyncPresence: Equatable, Sendable {
    public var device: String
    public var name: String
    /// When it said it, seconds since 1970.
    public var at: Double
    /// The tab in front on that Mac: its address, title and tab record id.
    public var url: String?
    public var title: String?
    public var tab: String?
    /// How far down that tab's page is, 0 at the top and 1 at the end:
    /// the iPhone opening the same tab starts there, once. Optional; Macs
    /// say it from R9 on (sync-ios.md).
    public var scroll: Double?
    /// The Mac said it is going to sleep (R9): asleep at once, without
    /// waiting for its line to go quiet.
    public var asleep: Bool
    /// Why it said asleep: `sleep` (the Mac went to sleep) or `quit` (Yab
    /// on it quit). Older Macs say neither; read as sleep.
    public var why: String?
    /// What this iPhone says for a Mac's From iPhone (PhoneFront): the space
    /// its tab in front is in, as sync names it, and when that page came in
    /// front here or was last left.
    public var space: String?
    public var changed: Double?

    public init(device: String, name: String, at: Double, url: String? = nil, title: String? = nil, tab: String? = nil,
                scroll: Double? = nil, asleep: Bool = false, why: String? = nil, space: String? = nil, changed: Double? = nil) {
        self.device = device; self.name = name; self.at = at; self.url = url; self.title = title; self.tab = tab
        self.scroll = scroll; self.asleep = asleep; self.why = why; self.space = space; self.changed = changed
    }

    public init(device: String, record: Record) {
        let scroll = record["scroll"]?.number
        self.init(device: device, name: record["name"]?.string ?? "", at: record["at"]?.number ?? 0,
                  url: record["url"]?.string, title: record["title"]?.string, tab: record["tab"]?.string,
                  scroll: scroll.map { min(1, max(0, $0)) }, asleep: record["asleep"]?.bool == true,
                  why: record["why"]?.string)
    }

    public var record: Record {
        var fields: SyncFields = ["name": .string(name), "at": .number(at), "kind": "iphone"]
        if let url { fields["url"] = .string(url) }
        if let title { fields["title"] = .string(title) }
        if let tab { fields["tab"] = .string(tab) }
        if let scroll { fields["scroll"] = .number(scroll) }
        // Only with a page to offer: a Mac reads its From iPhone from these.
        if url != nil, let changed {
            fields.merge(PhoneFront.fields(space: space, changed: Date(timeIntervalSince1970: changed))) { _, new in new }
        }
        return Record(collection: SyncCollection.presence, id: device, fields: fields)
    }
}
