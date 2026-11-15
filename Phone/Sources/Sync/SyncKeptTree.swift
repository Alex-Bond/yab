import Foundation
#if canImport(SyncKit)
import SyncKit
#endif

/// The Mac's `folder` field is a folder's parent, never its owning space.
/// Malformed edges stop here; every direct tab still occurs exactly once.
enum SyncKeptTree {
    indirect enum Node {
        case tab(SyncTab)
        case folder(SyncFolder, [Node])

        var tabs: [SyncTab] {
            switch self {
            case let .tab(tab): return [tab]
            case let .folder(_, children): return children.flatMap(\.tabs)
            }
        }
    }

    static func make(_ row: SyncRow) -> [Node] {
        let attached = Set(row.kept.compactMap(\.folder))
        let folders = row.folders.filter { _, folder in
            folder.space == row.space && (folder.search == nil && folder.today != true || attached.contains(folder.id))
        }
        var parent: [String: String] = [:]
        for folder in folders.values {
            guard folder.search == nil, folder.today != true, let up = folder.folder,
                  let owner = folders[up], owner.search == nil, owner.today != true, up != folder.id else { continue }
            parent[folder.id] = up
        }
        // Resolve each edge against the original graph, so record enumeration
        // cannot change the repair. Too-deep or cyclic paths become roots.
        let original = parent
        for id in folders.keys {
            var seen: Set<String> = [id]
            var here = id
            while let up = original[here] {
                guard seen.insert(up).inserted, seen.count <= KeptTree.deepest else {
                    parent[id] = nil
                    break
                }
                here = up
            }
        }
        struct Entry {
            var id: String
            var order: String
            var node: Node
        }
        func level(_ owner: String?) -> [Node] {
            var entries: [Entry] = []
            for folder in folders.values where parent[folder.id] == owner {
                let children = level(folder.id)
                let order = folder.order ?? children.flatMap(\.tabs).compactMap(\.order).min() ?? "\u{10FFFF}"
                entries.append(Entry(id: "folder:" + folder.id, order: order, node: .folder(folder, children)))
            }
            for tab in row.kept {
                let direct = tab.folder.flatMap { folders[$0] == nil ? nil : $0 }
                if direct == owner {
                    entries.append(Entry(id: "tab:" + tab.id, order: tab.order ?? "", node: .tab(tab)))
                }
            }
            return entries.sorted { ($0.order, $0.id) < ($1.order, $1.id) }.map(\.node)
        }
        return level(nil)
    }
}
