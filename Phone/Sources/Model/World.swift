import CryptoKit
import Foundation

/// A test world: everything the app knows at launch, from
/// Phone/Worlds/<name>.json (launch argument -YabWorld <name>). Until the
/// iPhone joins sync (M7) every run lives in one; `mira` is the prototype's.
struct World: Codable, Sendable {
    /// Its file's name: "mira".
    var name: String
    /// Whose it is, for the words that name the person.
    var owner: String
    /// The space shown at launch.
    var space: Space.ID
    var spaces: [Space]
    /// What tasks are, and those already running.
    var taskDefinitions: [TaskDefinition]
    var tasks: [TaskRun]
    var chats: [Chat]
    /// The Mac's state: awake or asleep, and its name.
    var mac: Mac

    struct Mac: Codable, Sendable {
        var name: String
        var asleep: Bool
        /// The tab just left on the Mac, offered on the Now line for a minute
        /// ("On your Mac", the same place of the page here). None: no offer.
        var handoff: Tab.ID?
        /// False until this iPhone has joined a Mac: the first launch's world
        /// (Worlds/empty.json), where the welcome asks.
        var joined: Bool

        init(name: String = "MacBook Pro", asleep: Bool = false, handoff: Tab.ID? = nil, joined: Bool = true) {
            self.name = name
            self.asleep = asleep
            self.handoff = handoff
            self.joined = joined
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? "MacBook Pro"
            asleep = try c.decodeIfPresent(Bool.self, forKey: .asleep) ?? false
            handoff = try c.decodeIfPresent(Tab.ID.self, forKey: .handoff)
            joined = try c.decodeIfPresent(Bool.self, forKey: .joined) ?? true
        }
    }

    enum CodingKeys: String, CodingKey { case name, owner, space, spaces, taskDefinitions, tasks, chats, mac }

    init(name: String, owner: String = "", space: Space.ID, spaces: [Space], taskDefinitions: [TaskDefinition] = [],
         tasks: [TaskRun] = [], chats: [Chat] = [], mac: Mac = Mac()) {
        self.name = name
        self.owner = owner
        self.space = space
        self.spaces = spaces
        self.taskDefinitions = taskDefinitions
        self.tasks = tasks
        self.chats = chats
        self.mac = mac
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        owner = try c.decodeIfPresent(String.self, forKey: .owner) ?? ""
        spaces = try c.decode([Space].self, forKey: .spaces)
        space = try c.decodeIfPresent(Space.ID.self, forKey: .space) ?? spaces.first?.id ?? ""
        taskDefinitions = try c.decodeIfPresent([TaskDefinition].self, forKey: .taskDefinitions) ?? []
        tasks = try c.decodeIfPresent([TaskRun].self, forKey: .tasks) ?? []
        chats = try c.decodeIfPresent([Chat].self, forKey: .chats) ?? []
        mac = try c.decodeIfPresent(Mac.self, forKey: .mac) ?? Mac()
    }

    // MARK: - loading

    enum LoadError: Error, CustomStringConvertible {
        case missing(String)
        case unreadable(String, Error)
        case invalid(String, String)

        var description: String {
            switch self {
            case let .missing(name): "no world named \(name) (Worlds/\(name).json)"
            case let .unreadable(name, error): "world \(name) doesn't read: \(error)"
            case let .invalid(name, why): "world \(name) is wrong: \(why)"
            }
        }
    }

    /// Where the app keeps its worlds: Yab.app/Worlds.
    static var folder: URL? { Bundle.main.resourceURL?.appendingPathComponent("Worlds") }

    /// The names of the worlds the app carries.
    static var available: [String] {
        guard let folder, let files = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }

    static func load(named name: String) throws -> World {
        guard let url = folder?.appendingPathComponent("\(name).json"), FileManager.default.fileExists(atPath: url.path) else {
            throw LoadError.missing(name)
        }
        return try load(from: url, name: name)
    }

    static func load(from url: URL, name: String? = nil) throws -> World {
        let label = name ?? url.deletingPathExtension().lastPathComponent
        let world: World
        do {
            world = try JSONDecoder().decode(World.self, from: Data(contentsOf: url))
        } catch {
            throw LoadError.unreadable(label, error)
        }
        if let problem = world.problem { throw LoadError.invalid(label, problem) }
        return world
    }

    /// What is inconsistent in it, if anything: ids used twice, a current tab
    /// that isn't there, a task or chat naming a task nobody defined.
    var problem: String? {
        var seen = Set<String>()
        for space in spaces {
            guard seen.insert("space:" + space.id).inserted else { return "space \(space.id) twice" }
            for tab in space.allTabs {
                guard seen.insert("tab:" + tab.id).inserted else { return "tab \(tab.id) twice" }
            }
            if let current = space.current, space.tab(current) == nil { return "space \(space.id)'s current tab \(current) isn't in it" }
        }
        guard spaces.contains(where: { $0.id == space }) else { return "no space \(space) to start in" }
        let defined = Set(taskDefinitions.map(\.id))
        if let run = tasks.first(where: { !defined.contains($0.id) }) { return "task \(run.id) has no definition" }
        if let chat = chats.first(where: { $0.task.map { !defined.contains($0) } ?? false }) { return "chat \(chat.id) names an undefined task" }
        if let handoff = mac.handoff, !spaces.contains(where: { $0.tab(handoff) != nil }) { return "the Mac's handoff \(handoff) isn't a tab" }
        return nil
    }

    /// A stable id for the world's own website data, so its cookies and
    /// storage never mix with another world's or a person's.
    var dataStoreID: UUID {
        let digest = SHA256.hash(data: Data(("yab-world:" + name).utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // a name-based UUID's version
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
