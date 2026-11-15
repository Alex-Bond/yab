import Foundation

/// One ordered tree, shared by the profile, search and the actual column.
/// A folder stays when its last direct tab leaves, including empty parents.
enum KeptTree {
    static let deepest = 5

    static func tabs(_ items: [KeptItem]) -> [Tab] {
        items.flatMap { item -> [Tab] in
            switch item {
            case let .tab(tab): return [tab]
            case let .folder(folder): return tabs(folder.items)
            }
        }
    }

    /// One kept tab at any depth, found without building the tree's list:
    /// the page host asks on every SwiftUI update (crash #104).
    static func tab(_ id: Tab.ID, in items: [KeptItem]) -> Tab? {
        for item in items {
            switch item {
            case let .tab(tab): if tab.id == id { return tab }
            case let .folder(folder): if let found = Self.tab(id, in: folder.items) { return found }
            }
        }
        return nil
    }

    static func folders(_ items: [KeptItem]) -> [Folder] {
        items.flatMap { item -> [Folder] in
            guard case let .folder(folder) = item else { return [] }
            return [folder] + folders(folder.items)
        }
    }

    static func path(to tab: Tab.ID, in items: [KeptItem]) -> [Folder] {
        for item in items {
            guard case let .folder(folder) = item else { continue }
            if folder.tabs.contains(where: { $0.id == tab }) { return [folder] }
            let below = path(to: tab, in: folder.items)
            if !below.isEmpty { return [folder] + below }
        }
        return []
    }

    /// The folder holding each kept tab directly, for every tab in one walk:
    /// what `path(to:in:).last` says of one tab. Asked of `path` for each tab
    /// in turn, a sync of a space with many kept tabs copied the tree once
    /// per tab on the main thread (#547).
    static func holders(_ items: [KeptItem]) -> [Tab.ID: Folder.ID] {
        var found: [Tab.ID: Folder.ID] = [:]
        func walk(_ items: [KeptItem]) {
            for item in items {
                guard case let .folder(folder) = item else { continue }
                // Its own tabs before those of the folders in it, as `path` looks.
                for case let .tab(tab) in folder.items where found[tab.id] == nil { found[tab.id] = folder.id }
                walk(folder.items)
            }
        }
        walk(items)
        return found
    }

    static func visible(_ items: [KeptItem], current: Tab.ID?) -> [Tab] {
        items.flatMap { item -> [Tab] in
            switch item {
            case let .tab(tab): return [tab]
            case let .folder(folder):
                if folder.open { return visible(folder.items, current: current) }
                return tabs(folder.items).filter { $0.id == current }
            }
        }
    }

    @discardableResult
    static func editFolder(_ id: Folder.ID, in items: inout [KeptItem], _ edit: (inout Folder) -> Void) -> Bool {
        for i in items.indices {
            guard case var .folder(folder) = items[i] else { continue }
            if folder.id == id {
                edit(&folder)
                items[i] = .folder(folder)
                return true
            }
            if editFolder(id, in: &folder.items, edit) {
                items[i] = .folder(folder)
                return true
            }
        }
        return false
    }

    @discardableResult
    static func replace(_ id: Tab.ID, in items: inout [KeptItem], with tab: Tab) -> Bool {
        for i in items.indices {
            switch items[i] {
            case let .tab(old) where old.id == id:
                items[i] = .tab(tab)
                return true
            case var .folder(folder):
                if replace(id, in: &folder.items, with: tab) {
                    items[i] = .folder(folder)
                    return true
                }
            default: break
            }
        }
        return false
    }

    @discardableResult
    static func remove(_ id: Tab.ID, from items: inout [KeptItem]) -> Tab? {
        for i in items.indices {
            switch items[i] {
            case let .tab(tab) where tab.id == id:
                items.remove(at: i)
                return tab
            case var .folder(folder):
                if let tab = remove(id, from: &folder.items) {
                    items[i] = .folder(folder)
                    return tab
                }
            default: break
            }
        }
        return nil
    }

    static func mapTabs(_ items: inout [KeptItem], _ change: (inout Tab) -> Void) {
        for i in items.indices {
            switch items[i] {
            case var .tab(tab):
                change(&tab)
                items[i] = .tab(tab)
            case var .folder(folder):
                mapTabs(&folder.items, change)
                items[i] = .folder(folder)
            }
        }
    }

    static func excludingPrivate(_ items: [KeptItem]) -> [KeptItem] {
        items.compactMap { item in
            switch item {
            case let .tab(tab): return tab.isPrivate ? nil : .tab(tab)
            case var .folder(folder):
                folder.items = excludingPrivate(folder.items)
                return .folder(folder)
            }
        }
    }
}
