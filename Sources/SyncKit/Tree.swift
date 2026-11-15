import Foundation

// Changes made apart can leave a tree that no device made: a bookmark in a
// folder another Mac removed, two folders moved into each other. After every
// merge the tree is put right, as a structured bookmark merge does, with nothing
// dropped and no "Recovered" folder: a thing whose parent is gone goes to
// the fallback its collection names, a loop is cut where the oldest move was.

public enum Tree {
    public struct Node: Hashable, Sendable {
        public var id: String
        public var parent: String?
        public var order: String
        /// When it was last moved: the stamp of its `parent`.
        public var moved: Stamp?

        public init(id: String, parent: String?, order: String, moved: Stamp? = nil) {
            self.id = id
            self.parent = parent
            self.order = order
            self.moved = moved
        }
    }

    public struct Fix: Hashable, Sendable {
        public var id: String
        public var parent: String?
        public var order: String
    }

    /// The moves that make `nodes` a tree again. A parent outside the
    /// nodes and not in `roots` counts as gone; such a node, and the one
    /// whose move closed a loop, go to the end of `fallback` (nil: the top).
    public static func repair(_ nodes: [Node], roots: Set<String> = [], fallback: String? = nil) -> [Fix] {
        var byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var fixes: [Fix] = []
        func last(in parent: String?) -> String? {
            byID.values.filter { $0.parent == parent }.map(\.order).max()
        }
        func move(_ id: String) {
            guard var node = byID[id] else { return }
            node.parent = fallback.flatMap { byID[$0] != nil || roots.contains($0) ? $0 : nil }
            node.order = Order.between(last(in: node.parent), nil)
            byID[id] = node
            fixes.append(Fix(id: id, parent: node.parent, order: node.order))
        }

        // Orphans, in id order so every device fixes them the same way.
        for id in byID.keys.sorted() {
            guard let parent = byID[id]?.parent else { continue }
            if byID[parent] == nil && !roots.contains(parent) { move(id) }
        }

        // Loops: walk up from each node; a walk that comes back to a node
        // it passed is a loop, cut at its member moved longest ago.
        for id in byID.keys.sorted() {
            var path: [String] = []
            var seen = Set<String>()
            var at: String? = id
            while let here = at, let node = byID[here] {
                if seen.contains(here) {
                    let loop = path.drop(while: { $0 != here })
                    let oldest = loop.min { a, b in
                        let x = byID[a]?.moved, y = byID[b]?.moved
                        switch (x, y) {
                        case let (x?, y?): return x != y ? x < y : a < b
                        case (nil, _?): return true
                        case (_?, nil): return false
                        case (nil, nil): return a < b
                        }
                    }
                    if let oldest { move(oldest) }
                    break
                }
                seen.insert(here)
                path.append(here)
                at = node.parent
            }
        }

        // Two things at the same place sort by id; that is fine to read,
        // but a later insert between them would have no room, so the second
        // is given a key of its own.
        let siblings = Dictionary(grouping: byID.values, by: { $0.parent })
        for (_, group) in siblings {
            let sorted = group.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
            var previous: String?
            for (i, node) in sorted.enumerated() {
                var order = node.order
                if let previous, order <= previous {
                    let next = sorted.dropFirst(i + 1).first(where: { $0.order > previous })?.order
                    order = Order.between(previous, next)
                    byID[node.id]?.order = order
                    fixes.append(Fix(id: node.id, parent: node.parent, order: order))
                }
                previous = order
            }
        }
        return fixes
    }

    /// The nodes under `parent` in the order they stand.
    public static func children(of parent: String?, in nodes: [Node]) -> [Node] {
        nodes.filter { $0.parent == parent }.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
    }
}
