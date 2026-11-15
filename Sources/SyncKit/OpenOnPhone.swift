import Foundation

/// Send to iPhone (docs/sync.md, "Pages for the iPhone"): Open on Mac the
/// other way round. A Mac writes the same `send` record of kind `open`,
/// addressed to the iPhone's device id, with the page's `url`, its `title`
/// and the `space` it is in; the iPhone takes it once (OpenOnMac.consume
/// keeps the local receipt before anything opens) and says `taken`.
///
/// An iPhone says it takes these in a `commandcap` record of its own, its
/// device id the record's id, `kind` "iphone", which only it writes: a Mac
/// offers Send to iPhone only to an iPhone that stamped `open` itself.
public enum OpenOnPhone {
    public static let version = 1
    /// The `kind` of an iPhone's commandcap record and of its presence.
    public static let kind = "iphone"
    /// A page sent this long ago or less opens at once on an iPhone that is
    /// in front with nothing being typed; an older one waits in Today with
    /// its card, so a page sent last night doesn't take over the screen.
    public static let fresh: TimeInterval = 10 * 60

    /// What an iPhone writes in its own commandcap record.
    public static func capability(device: String) -> [String: Value] {
        ["device": .string(device), "kind": .string(kind), "open": .number(Double(version)),
         "platform": .string("ios"), AndroidSyncCompatibility.field: .number(Double(AndroidSyncCompatibility.version)),
         AssistantApprovalRecords.field: .number(Double(AssistantApprovalRecords.detailVersion))]
    }

    /// An iPhone's own record only: its id, its kind, and `open` stamped by
    /// that iPhone, so no other device can say it for it.
    public static func supports(_ record: Record?, device: String) -> Bool {
        guard let record, record.collection == OpenOnMac.capability, record.id == device, record.alive(),
              record["device"]?.string == device,
              record["open"]?.number == Double(version),
              record.stamps["open"]?.device == device, record.stamps["device"]?.device == device else { return false }
        if record["kind"]?.string == kind { return true }
        return record["kind"]?.string == "android" && record["platform"]?.string == "android"
            && record.stamps["kind"]?.device == device && record.stamps["platform"]?.device == device
            && AndroidSyncCompatibility.supports(record, device: device)
    }

    /// A page for this iPhone, as the card says it.
    public struct Arrival: Equatable, Sendable {
        /// The send record's id.
        public var id: String
        public var url: URL
        /// The page's title, or its host when the Mac had none.
        public var title: String
        /// The space it was in on the Mac, as sync names it.
        public var space: String?
        /// The Mac that sent it.
        public var sender: String
        public var sent: Date

        public init(id: String, url: URL, title: String, space: String?, sender: String, sent: Date) {
            self.id = id; self.url = url; self.title = title; self.space = space; self.sender = sender; self.sent = sent
        }

        /// Sent recently enough to open at once (`fresh`).
        public func fresh(at now: Date) -> Bool { now.timeIntervalSince(sent) <= OpenOnPhone.fresh }
    }

    /// The pages waiting for this device: addressed to it, of kind open,
    /// not taken yet, or left `opening` by a relaunch (`take` says those
    /// failed, never opens them).
    public static func waiting(_ records: [Record], device: String) -> [Record] {
        records.filter { $0.collection == "send" && $0.alive() && $0["device"]?.string == device
            && $0["kind"]?.string == "open" && ($0["state"] == nil || $0["state"]?.string == "opening") }
            .sorted { ($0["at"]?.number ?? 0, $0.id) < ($1["at"]?.number ?? 0, $1.id) }
    }

    /// The page in a record, read as `take` reads it: nil for one it would
    /// refuse.
    public static func arrival(_ record: Record) -> Arrival? {
        guard record.collection == "send", record["kind"]?.string == "open",
              let sender = record["clientDevice"]?.string, !sender.isEmpty,
              let text = record["url"]?.string, let url = OpenOnMac.url(text),
              let sent = record["at"]?.number, sent.isFinite else { return nil }
        let title = OpenOnMac.title(record["title"]) ?? url.host(percentEncoded: false) ?? url.absoluteString
        return Arrival(id: record.id, url: url, title: title, space: OpenOnMac.space(record["space"]), sender: sender,
                       sent: Date(timeIntervalSince1970: sent))
    }

    /// Taken once: the receipt is kept first, then `open` runs, then the
    /// record says `taken`. One more than 12 hours late is `expired` and
    /// never opened; a replay, a rewrite or a relaunch never opens it again
    /// (OpenOnMac.consume). `open` throwing says `failed`.
    @discardableResult
    public static func take(_ record: Record, in journal: Journal, device: String, at now: Date = Date(),
                            open: (Arrival) throws -> Void) throws -> Bool {
        let page = Self.arrival(record)
        return try OpenOnMac.consume(record, in: journal, device: device, at: now) { url in
            guard let page, page.url == url else { throw OpenOnMac.Failure.invalid }
            try open(page)
        }
    }
}
