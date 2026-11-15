import Foundation

/// The ways into Yab from outside it that aren't a web page: the Search and
/// Ask widgets and the share sheet open Yab with yab://<route>. The Live
/// Activity's yab://task/... is TaskDesk's; a web link from another app comes
/// as yab-open:// (Entrances/Links). Compiled into the app, the widgets
/// (Phone/Activity) and the share sheet (Phone/Share).
enum YabRoute: String, CaseIterable, Sendable {
    /// New Tab's field, the keyboard up: the Search widget.
    case newTab = "new"
    /// A new chat, its field ready: the Ask widget.
    case ask
    /// New Tab with the eyes shut: Shortcuts' New Private Tab.
    case privateTab = "private"
    /// What the share sheet left in the queue (SharedLinkQueue): Open in Yab.
    case shared

    static let scheme = "yab"

    var url: URL { URL(string: "\(Self.scheme)://\(rawValue)")! }

    /// The route a yab:// link asks for; nil for anything else, a task's link too.
    init?(_ url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, let host = url.host()?.lowercased(),
              url.path().isEmpty || url.path() == "/", let route = YabRoute(rawValue: host) else { return nil }
        self = route
    }
}
