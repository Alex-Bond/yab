import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// One of a Mac's Now rows about mail, as the Now widget draws it
/// (docs/sync.md, `now`): the Mac's words, who wrote, and where the mail is.
struct NowShelfRow: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var detail: String
    /// The sender's name: all a locked iPhone shows.
    var who: String
    var host: String
    /// The thread in Gmail on the web.
    var web: String?
    /// The newest message's Message-ID, for Mail (message://).
    var message: String?
    var order: Int

    /// The widget's link to the row: Yab opens the mail where it is.
    var link: URL {
        var parts = URLComponents()
        parts.scheme = "yab"
        parts.host = NowShelf.route
        parts.queryItems = [URLQueryItem(name: "id", value: id)]
        return parts.url!
    }

    /// The letter on the row's mark.
    var letter: String { String((who.isEmpty ? host : who).prefix(1)).uppercased() }
}

/// The Mac's Now rows, kept in the App Group for the widget: the app writes
/// them as sync brings them (PhoneSync), the widget reads them. One small
/// file, written whole.
struct NowShelf: Sendable {
    static let appGroup = "group.dev.serafim.fast.iphone"
    /// WidgetKit's kind for the Now widget: stable, or placed widgets go blank.
    static let widgetKind = "dev.serafim.fast.iphone.now"
    /// yab://now?id=<row>: a row's tap.
    static let route = "now"
    static let limit = 3

    /// Nil when the App Group isn't granted (an unsigned simulator build):
    /// then nothing is kept and the widget is Search.
    let file: URL?

    static var shared: NowShelf {
        if let folder = ProcessInfo.processInfo.environment["YAB_NOW_SHELF"] {
            return NowShelf(file: URL(fileURLWithPath: folder).appendingPathComponent("now.json"))
        }
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        return NowShelf(file: container?.appendingPathComponent("Now", isDirectory: true).appendingPathComponent("now.json"))
    }

    func read() -> [NowShelfRow] {
        guard let file, let data = try? Data(contentsOf: file),
              let rows = try? JSONDecoder().decode([NowShelfRow].self, from: data) else { return [] }
        return rows
    }

    /// Keeps the rows, in order and at most three; the widget is drawn
    /// again only when they changed. False when nothing was written.
    @discardableResult
    func write(_ rows: [NowShelfRow]) -> Bool {
        guard let file else { return false }
        let rows = Array(rows.sorted { ($0.order, $0.id) < ($1.order, $1.id) }.prefix(Self.limit))
        guard rows != read() else { return false }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(rows).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            return false
        }
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
        #endif
        return true
    }

    /// The row a yab://now link names.
    static func id(in url: URL) -> String? {
        guard url.scheme?.lowercased() == "yab", url.host()?.lowercased() == route else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value
    }
}
