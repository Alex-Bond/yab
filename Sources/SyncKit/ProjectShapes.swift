import Foundation

// Projects of chats as they sync (docs/chat-projects.md, docs/sync.md).

/// A project of chats: a circle with an emoji, its name, its color and the
/// instructions its chats are told. Its memory and files stay on the Macs
/// in v1. Collection `project`, id `prj-…`; any device may write one, and a
/// Mac takes every field into its Projects.
public struct SyncProject: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var emoji: String
    /// One of blue, green, orange, purple, pink, yellow, teal, gray.
    public var tint: String
    /// What every chat in it is told, up to 8000 characters. Read-only on
    /// an iPhone in v1.
    public var instructions: String
    public var memoryOn: Bool
    public var pinned: Bool
    public var archived: Bool
    /// Its place among the pinned (Order).
    public var order: String
    public var created: Double
    public var updated: Double

    public init(id: String, name: String, emoji: String, tint: String, instructions: String = "", memoryOn: Bool = true,
                pinned: Bool = false, archived: Bool = false, order: String, created: Double, updated: Double) {
        self.id = id; self.name = name; self.emoji = emoji; self.tint = tint; self.instructions = instructions
        self.memoryOn = memoryOn; self.pinned = pinned; self.archived = archived; self.order = order
        self.created = created; self.updated = updated
    }

    public init?(_ record: Record) {
        guard record.collection == SyncCollection.project, record.alive(), ChatProjects.valid(record.id),
              let name = record["name"]?.string else { return nil }
        id = record.id
        self.name = name
        emoji = record["emoji"]?.string ?? ""
        tint = record["tint"]?.string ?? "blue"
        instructions = record["instructions"]?.string ?? ""
        memoryOn = record["memoryOn"]?.bool != false
        pinned = record["pinned"]?.bool == true
        archived = record["archived"]?.bool == true
        order = record["order"]?.string ?? ""
        created = record["created"]?.number ?? 0
        updated = record["updated"]?.number ?? created
    }

    public var fields: SyncFields {
        [
            "name": .string(String(name.prefix(200))),
            "emoji": .string(String(emoji.prefix(16))),
            "tint": .string(tint),
            "instructions": .string(String(instructions.prefix(8000))),
            "memoryOn": .bool(memoryOn),
            "pinned": pinned ? .bool(true) : .null,
            "archived": archived ? .bool(true) : .null,
            "order": .string(order),
            "created": .number(created),
            "updated": .number(updated),
        ]
    }

    /// Every live project in records, the pinned in their order first.
    public static func all(_ records: [Record]) -> [SyncProject] {
        records.compactMap(SyncProject.init).sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return a.pinned ? (a.order == b.order ? a.id < b.id : a.order < b.order) : a.updated > b.updated
        }
    }
}

/// Projects from the iPhone: a new chat in a project (`SyncSend.project`)
/// and a chat moved by writing its head's `project` field (null: out of
/// its project), stamped like Pin and Archive. A phone does either only
/// for a Mac that names this version in its `commandcap` as `chatProjects`:
/// an older Mac fails a send with a project and ignores the field.
public enum ChatProjects {
    public static let version = 1
    public static let field = "chatProjects"
    public static let missing = "That project isn't on this Mac any more."

    public static func supports(_ record: Record?, device: String) -> Bool {
        guard let record, record.collection == OpenOnMac.capability,
              record.id == device, record.alive(), record["device"]?.string == device else { return false }
        return record[field]?.number == Double(version)
    }

    /// A project id as a record, a send or a head carries it.
    public static func valid(_ id: String?) -> Bool {
        guard let id else { return false }
        return id.hasPrefix("prj-") && id.count > 4 && id.count <= 40 && !id.contains("/")
    }
}
