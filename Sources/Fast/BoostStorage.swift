import Foundation

/// A plugin's own JSON, shared by its service (`storage` in a tick) and its
/// pages (`chrome.yab.storage`). A page's set merges its keys in; one made
/// while a tick runs is laid again over what the tick saves, so the tick
/// never writes back a copy older than the person's edit.
@MainActor
enum BoostStorage {
    static let limit = 64_000
    private static var ticking: Set<String> = []
    private static var edits: [String: [String: Any]] = [:]

    static func key(_ id: String) -> String { "boosts.service." + id + ".state" }

    /// Said with the plugin's id each time its state is saved, for sync.
    static let changed = Notification.Name("yab.boosts.state")

    static func scopedID(_ id: String, in signIn: UUID?) -> String {
        signIn.map { id + ".profile." + $0.uuidString } ?? id
    }
    static func get(_ id: String, in signIn: UUID?) -> [String: Any] { get(scopedID(id, in: signIn)) }
    @discardableResult
    static func set(_ id: String, _ changes: [String: Any], in signIn: UUID?) throws -> [String: Any] {
        try set(scopedID(id, in: signIn), changes)
    }

    static func get(_ id: String) -> [String: Any] {
        Store.settings.string(forKey: key(id)).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
    }

    /// Keys from `changes` over `state`; a null removes its key.
    nonisolated static func merge(_ changes: [String: Any], into state: [String: Any]) throws -> [String: Any] {
        var out = state
        for (key, value) in changes {
            guard !key.isEmpty, key.count <= 200 else { throw BoostPackage.Invalid("Storage keys are 1 to 200 characters.") }
            if value is NSNull { out.removeValue(forKey: key) } else { out[key] = value }
        }
        guard JSONSerialization.isValidJSONObject(out),
              let data = try? JSONSerialization.data(withJSONObject: out), data.count <= limit else {
            throw BoostPackage.Invalid("A plugin keeps at most 64 KB of JSON.")
        }
        return out
    }

    private static func save(_ id: String, _ state: [String: Any]) {
        Store.settings.set(BoostScript.json(state), forKey: key(id))
        NotificationCenter.default.post(name: changed, object: id)
    }

    /// The state another Mac has (sync), laid in as a page's set is: a
    /// tick running here now keeps it over its own copy.
    static func adopt(_ id: String, _ json: String) {
        guard json != Store.settings.string(forKey: key(id)),
              let state = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return }
        var changes = state
        for key in get(id).keys where state[key] == nil { changes[key] = NSNull() }
        _ = try? set(id, changes)
    }

    /// A page's set: saved at once, and kept to lay over the running tick's.
    @discardableResult
    static func set(_ id: String, _ changes: [String: Any]) throws -> [String: Any] {
        let state = try merge(changes, into: get(id))
        save(id, state)
        // Nulls stay in the edits, to remove the key from the tick's copy too.
        if ticking.contains(id) { edits[id] = (edits[id] ?? [:]).merging(changes) { $1 } }
        return state
    }

    /// The JSON a tick starts from.
    static func begin(_ id: String) -> String {
        ticking.insert(id); edits[id] = nil
        return Store.settings.string(forKey: key(id)) ?? "{}"
    }

    /// The tick's storage, with what pages set meanwhile over it; nil when
    /// the tick failed, which leaves the saved state as it is.
    static func end(_ id: String, storage: [String: Any]?) {
        defer { ticking.remove(id); edits[id] = nil }
        guard let storage else { return }
        let state = (try? merge(edits[id] ?? [:], into: storage)) ?? get(id)
        if (try? merge([:], into: state)) != nil { save(id, state) }
    }
}
