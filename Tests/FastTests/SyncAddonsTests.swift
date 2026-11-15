import CryptoKit
import Foundation
import Testing
import SyncKit
@testable import Fast

/// Extensions and plugins between Macs, through the mirror SyncCenter runs
/// (SyncMirror) against real journals, with plain lists in place of
/// Extensions and Boosts: what goes out comes back the same; a fresh join,
/// a list that couldn't be read, a removal here or elsewhere, a relaunch,
/// a re-install and the switch off and on again each do what docs/sync.md
/// says; changes made here win only when made here; a plugin of your own
/// goes in parts, a Mac still catching up never takes parts back, and the
/// owner writes its parts again; one Mac ticks a plugin and gives it up for
/// good; a Store release with code comes only as the fresh catalog's.
@MainActor
@Suite(.serialized)
struct SyncAddonsTests {
    init() { SyncShapes.register() }

    nonisolated static let id = "fmkadmapgofadopljbjfkapdkoienihi"
    nonisolated static let other = "nngceckbapebfimnlniiiahkandclblb"
    nonisolated static let third = "eiaeiblijfjekdanodkjadfinkhbfgcd"

    // MARK: Two Macs

    @MainActor
    final class ExtensionList: MirrorExtensions {
        var installed: [Installed] = []
        var loaded = true
        func remove(_ id: String) { installed.removeAll { $0.id == id } }
        func syncState(_ id: String, enabled: Bool, pinned: Bool) {
            guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
            installed[index].pinned = pinned
            if installed[index].wants == nil { installed[index].enabled = enabled }
        }
        func get(_ id: String) -> Installed? { installed.first { $0.id == id } }
    }

    @MainActor
    final class PluginList: MirrorPlugins {
        var records: [BoostRecord] = []
        var loaded = true
        var kept: [String: [String: String]] = [:]
        var unreadable: Set<String> = []
        var origins: [String: (store: String, revision: String)] = [:]
        var states: [String: String] = [:]
        func files(_ id: String) -> [String: String]? { unreadable.contains(id) ? nil : kept[id] }
        func origin(_ id: String) -> (store: String, revision: String)? { origins[id] }
        func state(_ id: String) -> String? { states[id] }
        func remove(_ id: String) { records.removeAll { $0.id == id }; kept[id] = nil }
        /// As Boosts.applySynced: one waiting for the person's yes stays off.
        func apply(_ id: String, enabled: Bool, runsOn: String?) {
            guard let index = records.firstIndex(where: { $0.id == id }) else { return }
            if records[index].waits != true { records[index].enabled = enabled }
            records[index].runsOn = runsOn
        }
        func adoptState(_ id: String, _ state: String) { states[id] = state }
        /// Its rung as BoostPackage reads it: Look, or Page for files with a script.
        func keep(_ id: String, _ files: [String: String], enabled: Bool = true, runsOn: String? = nil, waits: Bool = false) {
            let digest = try? BoostShare.digest(.init(format: 1, id: id, sites: ["example.com"], files: files))
            let rung = (try? BoostPackage.read(id: id, files: files, sites: ["example.com"]))?.rung ?? .look
            let record = BoostRecord(id: id, name: "Plugin \(id)", sites: ["example.com"], rung: rung, intent: "", author: "You", session: "",
                                     enabled: enabled, revision: UUID().uuidString, updated: Date(), digest: digest, runsOn: runsOn,
                                     waits: waits ? true : nil)
            records.removeAll { $0.id == id }
            records.append(record)
            kept[id] = files
        }
        /// As Settings turns it on or off here (Boosts.setEnabled).
        func set(_ id: String, _ enabled: Bool) {
            guard let index = records.firstIndex(where: { $0.id == id }) else { return }
            records[index].enabled = enabled
            if enabled { records[index].waits = nil }
        }
        func get(_ id: String) -> BoostRecord? { records.first { $0.id == id } }
    }

    @MainActor
    final class Mac {
        let device: String
        let journal: Journal
        let extensions = ExtensionList()
        let plugins = PluginList()
        var ledger = SyncAddons.Ledger()
        var live = true
        private(set) var mirror: SyncMirror!
        /// What waits to be put in, as the last read said.
        var missing: [Record] = []
        var missingPlugins: [Record] = []

        init(_ device: String) throws {
            self.device = device
            journal = try Journal(path: nil, device: device)
            relaunch()
        }

        /// A new mirror over the kept ledger, as at a launch.
        func relaunch() {
            mirror = SyncMirror(extensions: extensions, plugins: plugins, ledger: ledger) { [unowned self] in ledger = $0 ?? SyncAddons.Ledger() }
            mirror.devices = devices
        }

        var devices: Set<String> = [] { didSet { mirror?.devices = devices } }

        /// A flush: the mirror's read of both, as SyncCenter.flush runs it.
        func flush() throws {
            missing = try mirror.extensions(journal)
            missingPlugins = try mirror.plugins(journal, device: device, live: live)
        }

        /// Everything `other` has pending, through the server, taken in here
        /// as SyncCenter.adopt takes it.
        @discardableResult
        func hear(_ other: Mac) throws -> [Record] {
            let pending = other.journal.pending()
            try other.journal.sent(pending.map { ($0.record, 1) })
            let changed = try journal.receive(pending.map { ($0.record, 1) })
            let by = Dictionary(grouping: changed, by: \.collection)
            if let ext = by[SyncAddons.ext] { missing = try mirror.extensions(journal, changed: Set(ext.map(\.id))) }
            if by[SyncAddons.plugin] != nil || by[SyncAddons.part] != nil {
                missingPlugins = try mirror.plugins(journal, device: device, live: live, changed: Set((by[SyncAddons.plugin] ?? []).map(\.id)),
                                                    parts: Set((by[SyncAddons.part] ?? []).map(\.id)))
            }
            return changed
        }

        /// What waits, put in, as SyncInstalls puts it in.
        func putIn() {
            for record in missing {
                extensions.installed.append(Installed(id: record.id, name: record["name"]?.string ?? "", version: record["version"]?.string ?? "1",
                                                      enabled: record["enabled"]?.bool ?? true, fromStore: true,
                                                      permissions: record["permissions"]?.array?.compactMap(\.string) ?? [],
                                                      pinned: record["pinned"]?.bool))
            }
            for record in missingPlugins {
                guard case .ready(let files, _) = SyncAddons.assemble(record, part: { self.journal.record(.init(collection: SyncAddons.part, id: $0)) }),
                      let package = try? BoostPackage.read(id: record.id, files: files, sites: ["example.com"]) else { continue }
                let kept = plugins.kept[record.id].flatMap { try? BoostPackage.read(id: record.id, files: $0, sites: ["example.com"]) }
                let arrival = SyncAddons.arrival(package, kept: kept, here: plugins.get(record.id), enabled: record["enabled"]?.bool ?? true)
                plugins.keep(record.id, files, enabled: arrival.enabled, runsOn: record["runsOn"]?.string, waits: arrival.waits)
            }
            missing = []
            missingPlugins = []
        }

        func ext(_ id: String) -> Record? { journal.record(.init(collection: SyncAddons.ext, id: id)) }
        func plugin(_ id: String) -> Record? { journal.record(.init(collection: SyncAddons.plugin, id: id)) }
        func part(_ id: String) -> Record? { journal.record(.init(collection: SyncAddons.part, id: id)) }
    }

    private func item(_ id: String = id, version: String = "1.0", enabled: Bool = true, pinned: Bool? = nil,
                      permissions: [String] = ["storage"], store: Bool = true, wants: [String]? = nil) -> Installed {
        Installed(id: id, name: "Extension \(id.prefix(4))", version: version, enabled: enabled, fromStore: store,
                  permissions: permissions, pinned: pinned, wants: wants)
    }

    private func look(lines: Int, tag: String = "row") -> [String: String] {
        let css = (0..<lines).map { ".\(tag)-\($0) { display: none !important; }" }.joined(separator: "\n")
        return ["manifest.json": #"{"manifest_version":3,"name":"Calm feed","version":"1.0","content_scripts":[{"matches":["https://example.com/*"],"css":["style.css"]}]}"#,
                "style.css": css,
                "BOOST.md": "---\nname: Calm feed\nsites: example.com\n---\n\nHide the noise."]
    }

    private func value(_ text: String) -> Value { .string(text) }

    private func page(_ code: String = "document.body.dataset.boost = 'yes';", hosts: [String]? = nil) -> [String: String] {
        BoostTests.pageFiles(hosts: hosts, code: code)
    }

    // MARK: Extensions

    @Test func anExtensionGoesOutAndIsPutInOnTheOtherMac() throws {
        let a = try Mac("a"), b = try Mac("b")
        a.extensions.installed = [item(pinned: true), item("local-1a2b3c4d", store: false)]
        try a.flush()
        // A folder's extension stays on its Mac.
        #expect(a.journal.all(SyncAddons.ext).map(\.id) == [Self.id])
        #expect(a.ext(Self.id)?["pinned"] == .bool(true) && a.ext(Self.id)?["permissions"] == .array(["storage"]))
        try b.hear(a)
        #expect(b.missing.map(\.id) == [Self.id])
        b.putIn()
        try b.flush()
        #expect(b.journal.pending().isEmpty && b.missing.isEmpty)
        #expect(b.extensions.get(Self.id)?.pinned == true)
    }

    @Test func aFreshJoinTakesTheAccountsSaySendsWhatOnlyItHasAndBringsBackWhatWasRemovedLongAgo() throws {
        let a = try Mac("a"), b = try Mac("b")
        a.extensions.installed = [item(enabled: false), item(Self.other), item(Self.third)]
        try a.flush()
        a.extensions.installed.removeAll { $0.id == Self.third }
        try a.flush()
        try b.hear(a)
        // B joins with the first on and pinned, the removed one, and one of its own.
        b.extensions.installed = [item(pinned: true), item(Self.third), item("hdokiejnpimakedhajhdlcegeplioahd")]
        try b.flush()
        #expect(b.extensions.get(Self.id)?.enabled == false && b.extensions.get(Self.id)?.pinned == false)
        #expect(b.ext(Self.id)?["enabled"] == .bool(false))
        #expect(SyncAddons.usable(try #require(b.ext(Self.third))))
        #expect(SyncAddons.usable(try #require(b.ext("hdokiejnpimakedhajhdlcegeplioahd"))))
        #expect(b.missing.map(\.id) == [Self.other])
    }

    @Test func aListThatCouldntBeReadTakesNothingAwayAndTakesNothingIn() throws {
        let a = try Mac("a"), b = try Mac("b")
        a.extensions.installed = [item(), item(Self.other)]
        a.plugins.keep("calm-feed", look(lines: 5))
        try a.flush()
        try b.hear(a)
        b.putIn()
        try b.flush()
        try a.hear(b)
        // installed.json and the boost index unreadable on A (a later
        // Yab's rung): read as empty, not taken for empty.
        a.extensions.installed = []
        a.extensions.loaded = false
        a.plugins.records = []
        a.plugins.loaded = false
        let before = a.ledger
        try a.flush()
        #expect(a.journal.pending().isEmpty && a.ledger == before)
        let ext = try #require(a.ext(Self.id)), plugin = try #require(a.plugin("calm-feed"))
        #expect(SyncAddons.usable(ext) && SyncAddons.usable(plugin))
        // Nor does a removal from elsewhere take anything out of a list
        // that couldn't be read, nor wait to put anything in.
        b.extensions.installed.removeAll { $0.id == Self.id }
        try b.flush()
        try a.hear(b)
        #expect(a.missing.isEmpty && a.journal.pending().isEmpty)
    }

    @Test func removedHereGoesAsARemovalAcrossARelaunchAndIsntPutBack() throws {
        let a = try Mac("a"), b = try Mac("b")
        a.extensions.installed = [item()]
        try a.flush()
        try b.hear(a)
        b.putIn()
        try b.flush()
        // Removed on B, which quits before its next read: the read after
        // the relaunch still knows it had it.
        b.extensions.installed = []
        b.relaunch()
        try b.flush()
        let gone = try #require(b.ext(Self.id))
        #expect(b.missing.isEmpty && !SyncAddons.usable(gone))
        // Its removal holds nothing of it.
        #expect(try #require(b.ext(Self.id)).fields.values.allSatisfy(\.isNull))
        try a.hear(b)
        #expect(a.extensions.installed.isEmpty)
    }

    @Test func aRemovalWinsOverAChangeMadeAtTheSameTimeAndAnInstallBringsItBack() throws {
        let a = try Mac("a"), b = try Mac("b")
        a.extensions.installed = [item()]
        try a.flush()
        try b.hear(a)
        b.putIn()
        try b.flush()
        // A removes it while B, not having heard, pins it.
        a.extensions.installed = []
        try a.flush()
        b.extensions.installed = [item(pinned: true)]
        try b.flush()
        let toB = a.journal.pending(), toA = b.journal.pending()
        try a.journal.sent(toB.map { ($0.record, 2) })
        try b.journal.sent(toA.map { ($0.record, 2) })
        let changedB = try b.journal.receive(toB.map { ($0.record, 2) })
        _ = try a.journal.receive(toA.map { ($0.record, 2) })
        let onA = try #require(a.ext(Self.id)), onB = try #require(b.ext(Self.id))
        #expect(!SyncAddons.usable(onA) && !SyncAddons.usable(onB))
        try b.mirror.extensions(b.journal, changed: Set(changedB.map(\.id)))
        #expect(b.extensions.installed.isEmpty)
        try a.hear(b)
        #expect(a.missing.isEmpty)
        // Installed again on A, after hearing all of that: back on B too.
        a.extensions.installed = [item()]
        try a.flush()
        try b.hear(a)
        #expect(b.missing.map(\.id) == [Self.id])
    }

    @Test func theSwitchOnAgainTakesWhatChangedElsewhereAndSendsOnlyWhatChangedHere() throws {
        let fourth = "fdjamakpfbbddfjaooikfcpapjohcfmg"
        let a = try Mac("a"), b = try Mac("b")
        a.extensions.installed = [item(), item(Self.other), item(Self.third)]
        a.plugins.keep("calm-feed", look(lines: 5))
        a.plugins.states["calm-feed"] = #"{"ticks":1}"#
        try a.flush()
        try b.hear(a)
        b.putIn()
        try b.flush()
        try a.hear(b)
        // B's switch goes off: its reads stop, what it agreed on stays.
        // A turns one off and pins it, removes another, adds a fourth, and
        // ticks the plugin on. B removes the third and turns the second off.
        a.extensions.installed = [item(enabled: false, pinned: true), item(Self.third), item(fourth)]
        a.plugins.states["calm-feed"] = #"{"ticks":9}"#
        try a.flush()
        _ = try b.journal.receive(a.journal.pending().map { ($0.record, 1) })
        try a.journal.sent(a.journal.pending().map { ($0.record, 1) })
        b.extensions.installed = [item(), item(Self.other, enabled: false)]
        // On again: one read.
        try b.flush()
        // The account's changes, here: off and pinned, the removal, the
        // newer state, the fourth to put in.
        #expect(b.extensions.get(Self.id)?.enabled == false && b.extensions.get(Self.id)?.pinned == true)
        #expect(b.extensions.get(Self.other) == nil)
        #expect(b.plugins.states["calm-feed"] == #"{"ticks":9}"#)
        #expect(b.missing.map(\.id) == [fourth])
        // And none of B's stale values went back.
        #expect(b.ext(Self.id)?["enabled"] == .bool(false) && b.plugin("calm-feed")?["state"] == #"{"ticks":9}"#)
        // B's own: the third's removal; the second was removed elsewhere,
        // which wins over B turning it off.
        let third = try #require(b.ext(Self.third)), other = try #require(b.ext(Self.other))
        #expect(!SyncAddons.usable(third) && !SyncAddons.usable(other))
        try a.hear(b)
        #expect(a.extensions.get(Self.id)?.enabled == false && a.extensions.get(Self.third) == nil)
        #expect(a.plugins.states["calm-feed"] == #"{"ticks":9}"#)
    }

    @Test func aChangeHereNotYetSentIsntUndoneByOneComingIn() throws {
        let a = try Mac("a"), b = try Mac("b")
        a.extensions.installed = [item()]
        a.plugins.keep("calm-feed", look(lines: 5))
        try a.flush()
        try b.hear(a)
        b.putIn()
        try b.flush()
        // B turns both off; before its flush, A's pin and A's state tick come in.
        b.extensions.installed[0].enabled = false
        if let index = b.plugins.records.firstIndex(where: { $0.id == "calm-feed" }) { b.plugins.records[index].enabled = false }
        a.extensions.installed = [item(pinned: true)]
        a.plugins.states["calm-feed"] = #"{"ticks":2}"#
        try a.flush()
        try b.hear(a)
        #expect(b.extensions.get(Self.id)?.enabled == false && b.extensions.get(Self.id)?.pinned == true)
        #expect(b.plugins.get("calm-feed")?.enabled == false && b.plugins.states["calm-feed"] == #"{"ticks":2}"#)
        try a.hear(b)
        #expect(a.extensions.get(Self.id)?.enabled == false && a.plugins.get("calm-feed")?.enabled == false)
    }

    @Test func versionsAndWhatWasAllowedOnlyGrow() throws {
        let a = try Mac("a")
        a.extensions.installed = [item(version: "2.0", permissions: ["storage", "tabs"])]
        try a.flush()
        try a.journal.sent(a.journal.pending().map { ($0.record, 1) })
        // A Mac still on 1.0, allowed less, doesn't write that back.
        a.extensions.installed = [item(version: "1.0")]
        try a.flush()
        #expect(a.journal.pending().isEmpty)
        #expect(a.ext(Self.id)?["version"] == "2.0" && a.ext(Self.id)?["permissions"] == .array(["storage", "tabs"]))
        #expect(SyncAddons.newer("1.10", than: "1.9") && SyncAddons.newer("2", than: "1.9.9"))
        #expect(!SyncAddons.newer("1.0", than: "1") && !SyncAddons.newer("1.2", than: "1.10"))
    }

    @Test func aVersionThatAsksForMoreThanWasAllowedComesInOffAndIsntTheirChoice() throws {
        let more = SyncAddons.arrival(grants: ["site:<all_urls>", "storage", "tabs"], enabled: true, allowed: ["storage", "tabs"])
        #expect(more == .init(enabled: false, permissions: ["storage", "tabs"], wants: ["site:<all_urls>"]))
        #expect(SyncAddons.arrival(grants: ["storage"], enabled: true, allowed: ["storage", "tabs"]) == .init(enabled: true, permissions: ["storage"], wants: nil))
        let a = try Mac("a"), b = try Mac("b")
        a.extensions.installed = [item()]
        try a.flush()
        try b.hear(a)
        b.extensions.installed = [item(enabled: false, wants: ["site:<all_urls>"])]
        try b.flush()
        #expect(b.journal.pending().isEmpty && b.ext(Self.id)?["enabled"] == .bool(true))
        // A pin from elsewhere doesn't turn it on here.
        a.extensions.installed = [item(pinned: true)]
        try a.flush()
        try b.hear(a)
        #expect(b.extensions.get(Self.id)?.enabled == false)
    }

    @Test func whatIsPutInIsAskedAgainRightBefore() throws {
        let a = try Mac("a"), b = try Mac("b")
        a.extensions.installed = [item()]
        a.plugins.keep("calm-feed", look(lines: 5))
        try a.flush()
        try b.hear(a)
        let key = Record.Key(collection: SyncAddons.ext, id: Self.id)
        #expect(b.mirror.wanted(key, in: b.journal))
        // Removed on A while B was unpacking it: not put in.
        a.extensions.installed = []
        try a.flush()
        try b.hear(a)
        #expect(!b.mirror.wanted(key, in: b.journal))
        // A plugin deleted here, its removal not sent yet: not put back.
        b.putIn()
        try b.flush()
        b.plugins.remove("calm-feed")
        #expect(!b.mirror.wanted(.init(collection: SyncAddons.plugin, id: "calm-feed"), in: b.journal))
    }

    // MARK: Plugins

    @Test func aPluginOfYourOwnGoesInPartsAndComesBackWhole() throws {
        let files = look(lines: 3_000)
        let a = try Mac("a"), b = try Mac("b")
        a.plugins.keep("calm-feed", files)
        try a.flush()
        let record = try #require(a.plugin("calm-feed"))
        let digest = try #require(record["digest"]?.string)
        let names = try #require(record["parts"]?.array).compactMap(\.string)
        #expect(names.count >= 3 && names.enumerated().allSatisfy { $0.element == "\(digest)/\($0.offset)" })
        #expect(names.allSatisfy { (SyncAddons.bytes(a.part($0)?["data"]?.string ?? "")?.count ?? .max) <= SyncAddons.partSize })
        try b.hear(a)
        #expect(b.missingPlugins.map(\.id) == ["calm-feed"])
        b.putIn()
        #expect(b.plugins.kept["calm-feed"] == files)
        try b.flush()
        #expect(b.journal.pending().isEmpty && b.ledger.plugins["calm-feed"]?.digest == digest)
    }

    @Test func aPartFitsWhatTheServerTakesAndItsRemovalHoldsNothing() throws {
        // The worst a part could be: bytes that are all slashes in plain
        // base64, which JSON would write twice as long.
        let data = Data(repeating: 0xFF, count: SyncAddons.partSize)
        let digest = String(repeating: "f", count: 64)
        let j = try Journal(path: nil, device: "a")
        try j.reconcile(SyncAddons.part, ["\(digest)/0": ["data": .string(SyncAddons.text(data))]])
        let seal = Seal.make()
        let record = try #require(j.all(SyncAddons.part).first)
        #expect(try seal.seal(record).base64EncodedString().count <= 96 * 1024)
        try j.reconcile(SyncAddons.part, [:], blank: true)
        let gone = try #require(j.all(SyncAddons.part).first)
        #expect(!gone.alive() && gone.fields["data"] == .null)
        #expect(try seal.seal(gone).count < 1_000)
    }

    @Test func partsNothingNamesGoWithTheirDataAndAPluginSentAgainSendsNothing() throws {
        let a = try Mac("a")
        a.plugins.keep("calm-feed", look(lines: 1_500))
        try a.flush()
        let first = try #require(a.plugin("calm-feed")?["digest"]?.string)
        try a.journal.sent(a.journal.pending().map { ($0.record, 1) })
        try a.flush()
        #expect(a.journal.pending().isEmpty)
        a.plugins.keep("calm-feed", look(lines: 1_600))
        try a.flush()
        let old = a.journal.all(SyncAddons.part).filter { $0.id.hasPrefix(first + "/") }
        #expect(!old.isEmpty && old.allSatisfy { !$0.alive() && $0.fields["data"] == .null })
        // Put back to the first version: its parts are written again.
        a.plugins.keep("calm-feed", look(lines: 1_500))
        try a.flush()
        #expect(a.journal.living(SyncAddons.part).contains { $0.id.hasPrefix(first + "/") })
    }

    @Test func aMacCatchingUpNeverTakesBackPartsItDidntGive() throws {
        let a = try Mac("a"), c = try Mac("c")
        a.plugins.keep("calm-feed", look(lines: 2_000))
        a.plugins.keep("wide", look(lines: 10, tag: "wide"))
        try a.flush()
        // C takes the parts in a page before their record: only "wide"'s
        // record comes with them, the other plugin's in a later page.
        let pending = a.journal.pending()
        try a.journal.sent(pending.map { ($0.record, 1) })
        let first = pending.filter { !($0.record.collection == SyncAddons.plugin && $0.record.id == "calm-feed") }
        let rest = pending.filter { $0.record.collection == SyncAddons.plugin && $0.record.id == "calm-feed" }
        c.live = false
        let changed = try c.journal.receive(first.map { ($0.record, 1) })
        c.missingPlugins = try c.mirror.plugins(c.journal, device: "c", live: false, changed: Set(changed.filter { $0.collection == SyncAddons.plugin }.map(\.id)),
                                                parts: Set(changed.filter { $0.collection == SyncAddons.part }.map(\.id)))
        #expect(c.missingPlugins.map(\.id) == ["wide"])
        c.putIn()
        try c.flush()
        // Live already, it still takes back only parts it gave itself.
        c.live = true
        try c.flush()
        #expect(c.journal.all(SyncAddons.part).allSatisfy { $0.alive() })
        _ = try c.journal.receive(rest.map { ($0.record, 1) })
        try c.flush()
        #expect(c.missingPlugins.map(\.id) == ["calm-feed"])
        c.putIn()
        #expect(c.plugins.kept["calm-feed"] == look(lines: 2_000))
    }

    @Test func theMacThatGaveAPartWritesItAgainWhenItGoesElsewhere() throws {
        let a = try Mac("a"), b = try Mac("b")
        a.plugins.keep("calm-feed", look(lines: 10))
        try a.flush()
        try b.hear(a)
        let part = try #require(a.plugin("calm-feed")?["parts"]?.array?.first?.string)
        // An older or broken Mac removes it.
        try b.journal.remove(.init(collection: SyncAddons.part, id: part))
        try a.hear(b)
        #expect(a.part(part)?.alive() == true && a.part(part)?["data"] != nil)
    }

    @Test func aChangeElsewhereComesInAndAChangeHereGoesUp() throws {
        let a = try Mac("a"), b = try Mac("b")
        a.plugins.keep("calm-feed", look(lines: 5))
        try a.flush()
        try b.hear(a)
        b.putIn()
        try b.flush()
        try a.hear(b)
        // A changes it; B, unchanged since, puts A's in, and meanwhile
        // turning it off here still goes up.
        a.plugins.keep("calm-feed", look(lines: 6))
        try a.flush()
        try b.hear(a)
        #expect(b.missingPlugins.map(\.id) == ["calm-feed"])
        if let index = b.plugins.records.firstIndex(where: { $0.id == "calm-feed" }) { b.plugins.records[index].enabled = false }
        // And so does its state, ticked here while A's version waits.
        b.plugins.states["calm-feed"] = #"{"ticks":5}"#
        try b.flush()
        #expect(b.plugin("calm-feed")?["enabled"] == .bool(false) && b.plugin("calm-feed")?["digest"] == a.plugin("calm-feed")?["digest"])
        #expect(b.plugin("calm-feed")?["state"] == #"{"ticks":5}"#)
        // B changes its own copy instead: B's goes up.
        b.plugins.keep("calm-feed", look(lines: 7), enabled: false)
        try b.flush()
        #expect(b.plugin("calm-feed")?["digest"] != a.plugin("calm-feed")?["digest"] && b.missingPlugins.isEmpty)
    }

    @Test func aPluginRemovedElsewhereComesOutHereButNotOneThisMacNeverAgreedOn() throws {
        let a = try Mac("a"), b = try Mac("b")
        a.plugins.keep("calm-feed", look(lines: 5))
        try a.flush()
        try b.hear(a)
        b.putIn()
        try b.flush()
        // Removed on A while B's switch was off: on again, out of B.
        a.plugins.remove("calm-feed")
        try a.flush()
        _ = try b.journal.receive(a.journal.pending().map { ($0.record, 1) })
        try b.flush()
        #expect(b.plugins.records.isEmpty)
        // A Mac that never agreed on it with this account (left and joined
        // again: its ledger went with sync) sends it again instead.
        let c = try Mac("c")
        _ = try c.journal.receive(a.journal.all(SyncAddons.plugin).map { ($0, 1) })
        c.plugins.keep("calm-feed", look(lines: 5))
        try c.flush()
        let back = try #require(c.plugin("calm-feed"))
        #expect(SyncAddons.usable(back) && c.plugins.get("calm-feed") != nil)
    }

    @Test func aPluginWhoseFilesChangedOutsideKeepIsLeftAlone() throws {
        let a = try Mac("a"), b = try Mac("b")
        a.plugins.keep("calm-feed", look(lines: 5))
        try a.flush()
        try b.hear(a)
        b.putIn()
        try b.flush()
        b.plugins.unreadable = ["calm-feed"]
        a.plugins.keep("calm-feed", look(lines: 6))
        try a.flush()
        try b.hear(a)
        #expect(b.missingPlugins.isEmpty)
        a.plugins.remove("calm-feed")
        try a.flush()
        try b.hear(a)
        #expect(b.plugins.get("calm-feed") != nil)
    }

    @Test func aPluginsStateGoesWhenTheRecordFitsAndAMacWithoutOneTakesNothingAway() throws {
        let a = try Mac("a"), b = try Mac("b")
        a.plugins.keep("calm-feed", look(lines: 5))
        a.plugins.states["calm-feed"] = #"{"seen":3}"#
        try a.flush()
        #expect(a.plugin("calm-feed")?["state"] == #"{"seen":3}"#)
        try b.hear(a)
        b.putIn()
        try b.flush()
        #expect(b.plugins.states["calm-feed"] == #"{"seen":3}"# && b.journal.pending().isEmpty)
        // Under 48 KB of words, but quotes JSON writes twice: too big. It
        // stays on B, and B doesn't take A's over it either.
        let quotes = "{\"k\":\"" + String(repeating: "\\\"", count: 23_000) + "\"}"
        #expect(quotes.utf8.count < 48_000)
        b.plugins.states["calm-feed"] = quotes
        try b.flush()
        #expect(b.plugin("calm-feed")?["state"] == #"{"seen":3}"#)
        a.plugins.states["calm-feed"] = #"{"seen":4}"#
        try a.flush()
        try b.hear(a)
        #expect(b.plugins.states["calm-feed"] == quotes)
    }

    @Test func oneMacTicksAPluginGivesItUpForGoodAndAnotherTakesIt() throws {
        let a = try Mac("a"), b = try Mac("b")
        a.plugins.keep("calm-feed", look(lines: 5))
        try a.flush()
        #expect(a.plugin("calm-feed")?["runsOn"] == "a" && a.plugins.get("calm-feed")?.runsOn == "a")
        try b.hear(a)
        b.putIn()
        try b.flush()
        #expect(b.plugins.get("calm-feed")?.runsOn == "a")
        var mine = try #require(b.plugins.get("calm-feed"))
        #expect(!mine.runs(on: "b", syncing: true) && mine.runs(on: "b", syncing: false))
        // A gives it up (its switch or sync going off): its next reads don't
        // take it back, and B, present, takes it.
        #expect(a.mirror.giveUp(a.journal, device: "a").map(\.id) == ["calm-feed"])
        try a.flush()
        #expect(a.plugin("calm-feed")?["runsOn"] == nil && a.plugins.get("calm-feed")?.runsOn == nil)
        b.devices = ["a", "b"]
        try b.hear(a)
        #expect(b.plugin("calm-feed")?["runsOn"] == "b")
        mine = try #require(b.plugins.get("calm-feed"))
        #expect(mine.runs(on: "b", syncing: true))
        // Only one kept and on here is taken; a Mac away two days gives its own up.
        #expect(SyncAddons.orphaned(b.journal.all(SyncAddons.plugin), devices: ["a"], me: "a", on: []).isEmpty)
        let now = Date()
        #expect(SyncAddons.present([(id: "a", seen: now), (id: "b", seen: now.addingTimeInterval(-3 * 86_400)), (id: "c", seen: nil)], now: now) == ["a", "c"])
        #expect(SyncAddons.orphaned(b.journal.all(SyncAddons.plugin), devices: ["a"], me: "a", on: ["calm-feed"]) == ["calm-feed"])
    }

    @Test func aStoreReleaseGoesAsTheReleaseAndCodeOnlyAsTheFreshCatalogsReviewedOne() throws {
        let files = look(lines: 10)
        let revision = try BoostShare.digest(.init(format: 1, id: "calm-feed-store", sites: ["example.com"], files: files))
        #expect(SyncAddons.isRelease(revision, catalog: "calm-feed-store", sites: ["example.com"], files: files))
        let a = try Mac("a")
        a.plugins.keep("calm-feed-store", files)
        a.plugins.origins["calm-feed-store"] = ("calm-feed-store", revision)
        try a.flush()
        let record = try #require(a.plugin("calm-feed-store"))
        #expect(record["store"] == "calm-feed-store" && record["revision"] == .string(revision) && record["parts"] == nil)
        #expect(a.journal.all(SyncAddons.part).isEmpty)
        let reviewed = StoreCatalog.Reviewed(by: "samrivera", date: "2026-10-01", commit: "abc1234")
        let listed = String(repeating: "a", count: 64), older = String(repeating: "b", count: 64)
        let listing = StoreCatalog.Item(id: "sponsor-skip", name: "Sponsor skip", intent: "Skip", sites: ["youtube.com"], host: "youtube.com",
                                        rung: "Page", rights: "", revision: listed, commit: nil, by: "Yab", picks: nil, added: nil, fixed: nil,
                                        check: nil, kept: nil, pictures: nil, versions: nil, reviewed: reviewed)
        let site = URL(string: "https://yetanotherbrowser.com/store/catalog.json")
        func check(_ rung: BoostPackage.Rung, _ revision: String, _ listing: StoreCatalog.Item?, origin: URL? = site, fresh: Bool = true) -> SyncAddons.StoreCheck {
            SyncAddons.storeCheck(rung: rung, revision: revision, listing: listing, origin: origin, listed: listing.map { [$0] } ?? [], fresh: fresh)
        }
        #expect(check(.page, listed, listing) == .code)
        #expect(check(.page, older, listing) != .code)
        // A record saying Look of a listing the Store says is code is code.
        #expect(check(.look, older, listing) != .code && check(.look, older, listing) != .look)
        #expect(check(.page, listed, nil) != .code)
        #expect(check(.page, listed, listing, origin: URL(string: "https://example.com/catalog.json")) != .code)
        // A catalog of any age vouches for nothing: it waits for a fresh one.
        #expect(check(.page, listed, listing, fresh: false) == .catalog("The Store's list here is old"))
        #expect(check(.look, older, nil, origin: nil, fresh: false) == .look)
    }

    // MARK: Code from another Mac

    @Test func aCodeBoostFromAnotherMacComesInOffAndWaitsWithoutTurningTheOthersOff() throws {
        let a = try Mac("a"), b = try Mac("b")
        a.plugins.keep("skip", page())
        a.plugins.keep("calm-feed", look(lines: 5))
        try a.flush()
        #expect(a.plugin("skip")?["rung"] == "Page" && a.plugin("skip")?["enabled"] == .bool(true))
        try b.hear(a)
        b.putIn()
        try b.flush()
        // The look comes on as it is on A; the code comes in off and waits.
        #expect(b.plugins.get("calm-feed")?.enabled == true && b.plugins.get("calm-feed")?.waits == nil)
        #expect(b.plugins.get("skip")?.enabled == false && b.plugins.get("skip")?.waits == true)
        // B's off goes nowhere: the account and A keep it on.
        #expect(b.plugin("skip")?["enabled"] == .bool(true) && b.journal.pending().isEmpty)
        try a.hear(b)
        #expect(a.plugins.get("skip")?.enabled == true)
        // A turns it off and on again: B stays off and waiting, and sends nothing.
        a.plugins.set("skip", false)
        try a.flush()
        try b.hear(a)
        #expect(b.plugin("skip")?["enabled"] == .bool(false) && b.plugins.get("skip")?.enabled == false)
        a.plugins.set("skip", true)
        try a.flush()
        try b.hear(a)
        try b.flush()
        #expect(b.plugins.get("skip")?.enabled == false && b.plugins.get("skip")?.waits == true && b.journal.pending().isEmpty)
        // A relaunch keeps it waiting.
        b.relaunch()
        try b.flush()
        #expect(b.plugins.get("skip")?.enabled == false && b.journal.pending().isEmpty)
    }

    @Test func turningAWaitingCodeBoostOnHereClearsTheMarkAndGoesAsAChange() throws {
        let a = try Mac("a"), b = try Mac("b")
        a.plugins.keep("skip", page())
        try a.flush()
        try b.hear(a)
        b.putIn()
        try b.flush()
        // Turned off on A meanwhile; B's yes is B's own, and goes up.
        a.plugins.set("skip", false)
        try a.flush()
        try b.hear(a)
        b.plugins.set("skip", true)
        #expect(b.plugins.get("skip")?.waits == nil)
        try b.flush()
        #expect(b.plugin("skip")?["enabled"] == .bool(true))
        try a.hear(b)
        #expect(a.plugins.get("skip")?.enabled == true)
        // From then on it follows the account as any plugin does.
        a.plugins.set("skip", false)
        try a.flush()
        try b.hear(a)
        #expect(b.plugins.get("skip")?.enabled == false)
        a.plugins.set("skip", true)
        try a.flush()
        try b.hear(a)
        #expect(b.plugins.get("skip")?.enabled == true)
    }

    @Test func aNewVersionOfCodeSaidYesToComesAsItIsUnlessItAsksForMore() throws {
        let a = try Mac("a"), b = try Mac("b")
        a.plugins.keep("skip", page(hosts: ["api.example.com"]))
        try a.flush()
        try b.hear(a)
        b.putIn()
        b.plugins.set("skip", true)
        try b.flush()
        try a.hear(b)
        // The same rights, new code: on, as it was.
        a.plugins.keep("skip", page("document.title = 'new';", hosts: ["api.example.com"]))
        try a.flush()
        try b.hear(a)
        b.putIn()
        try b.flush()
        #expect(b.plugins.kept["skip"]?["page.js"] == "document.title = 'new';")
        #expect(b.plugins.get("skip")?.enabled == true && b.plugins.get("skip")?.waits == nil)
        // A look turning into code, or code asking for another host: off, waiting.
        a.plugins.keep("skip", page("document.title = 'wider';", hosts: ["api.example.com", "other.example.org"]))
        a.plugins.keep("calm-feed", look(lines: 5))
        try a.flush()
        try b.hear(a)
        b.putIn()
        try b.flush()
        try a.hear(b)
        a.plugins.keep("calm-feed", page())
        try a.flush()
        try b.hear(a)
        b.putIn()
        try b.flush()
        for id in ["skip", "calm-feed"] {
            #expect(b.plugins.get(id)?.enabled == false && b.plugins.get(id)?.waits == true)
            #expect(b.plugin(id)?["enabled"] == .bool(true))
        }
    }

    @Test func onlyCodeNeverSaidYesToWaits() throws {
        let plain = try BoostPackage.read(id: "skip", files: look(lines: 3), sites: ["example.com"])
        let code = try BoostPackage.read(id: "skip", files: page(hosts: ["api.example.com"]), sites: ["example.com"])
        let same = try BoostPackage.read(id: "skip", files: page("document.title = 'x';", hosts: ["api.example.com"]), sites: ["example.com"])
        let wider = try BoostPackage.read(id: "skip", files: page(hosts: ["api.example.com", "other.example.org"]), sites: ["example.com"])
        let said = BoostRecord(id: "skip", name: "Skip", sites: ["example.com"], rung: .page, intent: "", author: "You", session: "",
                               revision: "r", updated: Date())
        var waiting = said; waiting.waits = true
        let on = SyncAddons.PluginArrival(enabled: true, waits: false), off = SyncAddons.PluginArrival(enabled: false, waits: false)
        let held = SyncAddons.PluginArrival(enabled: false, waits: true)
        #expect(SyncAddons.arrival(plain, kept: nil, here: nil, enabled: true) == on)
        #expect(SyncAddons.arrival(plain, kept: nil, here: nil, enabled: false) == off)
        #expect(SyncAddons.arrival(code, kept: nil, here: nil, enabled: true) == held)
        #expect(SyncAddons.arrival(same, kept: code, here: said, enabled: true) == on)
        #expect(SyncAddons.arrival(same, kept: code, here: said, enabled: false) == off)
        #expect(SyncAddons.arrival(same, kept: code, here: waiting, enabled: true) == held)
        #expect(SyncAddons.arrival(wider, kept: code, here: said, enabled: true) == held)
        #expect(SyncAddons.arrival(code, kept: plain, here: said, enabled: true) == held)
        // Kept here but unreadable: nothing to compare with, so it waits.
        #expect(SyncAddons.arrival(same, kept: nil, here: said, enabled: true) == held)
    }

    @Test func onlyWhatPuttingItInDependsOnTriesItAgain() throws {
        var record = Record(collection: SyncAddons.plugin, id: "p", fields: ["name": "P", "digest": "d1", "rung": "Look", "state": #"{"a":1}"#])
        let before = SyncAddons.signature(record)
        record.fields["state"] = #"{"a":2}"#
        record.fields["enabled"] = false
        record.fields["runsOn"] = "b"
        #expect(SyncAddons.signature(record) == before)
        record.fields["digest"] = "d2"
        #expect(SyncAddons.signature(record) != before)
        #expect(SyncInstalls.backoff(1) == 60 && SyncInstalls.backoff(2) == 300 && SyncInstalls.backoff(3) == 900 && SyncInstalls.backoff(40) == 3600)
        #expect(SyncInstalls.State.refused.words == "Couldn't install" && SyncInstalls.State.newer.words == "Needs a newer Yab")
        #expect(SyncInstalls.passing(URLError(.notConnectedToInternet)) && SyncInstalls.passing(Crx.Refused.download(503)))
        #expect(SyncInstalls.passing(BoostShare.Busy()) && !SyncInstalls.passing(Crx.Refused.download(404)))
        #expect(!SyncInstalls.passing(SyncInstalls.Refused("not the other Mac's files")) && !SyncInstalls.passing(Crx.Refused.empty))
        // Stand-ins: a file of the folder, never one outside it.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("standins-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("crx".utf8).write(to: folder.appendingPathComponent(Self.id + ".crx"))
        #expect(try SyncInstalls.standIn(Self.id + ".crx", in: folder.path) == Data("crx".utf8))
        #expect(throws: (any Error).self) { try SyncInstalls.standIn("../" + folder.lastPathComponent + "/" + Self.id + ".crx", in: folder.path) }
        #expect(throws: (any Error).self) { try SyncInstalls.standIn(Self.id + ".crx", in: nil) }
    }

    @Test(arguments: [false, true]) func aNewPackageWhileDownloadingIsStillPutIn(oldFails: Bool) async throws {
        var account = Record(collection: SyncAddons.plugin, id: "p", fields: ["name": "P", "digest": "old", "rung": "Look"])
        var attempts = [String]()
        var release: CheckedContinuation<Void, Never>?
        let queue = SyncInstalls(record: { _ in account }, putIn: { _ in
            attempts.append(account["digest"]?.string ?? "")
            if attempts.count == 1 {
                await withCheckedContinuation { release = $0 }
                if oldFails { throw SyncInstalls.Coming() }
            }
        })
        defer { queue.clear() }
        queue.want(SyncAddons.plugin, [account])
        for _ in 0..<200 where release == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        let first = try #require(release)
        account.fields["digest"] = "new"
        queue.want(SyncAddons.plugin, [account])
        #expect(attempts == ["old"])
        first.resume()
        for _ in 0..<200 where !queue.waiting.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(attempts == ["old", "new"])
        #expect(queue.waiting.isEmpty)
    }

    @Test func leavingAndJoiningWhileDownloadingKeepsTheNewAccountsRequest() async throws {
        let account = Record(collection: SyncAddons.plugin, id: "p", fields: ["name": "P", "digest": "same", "rung": "Look"])
        var attempts = 0
        var release: CheckedContinuation<Void, Never>?
        let queue = SyncInstalls(record: { _ in account }, putIn: { _ in
            attempts += 1
            if attempts == 1 {
                await withCheckedContinuation { release = $0 }
                throw SyncInstalls.Unreached("Old account's request failed")
            }
        })
        defer { queue.clear() }
        queue.want(SyncAddons.plugin, [account])
        for _ in 0..<200 where release == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        let first = try #require(release)
        queue.clear()
        queue.want(SyncAddons.plugin, [account])
        first.resume()
        for _ in 0..<200 where !queue.waiting.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(attempts == 2)
        #expect(queue.waiting.isEmpty)
    }

    @Test func aCatalogWaitKeepsItsBackoffWhileThePluginStateChanges() async throws {
        var account = Record(collection: SyncAddons.plugin, id: "p", fields: ["name": "P", "digest": "same", "rung": "Page"])
        var attempts = 0
        let queue = SyncInstalls(record: { _ in account }, putIn: { _ in
            attempts += 1
            throw SyncInstalls.Catalog("The Store's list here is old")
        })
        defer { queue.clear() }
        queue.want(SyncAddons.plugin, [account])
        for _ in 0..<200 where queue.waiting["plugin/p"]?.catalog != true { try await Task.sleep(nanoseconds: 10_000_000) }
        let held = try #require(queue.waiting["plugin/p"])
        #expect(held.catalog && held.tries == 1 && held.next > Date())
        account.fields["state"] = #"{"ticks":2}"#
        queue.want(SyncAddons.plugin, [account])
        #expect(attempts == 1 && queue.waiting["plugin/p"]?.next == held.next)
    }

    // MARK: What goes with the switch, and what older Yabs keep

    @Test func aPluginsRoutinesStayOnTheirMacAndOlderYabsKeepTheirs() throws {
        let j = try Journal(path: nil, device: "a")
        // An older Yab's routine record for a plugin's routine.
        try j.reconcile(SyncShapes.routine, ["boost:calm-feed:daily": ["when": "daily 9:00", "prompt": "Check the feed"]])
        let mine = Routine(id: "r1", when: "daily 9:00", prompt: "Check the news", last: Date())
        let plugins = Routine(id: "boost:calm-feed:daily", when: "daily 9:00", prompt: "Check the feed", last: Date())
        try SyncShapes.reconcileRoutines(j, [mine, plugins], device: "a")
        #expect(j.record(.init(collection: SyncShapes.routine, id: "boost:calm-feed:daily"))?.alive() == true)
        try SyncShapes.reconcileRoutines(j, [mine], device: "a")
        #expect(j.record(.init(collection: SyncShapes.routine, id: "boost:calm-feed:daily"))?.alive() == true)
        #expect(SyncShapes.routines(from: j.all(SyncShapes.routine)).map(\.id) == ["r1"])
    }

    @Test func anExtensionsOwnSettingsGoWithTheSwitch() throws {
        let j = try Journal(path: nil, device: "a")
        let key = "extensions.access.\(Self.id)"
        try SyncShapes.reconcileSettings(j, [key: "sites", "look": "glass"], addons: true)
        try j.sent(j.pending().map { ($0.record, 1) })
        // Off: removing the extension here clears its settings here, and
        // nothing of that goes.
        try SyncShapes.reconcileSettings(j, ["look": "glass"], addons: false)
        #expect(j.pending().isEmpty && j.record(.init(collection: SyncShapes.setting, id: key))?.alive() == true)
        try SyncShapes.reconcileSettings(j, ["look": "glass"], addons: true)
        #expect(j.record(.init(collection: SyncShapes.setting, id: key))?.alive() == false)
    }

    @Test func offStopsReadingThem() {
        let collections: Set<String> = [SyncShapes.tab, SyncAddons.ext, SyncAddons.plugin, SyncAddons.part]
        #expect(SyncAddons.due(collections, on: false) == [SyncShapes.tab])
        #expect(SyncAddons.due(collections, on: true) == collections)
    }

    @Test func partsThatDontMakeTheFilesAreNotPutIn() throws {
        let a = try Mac("a")
        a.plugins.keep("calm-feed", look(lines: 2_000))
        try a.flush()
        let record = try #require(a.plugin("calm-feed"))
        let names = try #require(record["parts"]?.array).compactMap(\.string)
        var parts: [String: [String: Value]] = [:]
        for name in names { parts[name] = a.part(name)?.visible }
        func part(_ id: String) -> Record? { parts[id].map { Record(collection: SyncAddons.part, id: id, fields: $0) } }
        #expect(SyncAddons.assemble(record, part: part) != .waiting)
        let held = parts.removeValue(forKey: names[0])
        #expect(SyncAddons.assemble(record, part: part) == .waiting)
        let text = try #require(held?["data"]?.string)
        var bytes = try #require(SyncAddons.bytes(text))
        bytes[10] ^= 0x20
        parts[names[0]] = ["data": .string(SyncAddons.text(bytes))]
        #expect(SyncAddons.assemble(record, part: part) == .broken)
        var later = record
        later.fields["rung"] = "Gadget"
        #expect(SyncAddons.assemble(later, part: part) == .newer)
        later = record
        later.schema = SyncAddons.schema + 1
        #expect(SyncAddons.assemble(later, part: part) == .newer)
    }
}
