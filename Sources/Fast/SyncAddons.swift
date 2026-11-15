import CryptoKit
import Foundation
import SyncKit

// Extensions and plugins in sync (docs/sync.md, "Extensions and plugins").
// Pure, as SyncShapes is: what is installed here, what this Mac and the
// account last agreed on (its ledger) and what the account says in; what to
// tell the journal and what to take out, set or put in here, out.
// SyncMirror runs these against the journal and the live lists, and
// SyncInstalls fetches and puts in what another Mac has.
//
// Collections:
// - extension: one per extension from the Chrome Web Store, by its id. One
//   loaded from a folder stays on its Mac: there is nothing to fetch it from.
// - plugin: one per kept plugin (boost), by its package id. A Store release
//   kept as it came goes as the release (`store`, `revision`), fetched again
//   on the other Mac; one of your own goes as its files, in parts.
// - pluginpart: a piece of a plugin's files, `<digest>/<n>`, named by what
//   it holds, so a plugin sent again unchanged sends nothing new.
//
// Which side wins, field by field: a value changed here since this Mac and
// the account last agreed on it goes up; one unchanged here takes the
// account's, and so does one never agreed on (joining, or after a Yab that
// didn't keep the ledger). So a Mac back from being away, or from the switch
// off, sends only what it changed and takes the rest.
//
// A removal wins over what another Mac changed at the same moment (turned
// it off, pinned it): a record counts only while its name was written after
// its last removal (`usable`). Installing it again writes its name again,
// and brings it back, which a collection whose removals win outright, as
// tabs', would never let an extension with a fixed id do. Removals empty the
// record (Journal.reconcile `blank`): the server keeps them for good.

enum SyncAddons {
    static let ext = SyncCollection.ext, plugin = SyncCollection.plugin, part = SyncCollection.pluginPart
    static let collections = [ext, plugin, part]

    /// The shape these records have. One a later Yab marks higher waits for
    /// an update here rather than being read wrong.
    static let schema = 1

    /// The raw bytes of one part. Its record is sealed and sent as base64,
    /// which the server takes up to 96 KB of: 48,000 bytes are 64,000
    /// characters (`text`), and the seal and the record's own fields fit
    /// around them.
    static let partSize = 48_000
    /// The most a record's JSON may be: sealed (28 bytes more) and in base64
    /// (a third more), it stays under the server's 96 KB.
    static let recordLimit = 70_000

    /// Settings › Sync, Extensions and plugins: on unless turned off. Off,
    /// this Mac neither sends nor takes them; what the account has stays.
    static var on: Bool {
        get { Store.settings.object(forKey: "sync.addons") as? Bool ?? true }
        set { Store.settings.set(newValue, forKey: "sync.addons") }
    }

    /// Sync on here, with extensions and plugins: only then does another
    /// Mac's `runsOn` keep a plugin's ticks off this one.
    static var active: Bool {
        on && FileManager.default.fileExists(atPath: Store.file("sync.sqlite").path)
    }

    /// What a flush reads: these collections only while they are on here.
    static func due(_ collections: Set<String>, on: Bool = on) -> Set<String> {
        on ? collections : collections.subtracting(Self.collections)
    }

    /// An extension or plugin to have: there, and named since its last
    /// removal. A change another Mac made as it was removed leaves only
    /// that field alive, which isn't one.
    static func usable(_ record: Record) -> Bool {
        record.alive() && record["name"]?.string != nil
    }

    /// Removed: a removal in it, and nothing named since.
    static func removed(_ record: Record) -> Bool {
        record.deleted != nil && !usable(record)
    }

    /// Whether a record of these fields fits what the server takes.
    static func fits(_ collection: String, _ id: String, _ fields: [String: Value], device: String) -> Bool {
        let stamp = Stamp(wall: 9_999_999_999_999, count: .max, device: device)
        let record = Record(collection: collection, id: id, fields: fields, stamps: fields.mapValues { _ in stamp }, deleted: stamp)
        return ((try? JSONEncoder().encode(record).count) ?? .max) <= recordLimit
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    typealias Collection = SyncShapes.Collection

    // MARK: The ledger

    /// What this Mac and the account last agreed on, per extension and
    /// plugin, kept in sync's own file (SyncMirror), not in Yab's lists, which
    /// an older Yab rewrites without it. An item in it is one this Mac had
    /// at its last read: one gone here since is a removal to send.
    struct Ledger: Codable, Equatable {
        var extensions: [String: Agreed] = [:]
        var plugins: [String: Agreed] = [:]
        /// The parts this Mac gave at its last read; only these it removes.
        var parts: Set<String> = []
        /// Put in by sync since this Mac joined, for Undo Joining.
        var installed: [String] = []
    }

    struct Agreed: Codable, Equatable {
        var enabled: Bool?
        var pinned: Bool?
        /// A plugin's files, by their digest.
        var digest: String?
        /// A plugin's state, by its hash.
        var state: String?
    }

    /// A field as it should be now: changed here since the two agreed, this
    /// Mac's; otherwise, or never agreed on, the account's when it has one.
    static func settle<T: Equatable>(mine: T, agreed: T?, theirs: T?) -> T {
        guard let theirs else { return mine }
        if let agreed, agreed != mine { return mine }
        return theirs
    }

    // MARK: Extensions

    /// Whether one Chrome version ("1.2.3.4") comes after another, part by part.
    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    struct ExtensionPass: Equatable {
        /// The records this Mac says now.
        var now: Collection = [:]
        /// Those it may remove for missing from `now`: what it had.
        var removable: Set<String> = []
        /// To take out here: removed in the account after this Mac had them.
        var remove: [String] = []
        /// To set here: on, off and pinned as the account says.
        var states: [String: State] = [:]
        /// To put in here.
        var missing: [String] = []
        var ledger: [String: Agreed] = [:]
        struct State: Equatable { var enabled: Bool; var pinned: Bool }
    }

    /// The extensions here against the account. A list that couldn't be
    /// read says nothing, removes nothing and takes nothing: read as empty,
    /// it would take every extension off every Mac. One removed here since
    /// the last read goes as a removal and isn't put back in; one the
    /// account removed after this Mac had it (or just now, `changed`) comes
    /// out here. What it was allowed only grows, and its version is the
    /// newer of the two, so two Macs a version apart don't write theirs over
    /// each other's. One here that waits to be allowed more stands as the
    /// account has it: off here for that is not the person turning it off.
    static func passExtensions(_ installed: [Installed], loaded: Bool, ledger: [String: Agreed], records: [String: Record],
                               changed: Set<String> = []) -> ExtensionPass {
        guard loaded else { return ExtensionPass(ledger: ledger) }
        var pass = ExtensionPass()
        let store = installed.filter { $0.fromStore && Crx.id(in: $0.id) == $0.id }
        pass.remove = store.filter { (ledger[$0.id] != nil || changed.contains($0.id)) && records[$0.id].map(removed) == true }.map(\.id).sorted()
        for item in store where !pass.remove.contains(item.id) {
            let record = records[item.id].flatMap { usable($0) ? $0 : nil }
            if item.wants != nil {
                if let record {
                    pass.now[item.id] = record.visible
                    pass.ledger[item.id] = Agreed(enabled: record["enabled"]?.bool, pinned: record["pinned"]?.bool)
                }
                continue
            }
            let agreed = ledger[item.id]
            let enabled = settle(mine: item.enabled, agreed: agreed?.enabled, theirs: record?["enabled"]?.bool)
            let pinned = settle(mine: item.pinned == true, agreed: agreed?.pinned, theirs: record?["pinned"]?.bool)
            if enabled != item.enabled || pinned != (item.pinned == true) { pass.states[item.id] = .init(enabled: enabled, pinned: pinned) }
            var allowed = Set(item.permissions)
            allowed.formUnion(record?["permissions"]?.array?.compactMap(\.string) ?? [])
            var version = item.version
            if let theirs = record?["version"]?.string, newer(theirs, than: version) { version = theirs }
            pass.now[item.id] = [
                "name": .string(item.name),
                "version": .string(version),
                "enabled": .bool(enabled),
                "pinned": .bool(pinned),
                "permissions": .array(allowed.sorted().map(Value.string)),
            ]
            pass.ledger[item.id] = Agreed(enabled: enabled, pinned: pinned)
        }
        let here = Set(installed.map(\.id))
        pass.removable = Set(ledger.keys)
        pass.missing = records.values.filter { record in
            usable(record) && record.collection == ext && Crx.id(in: record.id) == record.id
                && !here.contains(record.id) && ledger[record.id] == nil
        }.map(\.id).sorted()
        return pass
    }

    /// Fetched here at a version that asks for more than another Mac
    /// allowed it: comes in off, and asks when turned on.
    struct Arrival: Equatable {
        var enabled: Bool
        var permissions: [String]
        var wants: [String]?
    }

    static func arrival(grants: [String], enabled: Bool, allowed: [String]) -> Arrival {
        let more = Set(grants).subtracting(allowed).sorted()
        guard more.isEmpty else { return Arrival(enabled: false, permissions: Set(allowed).sorted(), wants: more) }
        return Arrival(enabled: enabled, permissions: grants, wants: nil)
    }

    // MARK: Plugins

    /// A plugin kept here, as the mirror reads it.
    struct Kept: Equatable {
        var id: String
        var name: String
        var sites: [String]
        var rung: String
        var enabled: Bool
        var author: String
        /// BoostShare.digest of its files under its id.
        var digest: String
        /// The Mac its service runs on, as this Mac has it.
        var runsOn: String?
        /// The Store listing and release it is, when its files are that
        /// release's exactly.
        var store: String?
        var revision: String?
        /// How many bytes its payload (BoostShare.encoded) is, for one that
        /// goes as files: its parts are named by the digest and the count.
        var size: Int = 0
        var state: String?
        /// Code from another Mac kept off here until the person's yes
        /// (BoostRecord.waits): the account's on or off stands meanwhile.
        var waits = false
    }

    /// How a plugin from another Mac is kept here: a look on or off as
    /// the account has it; code too, when it replaces one this Mac said yes
    /// to and asks for no more than that one could. Any other code (new
    /// here, still waiting, kept here unreadable, or asking for more) comes
    /// in off and waits for the person to turn it on here, as an extension
    /// that asks for more does (`arrival(grants:)`).
    struct PluginArrival: Equatable {
        var enabled: Bool
        var waits: Bool
    }

    static func arrival(_ package: BoostPackage, kept: BoostPackage?, here: BoostRecord?, enabled: Bool) -> PluginArrival {
        guard package.rung != .look else { return PluginArrival(enabled: enabled, waits: false) }
        if let kept, let here, here.waits != true, !package.widens(kept) { return PluginArrival(enabled: enabled, waits: false) }
        return PluginArrival(enabled: false, waits: true)
    }

    /// Whether these files are that Store release as it is listed: its
    /// payload is named for the listing, so the hash says it.
    static func isRelease(_ revision: String, catalog: String, sites: [String], files: [String: String]) -> Bool {
        BoostShare.validRevision(revision)
            && (try? BoostShare.digest(.init(format: 1, id: catalog, sites: sites, files: files))) == revision
    }

    /// A part's bytes as text: base64 in its URL-safe letters, which JSON
    /// keeps as they are (a "/" it writes as two), so a part's record stays
    /// the size worked out above whatever bytes it holds.
    static func text(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }

    static func bytes(_ text: String) -> Data? {
        Data(base64Encoded: text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/"))
    }

    /// The parts of a payload of `size` bytes, by name.
    static func partIDs(digest: String, size: Int) -> [String] {
        (0..<max(1, (size + partSize - 1) / partSize)).map { "\(digest)/\($0)" }
    }

    /// A payload in pieces of `partSize`, each named by the digest and its place.
    static func parts(of payload: Data, digest: String) -> [(id: String, data: Data)] {
        stride(from: 0, to: payload.count, by: partSize).enumerated().map { piece in
            (id: "\(digest)/\(piece.offset)", data: payload.subdata(in: piece.element..<min(piece.element + partSize, payload.count)))
        }
    }

    struct PluginPass: Equatable {
        var now: Collection = [:]
        var removable: Set<String> = []
        var remove: [String] = []
        /// On or off, and the Mac that ticks it, to set here.
        var apply: [String: Apply] = [:]
        /// The account's state, to take here.
        var states: [String: String] = [:]
        var missing: [String] = []
        /// The parts of the plugins whose files this Mac gives, by plugin.
        var own: [String: [String]] = [:]
        var ledger: [String: Agreed] = [:]
        struct Apply: Equatable { var enabled: Bool; var runsOn: String? }
    }

    /// The plugins kept here against the account, as extensions are. Their
    /// files: changed here since the two agreed, this Mac's go; otherwise,
    /// or never agreed on, the account's newer ones are put in here, and
    /// until then the record stands as the account has it but for what
    /// this Mac changed (on or off, its state). Who ticks it is always the
    /// account's, but for one with no record yet, or a new life after a
    /// removal: this Mac. `unread`: kept here, but its files couldn't be read
    /// as kept: neither sent, nor removed, nor put in, nor changed. One that
    /// waits for the person's yes here (`Kept.waits`) leaves the account's
    /// on or off as it is.
    static func passPlugins(_ kept: [Kept], loaded: Bool, unread: Set<String> = [], ledger: [String: Agreed], records: [String: Record],
                            device: String, changed: Set<String> = []) -> PluginPass {
        guard loaded else { return PluginPass(ledger: ledger) }
        var pass = PluginPass()
        for id in unread { if let agreed = ledger[id] { pass.ledger[id] = agreed } }
        pass.remove = kept.filter { (ledger[$0.id] != nil || changed.contains($0.id)) && records[$0.id].map(removed) == true }.map(\.id).sorted()
        var waiting = Set<String>()
        for plugin in kept where !pass.remove.contains(plugin.id) {
            let record = records[plugin.id]
            let ok = record.map(usable) ?? false
            let agreed = ledger[plugin.id]
            // There, not removed, but not one this Yab can read: left as it is.
            if let record, !ok, !removed(record) {
                if let agreed { pass.ledger[plugin.id] = agreed }
                continue
            }
            var fields: [String: Value]
            let theirs = ok ? record?["digest"]?.string : nil
            if let record, let theirs, theirs != plugin.digest, agreed?.digest == nil || agreed?.digest == plugin.digest {
                fields = record.visible
                waiting.insert(plugin.id)
            } else {
                fields = [
                    "name": .string(plugin.name),
                    "sites": .array(plugin.sites.map(Value.string)),
                    "rung": .string(plugin.rung),
                    "author": .string(plugin.author),
                    "digest": .string(plugin.digest),
                ]
                if let store = plugin.store, let revision = plugin.revision {
                    fields["store"] = .string(store)
                    fields["revision"] = .string(revision)
                } else {
                    let ids = partIDs(digest: plugin.digest, size: plugin.size)
                    fields["parts"] = .array(ids.map(Value.string))
                    pass.own[plugin.id] = ids
                }
            }
            // Waiting for the person's yes here, off here is not the person
            // turning it off: the account's on or off stands, and the ledger
            // agrees with it, so what the person sets here later goes up.
            let theirsOn = ok ? record?["enabled"]?.bool : nil
            let enabled = plugin.waits ? theirsOn ?? plugin.enabled : settle(mine: plugin.enabled, agreed: agreed?.enabled, theirs: theirsOn)
            fields["enabled"] = .bool(enabled)
            let runsOn = ok ? record?["runsOn"]?.string : device
            fields["runsOn"] = Value(runsOn)
            let onHere = plugin.waits ? plugin.enabled : enabled
            if onHere != plugin.enabled || runsOn != plugin.runsOn { pass.apply[plugin.id] = .init(enabled: onHere, runsOn: runsOn) }
            // State: as on and off, by its hash.
            let account = ok ? record?["state"]?.string : nil
            let mine = plugin.state.map(hash)
            var state = plugin.state
            if let account, account != plugin.state, agreed?.state == nil || agreed?.state == mine {
                state = account
                pass.states[plugin.id] = account
            }
            fields["state"] = Value(account)
            if let state, state != account {
                var sent = fields
                sent["state"] = .string(state)
                if fits(Self.plugin, plugin.id, sent, device: device) { fields = sent }
            }
            pass.now[plugin.id] = fields
            pass.ledger[plugin.id] = Agreed(enabled: enabled, digest: waiting.contains(plugin.id) ? agreed?.digest : plugin.digest,
                                            state: fields["state"]?.string.map(hash))
        }
        pass.removable = Set(ledger.keys).subtracting(unread)
        let here = Set(kept.map(\.id)).union(unread)
        pass.missing = records.values.filter { record in
            guard record.collection == plugin, usable(record), record["digest"]?.string != nil,
                  !pass.remove.contains(record.id), !unread.contains(record.id) else { return false }
            return here.contains(record.id) ? waiting.contains(record.id) : ledger[record.id] == nil
        }.map(\.id).sorted()
        return pass
    }

    /// The parts the account's plugins name.
    static func referenced(_ plugins: [Record]) -> Set<String> {
        Set(plugins.filter(usable).flatMap { $0["parts"]?.array?.compactMap(\.string) ?? [] })
    }

    /// The parts this Mac takes back: ones it gave at its last read and no
    /// longer gives, that no plugin of the account names, and only once it
    /// is caught up with the account, which a Mac still taking in its
    /// first pages isn't: a part is named by a record that may come later.
    static func partsGoing(gave: Set<String>, gives: Set<String>, named: Set<String>, live: Bool) -> Set<String> {
        live ? gave.subtracting(gives).subtracting(named) : []
    }

    /// One of your own plugins from its parts: waiting while some haven't
    /// come, broken when they don't make what the record says, newer when
    /// a later Yab made it.
    enum Assembly: Equatable {
        case waiting
        case ready(files: [String: String], sites: [String])
        case broken
        case newer
    }

    static func assemble(_ record: Record, part: (String) -> Record?) -> Assembly {
        guard record.schema <= schema, BoostPackage.Rung(rawValue: record["rung"]?.string ?? "") != nil else { return .newer }
        guard let digest = record["digest"]?.string, let ids = record["parts"]?.array?.compactMap(\.string), !ids.isEmpty,
              ids.enumerated().allSatisfy({ $0.element == "\(digest)/\($0.offset)" }) else { return .broken }
        var data = Data()
        for id in ids {
            guard let piece = part(id), piece.alive(), let text = piece["data"]?.string else { return .waiting }
            guard let bytes = Self.bytes(text) else { return .broken }
            data.append(bytes)
        }
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == digest else { return .broken }
        guard let payload = try? JSONDecoder().decode(BoostShare.Payload.self, from: data) else { return .newer }
        guard payload.format == 1 else { return .newer }
        guard payload.id == record.id, (try? BoostShare.digest(payload)) == digest else { return .broken }
        return .ready(files: payload.files, sites: payload.sites)
    }

    /// What, of a record, putting it in depends on: a change to anything
    /// else (its state, its Mac, on or off) is no reason to try again.
    static func signature(_ record: Record) -> String {
        let fields = ["digest", "store", "revision", "parts", "rung", "version"].map { name in
            record[name].map { (try? JSONEncoder().encode($0)).map { String(decoding: $0, as: UTF8.self) } ?? "" } ?? ""
        }
        return "\(record.schema)|" + fields.joined(separator: "|")
    }

    // MARK: The Store

    /// Whether a Store release is code: by its rung, or by what the Store
    /// says the listing is, whichever says so.
    static func isCode(rung: BoostPackage.Rung, listing: StoreCatalog.Item?) -> Bool {
        rung != .look || listing?.plugin == true
    }

    /// What may come in of a Store release. Code only while a catalog read
    /// from yetanotherbrowser.com in the last six hours lists it reviewed at
    /// this very revision, as a release on trial would have to be: any
    /// other revision the site still serves is not the reviewed one. A
    /// catalog that is old, missing or lists another release waits for the
    /// next one.
    enum StoreCheck: Equatable {
        case look
        case code
        /// Waits for a fresh catalog, saying why.
        case catalog(String)
    }

    static func storeCheck(rung: BoostPackage.Rung, revision: String, listing: StoreCatalog.Item?, origin: URL?,
                           listed: [StoreCatalog.Item], fresh: Bool) -> StoreCheck {
        guard isCode(rung: rung, listing: listing) else { return .look }
        guard fresh else { return .catalog("The Store's list here is old") }
        guard let listing else { return .catalog("The Store doesn't list it here") }
        if let refusal = StoreCatalog.codeRefusal(listing, origin: origin, listed: listed) { return .catalog(refusal) }
        guard listing.revision == revision else { return .catalog("It isn't the release the Store lists") }
        return .code
    }

    // MARK: Who ticks a plugin

    /// A device the account has, seen in the last two days: one away longer
    /// (or one that turned sync off without saying so) gives its plugins
    /// up to the Macs still here.
    static let away: TimeInterval = 2 * 86_400

    static func present(_ devices: [(id: String, seen: Date?)], now: Date = Date()) -> Set<String> {
        Set(devices.filter { $0.seen.map { now.timeIntervalSince($0) < away } ?? true }.map(\.id))
    }

    /// Plugins whose Mac no longer ticks them (gone from the account, away,
    /// or given them up) that this Mac keeps and has on: this one ticks them
    /// from now on. Nothing while the account's devices aren't known, or
    /// don't have this Mac among them.
    static func orphaned(_ records: [Record], devices: Set<String>, me: String, on here: Set<String>) -> [String] {
        guard devices.contains(me) else { return [] }
        return records.filter { record in
            record.collection == plugin && usable(record) && here.contains(record.id)
                && !(record["runsOn"]?.string.map { devices.contains($0) } ?? false)
        }.map(\.id).sorted()
    }

    /// The plugins this Mac ticks for the account, to give up when it
    /// stops syncing them.
    static func ticked(_ records: [Record], by me: String) -> [String] {
        records.filter { $0.collection == plugin && usable($0) && $0["runsOn"]?.string == me }.map(\.id).sorted()
    }
}
