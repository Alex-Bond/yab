import Foundation
#if canImport(SyncKit)
import SyncKit
#endif

/// What sync holds of spaces and rows, as the app last took it: spaces,
/// tabs and folders by id. The bridge builds the app's spaces from it, and
/// compares the app's spaces with it to know what the iPhone changed. Kept
/// up to date by every batch, the iPhone's own included, so it always says
/// what the journal says.
nonisolated struct SyncMirror: Equatable, Sendable {
    var spaces: [String: SyncSpace] = [:]
    /// The tabs this iPhone shows: its own of today, everyone's pins and kept.
    var tabs: [String: SyncTab] = [:]
    var folders: [String: SyncFolder] = [:]
    /// The Macs' tabs of today (SyncTab.shown): never in the app's rows, so
    /// never taken for closed here when the app's rows are compared.
    var elsewhere: [String: SyncTab] = [:]
    /// This iPhone's device id; nil shows every tab (a line-less world).
    var device: String?

    init(device: String? = nil) { self.device = device }

    init(spaces: [SyncSpace], rows: [String: SyncRow], device: String? = nil) {
        self.device = device
        for space in spaces { self.spaces[space.id] = space }
        for row in rows.values {
            for tab in row.all { put(tab) }
            for tab in row.elsewhere { put(tab) }
            for (id, folder) in row.folders { folders[id] = folder }
        }
    }

    /// A tab where it belongs: shown here, or the Macs'.
    private mutating func put(_ tab: SyncTab) {
        if tab.shown(to: device, mac: false) {
            tabs[tab.id] = tab
            elsewhere[tab.id] = nil
        } else {
            elsewhere[tab.id] = tab
            tabs[tab.id] = nil
        }
    }

    var isEmpty: Bool { spaces.isEmpty && tabs.isEmpty }

    /// Takes a batch in; returns the spaces whose rows it touched.
    @discardableResult
    mutating func apply(_ changes: [SyncChange]) -> Set<String> {
        var touched = Set<String>()
        for change in changes {
            switch change {
            case let .space(space):
                spaces[space.id] = space
                touched.insert(space.id)
            case let .spaceGone(id):
                spaces[id] = nil
                touched.insert(id)
            case let .tab(tab):
                if let old = tabs[tab.id] ?? elsewhere[tab.id], old.space != tab.space { touched.insert(old.space) }
                put(tab)
                touched.insert(tab.space)
            case let .tabGone(id):
                if let old = tabs.removeValue(forKey: id) ?? elsewhere.removeValue(forKey: id) { touched.insert(old.space) }
            case let .folder(folder):
                folders[folder.id] = folder
                touched.insert(folder.space)
            case let .folderGone(id):
                if let old = folders.removeValue(forKey: id) { touched.insert(old.space) }
            default:
                break
            }
        }
        return touched
    }

    /// Spaces in their order, the Mac's.
    var orderedSpaces: [SyncSpace] {
        spaces.values.sorted { ($0.order ?? "", $0.id) < ($1.order ?? "", $1.id) }
    }

    /// A space's row the Mac's way (SyncShapes.row): tabs by place then id,
    /// split into pins, kept and today's; a tab's folder only if that
    /// folder is there.
    func row(_ space: String) -> SyncRow {
        let mine = tabs.values.filter { $0.space == space }.sorted(by: RecordShapes.placed)
        var shown: [SyncTab] = []
        let owned = folders.filter { $0.value.space == space }
        for var tab in mine {
            if let id = tab.folder, owned[id] == nil { tab.folder = nil }
            shown.append(tab)
        }
        return SyncRow(space: space, pins: shown.filter { $0.list == .pinned }, kept: shown.filter { $0.list == .kept },
                       today: shown.filter { $0.list == .today }, folders: owned,
                       elsewhere: elsewhere.values.filter { $0.space == space }.sorted(by: RecordShapes.placed))
    }
}
