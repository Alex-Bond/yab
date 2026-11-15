import Foundation

// One thing that syncs: a tab, a space, a bookmark, a setting. A bag of
// fields, each with the stamp of its last change, and the stamp of its
// removal if it was removed. Two copies of a record merge field by field,
// in any order, any number of times, to the same result on every device.

public struct Record: Codable, Hashable, Sendable {
    public var collection: String
    public var id: String
    public var fields: [String: Value]
    public var stamps: [String: Stamp]
    /// When it was removed. Kept for good: a removal forgotten is a record
    /// that comes back from a device that was away.
    public var deleted: Stamp?
    /// The shape of the fields, for a later Yab that changes one.
    public var schema: Int

    public init(collection: String, id: String, fields: [String: Value] = [:], stamps: [String: Stamp] = [:], deleted: Stamp? = nil, schema: Int = 1) {
        self.collection = collection
        self.id = id
        self.fields = fields
        self.stamps = stamps
        self.deleted = deleted
        self.schema = schema
    }

    public var key: Key { Key(collection: collection, id: id) }

    /// The newest change to anything in it.
    public var latest: Stamp? {
        ([deleted].compactMap { $0 } + stamps.values).max()
    }

    public struct Key: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
        public var collection: String
        public var id: String
        public init(collection: String, id: String) { self.collection = collection; self.id = id }
        public static func < (a: Key, b: Key) -> Bool { (a.collection, a.id) < (b.collection, b.id) }
        public var description: String { "\(collection)/\(id)" }
    }
}

// MARK: - Kinds

/// How a collection's records merge.
public struct Kind: Sendable {
    public enum Rule: Sendable {
        /// The latest change wins.
        case last
        /// The larger number wins, whoever wrote it: when a tab was last
        /// seen is the latest of the devices that saw it.
        case most
        /// An object of a number per device; each device's part is its
        /// own, and the field's worth is their sum (`Record.total`).
        case perDevice
    }

    public var name: String
    /// A removal beats any change made to the record, before or after: a
    /// tab closed on one Mac stays closed though another moved it on.
    /// Otherwise a change made after the removal brings the record back.
    public var removalWins: Bool
    public var rules: [String: Rule]
    /// Fields that only mean something together, such as where a thing
    /// stands (`parent` and `order`): the newest change to any of them
    /// brings all of them.
    public var groups: [[String]]

    public init(_ name: String, removalWins: Bool = false, rules: [String: Rule] = [:], groups: [[String]] = []) {
        self.name = name
        self.removalWins = removalWins
        self.rules = rules
        self.groups = groups
    }

    public static let place = ["parent", "order"]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var known: [String: Kind] = [:]

    /// Makes a collection's rules known. Collections never registered merge
    /// as plain latest-wins, which is also what keeps a newer Yab's
    /// collections intact in an older one.
    public static func register(_ kind: Kind) {
        lock.lock(); defer { lock.unlock() }
        known[kind.name] = kind
    }

    public static func of(_ collection: String) -> Kind {
        lock.lock(); defer { lock.unlock() }
        return known[collection] ?? Kind(collection)
    }
}

// MARK: - Reading

public extension Record {
    /// Whether the record is there, as opposed to removed.
    func alive(_ kind: Kind? = nil) -> Bool {
        guard let deleted else { return true }
        if (kind ?? Kind.of(collection)).removalWins { return false }
        return stamps.values.contains { $0 > deleted }
    }

    /// The fields as they stand: a record brought back after a removal
    /// shows only what was set after it.
    var visible: [String: Value] {
        guard let deleted else { return fields.filter { !$0.value.isNull } }
        return fields.filter { name, value in
            !value.isNull && (stamps[name].map { $0 > deleted } ?? false)
        }
    }

    subscript(_ field: String) -> Value? { visible[field] }

    /// A per-device field's worth: every device's part added up.
    func total(_ field: String) -> Double {
        (visible[field]?.object ?? [:]).values.compactMap(\.number).reduce(0, +)
    }
}

// MARK: - Changing

public extension Record {
    mutating func set(_ field: String, _ value: Value, at stamp: Stamp) {
        fields[field] = value
        stamps[field] = stamp
    }

    mutating func remove(at stamp: Stamp) {
        if deleted.map({ stamp > $0 }) ?? true { deleted = stamp }
    }

    /// Makes the record say `want`, stamping only the fields that differ
    /// with one stamp from `clock`, and clearing those no longer there.
    /// Returns whether anything changed. A per-device field is given as
    /// this device's part alone and merged into the others' parts.
    @discardableResult
    mutating func update(to want: [String: Value], clock: Clock, kind: Kind? = nil) -> Bool {
        let kind = kind ?? Kind.of(collection)
        let now = visible
        var changes: [String: Value] = [:]
        for (name, value) in want where !value.isNull {
            if kind.rules[name] == .perDevice {
                // The whole object handed back as it stands is no change.
                if value == now[name] { continue }
                var parts = now[name]?.object ?? [:]
                guard parts[clock.device] != value else { continue }
                parts[clock.device] = value
                changes[name] = .object(parts)
            } else if now[name] != value {
                changes[name] = value
            }
        }
        for name in now.keys where want[name] == nil || want[name] == .null {
            changes[name] = .null
        }
        let wasGone = !alive(kind)
        guard !changes.isEmpty || wasGone else { return false }
        if wasGone && kind.removalWins { return false }
        let stamp = clock.tick()
        // A change to one field of a group restamps the rest of it, so the
        // group travels as one.
        for group in kind.groups where group.contains(where: { changes[$0] != nil }) {
            for name in group where changes[name] == nil {
                changes[name] = now[name] ?? .null
            }
        }
        if wasGone {
            // Back after a removal: every field it has now counts as new.
            for (name, value) in now where changes[name] == nil { changes[name] = value }
            if changes.isEmpty { changes["_"] = true }
        }
        for (name, value) in changes { set(name, value, at: stamp) }
        return true
    }
}

// MARK: - Merging

public extension Record {
    /// This record and another copy of it, put together. Commutative,
    /// associative and idempotent: every device that has seen the same
    /// changes holds the same record, whatever order they came in.
    func merged(with other: Record, kind: Kind? = nil) -> Record {
        precondition(key == other.key, "merging \(key) with \(other.key)")
        let kind = kind ?? Kind.of(collection)
        var out = self
        out.schema = max(schema, other.schema)
        out.deleted = [deleted, other.deleted].compactMap { $0 }.max()

        var grouped = Set<String>()
        for group in kind.groups {
            grouped.formUnion(group)
            let mine = group.compactMap { stamps[$0] }.max()
            let theirs = group.compactMap { other.stamps[$0] }.max()
            guard let theirs, mine.map({ theirs > $0 }) ?? true else { continue }
            for name in group {
                out.fields[name] = other.fields[name]
                out.stamps[name] = other.stamps[name]
            }
        }

        for name in Set(other.fields.keys).union(other.stamps.keys) where !grouped.contains(name) {
            let a = stamps[name], b = other.stamps[name]
            switch kind.rules[name] ?? .last {
            case .last:
                if let b, a.map({ b > $0 }) ?? true {
                    out.fields[name] = other.fields[name]
                    out.stamps[name] = b
                }
            case .most:
                let x = fields[name]?.number, y = other.fields[name]?.number
                out.fields[name] = [x, y].compactMap { $0 }.max().map(Value.number) ?? other.fields[name] ?? fields[name]
                out.stamps[name] = [a, b].compactMap { $0 }.max()
            case .perDevice:
                var parts = fields[name]?.object ?? [:]
                for (device, value) in other.fields[name]?.object ?? [:] {
                    guard let mine = parts[device] else { parts[device] = value; continue }
                    // A device's part only grows; anything else still has
                    // to pick the same side on every device.
                    let x = mine.number ?? -.infinity, y = value.number ?? -.infinity
                    if y > x || (y == x && String(describing: value) > String(describing: mine)) { parts[device] = value }
                }
                out.fields[name] = .object(parts)
                out.stamps[name] = [a, b].compactMap { $0 }.max()
            }
        }
        return out
    }
}
