import Foundation

/// The page in front on an iPhone, as its presence says it (docs/sync.md,
/// "Continue from your iPhone"): a Mac offers it under its empty field as
/// "From iPhone" for a minute after it changed there, the mirror of the
/// iPhone's "On your Mac". The presence is sealed as every presence is and
/// says only the tab in front: its address and title, its tab and space as
/// sync names them, and `changed`, when that page came in front on the
/// iPhone or was last left there (Yab to the back). Never a private tab's.
public enum PhoneFront {
    /// How long an iPhone's page is offered after it changed there.
    public static let window: TimeInterval = 60
    public static let changedField = "changed"

    public struct Page: Equatable, Sendable {
        /// The iPhone's device id, as the server says who spoke.
        public var device: String
        /// The iPhone's name, as it says it.
        public var name: String
        public var url: URL
        public var title: String
        /// Its tab and space as sync names them, when the tab syncs.
        public var tab: String?
        public var space: String?
        public var changed: Date

        public init(device: String, name: String, url: URL, title: String, tab: String?, space: String?, changed: Date) {
            self.device = device; self.name = name; self.url = url; self.title = title
            self.tab = tab; self.space = space; self.changed = changed
        }
    }

    /// The fields an iPhone adds to its presence for its page in front.
    public static func fields(space: String?, changed: Date) -> [String: Value] {
        var out: [String: Value] = [changedField: .number(changed.timeIntervalSince1970.rounded(.down))]
        if let space = OpenOnMac.space(.string(space ?? "")) { out["space"] = .string(space) }
        return out
    }

    /// An iPhone's page out of its presence: only an iPhone's, only a web
    /// page another device can open (ContinuePage's rules), with when it
    /// changed. Nil for a Mac's presence or one with no page in front.
    public static func page(device: String, record: Record) -> Page? {
        guard record.collection == "presence", [OpenOnPhone.kind, "android"].contains(record["kind"]?.string ?? ""), !device.isEmpty,
              let changed = record[changedField]?.number, changed.isFinite, changed > 0,
              let page = ContinuePage.page(url: record["url"]?.string.flatMap(URL.init(string:)), title: record["title"]?.string ?? "",
                                           space: OpenOnMac.space(record["space"])) else { return nil }
        let tab = record["tab"]?.string.flatMap(UUID.init(uuidString:))?.uuidString
        return Page(device: device, name: record["name"]?.string ?? "", url: page.url, title: page.title, tab: tab,
                    space: page.space, changed: Date(timeIntervalSince1970: changed))
    }

    /// Whether a Mac offers it now: it changed on the iPhone in the last
    /// minute, and it isn't the page the Mac has in front already (by its
    /// tab or by its address).
    public static func offered(_ page: Page, now: Date, front: URL?, frontTab: String?) -> Bool {
        let age = now.timeIntervalSince(page.changed)
        guard age < window, age > -5 else { return false }
        if let tab = page.tab, let frontTab, tab.caseInsensitiveCompare(frontTab) == .orderedSame { return false }
        if let front, ContinuePage.same(front, page.url) { return false }
        return true
    }

    /// The freshest page offered among the iPhones', if any.
    public static func offer(_ pages: [Page], now: Date, front: URL?, frontTab: String?) -> Page? {
        pages.filter { offered($0, now: now, front: front, frontTab: frontTab) }.max { $0.changed < $1.changed }
    }
}
