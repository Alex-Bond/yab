import Foundation

/// Device-local choices, deliberately outside the synced settings allowlist.
public enum SyncCategory: String, CaseIterable, Sendable {
    case spaces, tabs, bookmarks, settings, files, chats, routines, memory

    public static let preferenceKey = "sync.disabledCategories"
    public static let replayKey = "sync.categoryReplay"

    public var collections: Set<String> {
        switch self {
        case .spaces: return [SyncCollection.space]
        case .tabs: return [SyncCollection.tab, SyncCollection.folder, SyncCollection.pair]
        case .bookmarks: return [SyncCollection.bookmark]
        case .settings: return [SyncCollection.setting]
        case .files: return [SyncCollection.file, SyncCollection.icon, SyncCollection.answer]
        // Explicit cross-device commands (send, task, approval) have their own
        // consent and are independent of copying chat history.
        case .chats: return [SyncCollection.chat, SyncCollection.chatItem, SyncCollection.project]
        case .routines: return [SyncCollection.routine]
        case .memory: return [SyncCollection.memory]
        }
    }

    public static func excluded(by disabled: Set<SyncCategory>) -> Set<String> {
        disabled.reduce(into: Set<String>()) { $0.formUnion($1.collections) }
    }
}
