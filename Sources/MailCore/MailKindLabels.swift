import Foundation

/// Label in Gmail (docs/mail.md, Splits, Sorting): a kind of mail as this
/// Mac reads it (MailSense) put on its threads in Gmail as `yab/<Kind>`, so
/// Gmail on a phone sorts as Yab does. Off until a kind is turned on; then
/// after each reading, the last month's threads of that kind not labeled
/// yet are, through ops (MailOps.label: the journal, Gmail hears it with
/// the next flush). Each thread once: one whose label was taken off in
/// Gmail by hand isn't labeled again, and a kind turned off stops being
/// labeled, what carries it left as it is.
public enum MailKindLabels {
    /// The kinds the Sorting table lists, in its order, and their names.
    public static let kinds: [MailSensed.Kind] = [.invoice, .meeting, .shipping, .code, .list, .promotion]

    public static func name(_ kind: MailSensed.Kind) -> String {
        switch kind {
        case .invoice: return "Invoices"
        case .meeting: return "Invitations"
        case .shipping: return "Shipping"
        case .code: return "Codes"
        case .list: return "Newsletters"
        case .promotion: return "Cold pitches"
        case .person: return "People"
        case .other: return "Other"
        }
    }

    /// Its label in Gmail: "yab/Invoices".
    public static func label(_ kind: MailSensed.Kind) -> String { "yab/" + name(kind) }

    /// How far back a kind is counted and labeled.
    public static let month: TimeInterval = 30 * 86_400

    /// The settings key: the kinds labeled in Gmail, by raw value.
    public static let key = "mail.kinds.label"

    /// How many threads of each kind came in the last month.
    public static func counts(_ store: MailStore, now: Date = MailClock.now) -> [MailSensed.Kind: Int] {
        var out: [MailSensed.Kind: Int] = [:]
        for one in store.kinds(since: now.addingTimeInterval(-month)) { out[one.kind, default: 0] += 1 }
        return out
    }

    /// The threads labeled already, by kind, kept in the store's meta:
    /// none labeled twice, whether Gmail's label id is known yet or not.
    static func done(_ kind: MailSensed.Kind, in store: MailStore) -> Set<String> {
        guard let kept = store.value("kind-labeled." + kind.rawValue)?.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: kept) else { return [] }
        return Set(ids)
    }

    /// The last month's threads of these kinds not labeled yet, labeled:
    /// one act a kind. Nil when nothing was to do.
    @discardableResult
    public static func run(_ store: MailStore, kinds wanted: Set<MailSensed.Kind>, now: Date = MailClock.now) -> [MailOps.Acted]? {
        guard !wanted.isEmpty else { return nil }
        let recent = store.kinds(since: now.addingTimeInterval(-month))
        var out: [MailOps.Acted] = []
        for kind in kinds where wanted.contains(kind) {
            let ids = recent.filter { $0.kind == kind }.map(\.thread)
            guard !ids.isEmpty else { continue }
            var done = done(kind, in: store)
            let name = label(kind)
            // By its id once Gmail made it (MailLabels keeps it); by its name
            // until then, which the flush makes and keeps (MailOps.flush).
            let id = store.labelID(exactly: name)
            let carry = id.map { id in Set(store.threads(ids: ids).filter { $0.labels.contains(id) }.map(\.id)) } ?? []
            let new = ids.filter { !done.contains($0) && !carry.contains($0) }
            done.formUnion(ids.filter { carry.contains($0) })
            if !new.isEmpty {
                out.append(MailOps.label(new, id: id ?? "name:" + name, in: store))
                done.formUnion(new)
            }
            // A month's worth and a little more: older ones are out of reach.
            let keep = Set(ids).intersection(done)
            if let data = try? JSONEncoder().encode(keep.sorted()), let line = String(data: data, encoding: .utf8) {
                store.set("kind-labeled." + kind.rawValue, line)
            }
        }
        return out.isEmpty ? nil : out
    }
}
