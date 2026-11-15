import Foundation

/// What the Mac's ⌘T field keeps that this iPhone's field shows too: its
/// Favorites (pages only, `field.favorites`), its Quick Actions
/// (`quick-actions.json`) and the meetings in its Now (`now` rows of kind
/// meeting). Sync fills it (Sync/PhoneSync); the field reads it (Field).
/// Empty until a Mac says otherwise; nothing here is kept on its own.
@MainActor
@Observable
final class MacField {
    /// The Mac's Favorites that are pages, in its order.
    var favorites: [Favorite] = []
    /// The Mac's Quick Actions that are on, in its order.
    var quickActions: [QuickAction] = []
    /// Meetings Now shows on a Mac, nearest first.
    var meetings: [Meeting] = []

    struct Favorite: Equatable, Sendable, Identifiable {
        /// The Mac's id for it, "page:<address>".
        var id: String
        /// Its name as kept on the Mac; empty where the page has only its address.
        var name: String
        var url: URL
    }

    struct QuickAction: Equatable, Sendable, Identifiable {
        var id: String
        /// "New document".
        var name: String
        /// Where it goes: "https://docs.new".
        var url: URL
        /// What typed leads to it: "doc".
        var alias: String
    }

    struct Meeting: Equatable, Sendable, Identifiable {
        /// The Mac's Now row id.
        var id: String
        var title: String
        /// When it starts.
        var due: Date
        /// Its call (Zoom, Meet, Teams…), when it has one.
        var join: URL?
    }
}
