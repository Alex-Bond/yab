import Foundation
import CryptoKit

/// Page scripts go to the helper once per connection and set of scripts, and
/// each tab's scripts.install names that set. Every tab's scripts are nearly
/// all every tab's, about a megabyte, so 138 loading tabs once sent the same
/// megabyte 138 times and overran the wire. The helper keeps a set until told
/// to forget it; this side keeps at most `kept` and forgets the least recently
/// used one that no install is waiting on. A set used again after it was
/// forgotten is defined again under a new name, so a late forget can never
/// take it away. Confined to the client actor.
final class ScriptBundles {
    static let kept = 32
    var enabled = false
    private struct Bundle { let name: String; let definition: Task<Void, Error>; var users: Int }
    private var bundles: [String: Bundle] = [:]  // identity -> bundle
    private var recent: [String] = []            // identities, least recent first
    private var serial = 0

    static func identity(_ scripts: JSONValue) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(scripts)).map { String(format: "%02x", $0) }.joined()
    }

    /// The bundle for these scripts, made with `define` if there is none yet.
    func use(_ identity: String, define: (String) -> Task<Void, Error>) -> (name: String, definition: Task<Void, Error>) {
        if var bundle = bundles[identity] {
            bundle.users += 1; bundles[identity] = bundle
            touch(identity)
            return (bundle.name, bundle.definition)
        }
        serial += 1
        let name = String(identity.prefix(32)) + "-" + String(serial)
        let bundle = Bundle(name: name, definition: define(name), users: 1)
        bundles[identity] = bundle
        touch(identity)
        return (name, bundle.definition)
    }

    /// An install is done with it. Returns the names to forget, if any.
    func release(_ identity: String, failed: Bool = false) -> [String] {
        guard var bundle = bundles[identity] else { return [] }
        bundle.users -= 1
        var forget: [String] = []
        if failed && bundle.users == 0 {
            // A definition that failed is no bundle at all.
            bundles[identity] = nil; recent.removeAll { $0 == identity }
            forget.append(bundle.name)
        } else { bundles[identity] = bundle }
        var index = 0
        while bundles.count > Self.kept, index < recent.count {
            let candidate = recent[index]
            if let held = bundles[candidate], held.users == 0 {
                bundles[candidate] = nil; recent.remove(at: index)
                forget.append(held.name)
            } else { index += 1 }
        }
        return forget
    }

    func fail(_ error: Error) {
        bundles.values.forEach { $0.definition.cancel() }
        bundles.removeAll(); recent.removeAll()
    }

    var count: Int { bundles.count }

    private func touch(_ identity: String) {
        recent.removeAll { $0 == identity }
        recent.append(identity)
    }
}
