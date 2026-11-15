import Foundation
import SyncKit

// The extensions and plugins mirror (docs/sync.md, "Extensions and plugins"):
// between the journal and the lists here, by the passes in SyncAddons. One
// read does both ways, from a flush or from records that came in: it takes
// out, sets and takes in here what the account says and this Mac didn't
// change, tells the journal what this Mac has, and says what waits to be put
// in (SyncInstalls). The lists are behind two small protocols, Extensions
// and Boosts in Yab and plain lists in SyncAddonsTests, so the tests run
// this very code against real journals.

/// The extensions here, as the mirror sees them.
@MainActor
protocol MirrorExtensions: AnyObject {
    var installed: [Installed] { get }
    /// False when the list is there and couldn't be read.
    var loaded: Bool { get }
    func remove(_ id: String)
    func syncState(_ id: String, enabled: Bool, pinned: Bool)
}

/// The plugins kept here, as the mirror sees them.
@MainActor
protocol MirrorPlugins: AnyObject {
    var records: [BoostRecord] { get }
    var loaded: Bool { get }
    /// A kept plugin's files as kept; nil when they changed outside Keep.
    func files(_ id: String) -> [String: String]?
    func origin(_ id: String) -> (store: String, revision: String)?
    func state(_ id: String) -> String?
    func remove(_ id: String)
    func apply(_ id: String, enabled: Bool, runsOn: String?)
    func adoptState(_ id: String, _ state: String)
}

@MainActor
final class SyncMirror {
    let extensions: MirrorExtensions
    let plugins: MirrorPlugins
    private(set) var ledger: SyncAddons.Ledger
    private let keep: (SyncAddons.Ledger?) -> Void
    /// The account's devices seen lately (SyncAddons.present); empty while
    /// not known.
    var devices: Set<String> = []
    /// Extensions and plugins the account has now, for Settings.
    private(set) var count = 0
    private var counts: [String: Int] = [:]
    /// Write this Mac's parts again at the next read: at launch, and when
    /// one of them was removed elsewhere.
    private var repair = true
    /// Each kept plugin as read, by a key of what it was read from; nil for
    /// one whose files changed outside Keep.
    private var reads: [String: (key: String, kept: SyncAddons.Kept?, payload: Data?)] = [:]
    /// Parts' fields, by part id, made once a digest.
    private var texts: [String: [String: Value]] = [:]

    init(extensions: MirrorExtensions, plugins: MirrorPlugins, ledger: SyncAddons.Ledger, keep: @escaping (SyncAddons.Ledger?) -> Void) {
        self.extensions = extensions
        self.plugins = plugins
        self.ledger = ledger
        self.keep = keep
    }

    private func byID(_ records: [Record]) -> [String: Record] {
        Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func save() { keep(ledger) }

    // MARK: Extensions

    /// One read of the extensions; `changed`: records that just came in.
    /// Returns the account's this Mac should put in.
    @discardableResult
    func extensions(_ journal: Journal, changed: Set<String> = []) throws -> [Record] {
        let records = byID(journal.all(SyncAddons.ext))
        counts[SyncAddons.ext] = records.values.filter(SyncAddons.usable).count
        count = counts.values.reduce(0, +)
        guard extensions.loaded else { return [] }
        let pass = SyncAddons.passExtensions(extensions.installed, loaded: true, ledger: ledger.extensions, records: records, changed: changed)
        for id in pass.remove { extensions.remove(id) }
        for (id, state) in pass.states { extensions.syncState(id, enabled: state.enabled, pinned: state.pinned) }
        try journal.reconcile(SyncAddons.ext, pass.now, within: { pass.removable.contains($0.id) }, blank: true)
        ledger.extensions = pass.ledger
        save()
        return pass.missing.compactMap { records[$0] }
    }

    /// As with extensions, account sync covers shared sign-ins. Local
    /// profile installations neither publish nor remove the account's copy.
    private var sharedPlugins: [BoostRecord] {
        plugins.records.compactMap { record in
            guard record.profiles?.contains(nil) ?? true else { return nil }
            var shared = record
            shared.enabled = record.enabled && (record.profiles?.isEnabled(in: nil) ?? true)
            return shared
        }
    }

    // MARK: Plugins

    /// One read of the plugins and their parts. `live`: caught up with the
    /// account, so a part no record names is truly named by none. `changed`
    /// and `parts`: records that just came in.
    @discardableResult
    func plugins(_ journal: Journal, device: String, live: Bool, changed: Set<String> = [], parts: Set<String> = []) throws -> [Record] {
        let records = byID(journal.all(SyncAddons.plugin))
        counts[SyncAddons.plugin] = records.values.filter(SyncAddons.usable).count
        count = counts.values.reduce(0, +)
        guard plugins.loaded else { return [] }
        // One changed elsewhere is read afresh: files changed here outside
        // Keep since its last read are left alone rather than overwritten.
        for id in changed { reads[id] = nil }
        var unread = Set<String>(), payloads: [String: Data] = [:]
        let kept = sharedPlugins.compactMap { record -> SyncAddons.Kept? in
            guard let read = read(record) else { unread.insert(record.id); return nil }
            payloads[record.id] = read.payload
            return read.kept
        }
        let pass = SyncAddons.passPlugins(kept, loaded: true, unread: unread, ledger: ledger.plugins, records: records,
                                          device: device, changed: changed)
        for id in pass.remove { plugins.remove(id) }
        for (id, apply) in pass.apply { plugins.apply(id, enabled: apply.enabled, runsOn: apply.runsOn) }
        for (id, state) in pass.states { plugins.adoptState(id, state) }
        try journal.reconcile(SyncAddons.plugin, pass.now, within: { pass.removable.contains($0.id) }, blank: true)
        ledger.plugins = pass.ledger
        // Parts: this Mac's written again when one of them went, and taken
        // back only once nothing names them.
        let gives = Set(pass.own.values.flatMap { $0 })
        if !parts.isDisjoint(with: ledger.parts.union(gives)) { repair = true }
        var named = Set(pass.now.values.flatMap { $0["parts"]?.array?.compactMap(\.string) ?? [] })
        for (id, record) in records where pass.now[id] == nil && !pass.removable.contains(id) {
            named.formUnion(SyncAddons.referenced([record]))
        }
        let going = SyncAddons.partsGoing(gave: ledger.parts, gives: gives, named: named, live: live)
        if gives != ledger.parts || repair || !going.isEmpty {
            var now: SyncAddons.Collection = [:]
            for (id, ids) in pass.own {
                guard let payload = payloads[id], let digest = kept.first(where: { $0.id == id })?.digest else { continue }
                if ids.contains(where: { texts[$0] == nil }) {
                    for piece in SyncAddons.parts(of: payload, digest: digest) { texts[piece.id] = ["data": .string(SyncAddons.text(piece.data))] }
                }
                for part in ids { now[part] = texts[part] }
            }
            try journal.reconcile(SyncAddons.part, now, within: { going.contains($0.id) }, blank: true)
            repair = false
        }
        // What this Mac gave and couldn't take back yet stays noted.
        ledger.parts = gives.union(ledger.parts.subtracting(gives).subtracting(going))
        save()
        takeOver(journal, device: device)
        return pass.missing.compactMap { records[$0] }
    }

    /// A kept plugin as sync sends it: the Store release it is, or its
    /// files and their size. Nil for one whose files changed outside Keep.
    private func read(_ record: BoostRecord) -> (kept: SyncAddons.Kept, payload: Data)? {
        let origin = plugins.origin(record.id)
        let key = [record.revision, record.digest ?? "", record.sites.joined(separator: ","), origin?.store ?? "", origin?.revision ?? ""].joined(separator: "|")
        var kept: SyncAddons.Kept, payload: Data
        if let read = reads[record.id], read.key == key {
            guard let had = read.kept, let data = read.payload else { return nil }
            kept = had
            payload = data
        } else {
            guard let files = plugins.files(record.id), !files.isEmpty else {
                reads[record.id] = (key, nil, nil)
                return nil
            }
            let made = BoostShare.Payload(format: 1, id: record.id, sites: record.sites, files: files)
            guard let data = try? BoostShare.encoded(made), let digest = try? BoostShare.digest(made) else { return nil }
            let release = origin.flatMap { SyncAddons.isRelease($0.revision, catalog: $0.store, sites: record.sites, files: files) ? $0 : nil }
            kept = SyncAddons.Kept(id: record.id, name: record.name, sites: record.sites, rung: record.rung.rawValue, enabled: record.enabled,
                                   author: record.author, digest: digest, store: release?.store, revision: release?.revision,
                                   size: release == nil ? data.count : 0)
            payload = data
            reads[record.id] = (key, kept, data)
        }
        kept.name = record.name
        kept.enabled = record.enabled
        kept.waits = record.waits == true
        kept.author = record.author
        kept.runsOn = record.runsOn
        kept.state = plugins.state(record.id)
        return (kept, payload)
    }

    // MARK: Who ticks

    /// Plugins of the account no Mac present ticks, that this Mac keeps and
    /// has on: this one ticks them now. If two Macs do at once, the later
    /// write wins and the other stops.
    @discardableResult
    func takeOver(_ journal: Journal, device: String) -> [String] {
        guard !devices.isEmpty, SyncAddons.on else { return [] }
        let here = Set(sharedPlugins.filter(\.enabled).map(\.id))
        let ids = SyncAddons.orphaned(journal.all(SyncAddons.plugin), devices: devices, me: device, on: here)
        for id in ids {
            _ = try? journal.change(.init(collection: SyncAddons.plugin, id: id), ["runsOn": .string(device)])
            if let mine = sharedPlugins.first(where: { $0.id == id }) { plugins.apply(id, enabled: mine.enabled, runsOn: device) }
        }
        return ids
    }

    /// The plugins this Mac ticks for the account, given up: none ticks
    /// them in their records, and the first Mac present to see it takes
    /// them on. Returns the records written, to wait for their push.
    @discardableResult
    func giveUp(_ journal: Journal, device: String) -> [Record.Key] {
        let ids = SyncAddons.ticked(journal.all(SyncAddons.plugin), by: device)
        var keys: [Record.Key] = []
        for id in ids {
            let key = Record.Key(collection: SyncAddons.plugin, id: id)
            _ = try? journal.change(key, ["runsOn": .null])
            keys.append(key)
            if let mine = sharedPlugins.first(where: { $0.id == id }) { plugins.apply(id, enabled: mine.enabled, runsOn: nil) }
        }
        return keys
    }

    // MARK: Putting in

    /// Whether what SyncInstalls is about to put in is still wanted: the
    /// switch on, the account's record there, and not removed here since
    /// this Mac's last read (its removal on its way).
    func wanted(_ key: Record.Key, in journal: Journal) -> Bool {
        guard SyncAddons.on, let record = journal.record(key), SyncAddons.usable(record) else { return false }
        switch key.collection {
        case SyncAddons.ext:
            return extensions.loaded && !(ledger.extensions[key.id] != nil && !extensions.installed.contains { $0.id == key.id })
        case SyncAddons.plugin:
            return plugins.loaded && !(ledger.plugins[key.id] != nil && !sharedPlugins.contains { $0.id == key.id })
        default:
            return false
        }
    }

    /// Put in by sync: noted for Undo Joining.
    func installed(_ key: Record.Key) {
        guard !ledger.installed.contains(key.description) else { return }
        ledger.installed.append(key.description)
        save()
    }

    /// Sync off here: nothing agreed on any more.
    func forget() {
        ledger = SyncAddons.Ledger()
        reads = [:]
        texts = [:]
        repair = true
        keep(nil)
    }
}

// MARK: - Yab's own lists

@available(macOS 15.4, *)
extension Extensions: MirrorExtensions {}

extension Boosts: MirrorPlugins {
    func files(_ id: String) -> [String: String]? { try? library.files(id) }
    func origin(_ id: String) -> (store: String, revision: String)? { StoreCatalog.shared.origin(of: id) }
    func state(_ id: String) -> String? { Store.settings.string(forKey: BoostStorage.key(id)) }
    func remove(_ id: String) { removeSynced(id) }
    func apply(_ id: String, enabled: Bool, runsOn: String?) { applySynced(id, enabled: enabled, runsOn: runsOn) }
    func adoptState(_ id: String, _ state: String) { BoostStorage.adopt(id, state) }
}
