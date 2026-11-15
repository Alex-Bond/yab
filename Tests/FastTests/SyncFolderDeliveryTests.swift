import Foundation
import Testing
import SyncKit
@testable import Fast

/// A fresh Mac (Yab deleted and installed again) takes the account's
/// spaces in catch-up pages ordered by sequence, not by space. A folder
/// opened, renamed or moved after its tabs were last written has the newer
/// sequence, so it comes pages after them; a folder can also come before
/// or after the folder it is in. Between pages the Mac saves its rows. A
/// row can't draw a folder whose record hasn't come, and that save must
/// not take tabs out of their folders or remove folders, here or on the
/// Mac that has them.
@MainActor
@Suite(.serialized)
struct SyncFolderDeliveryTests {
    init() { SyncShapes.register() }

    struct Folder {
        let id = UUID().uuidString
        let name: String
        var step: Session.Step { Session.Step(id: id, name: name, open: true, mark: nil) }
    }

    /// A kept tab, in `folder` when given, that folder inside `path`.
    static func kept(_ name: String, in folder: Folder? = nil, path: [Folder] = []) -> Session.Entry {
        Session.Entry(url: "https://folders.test/\(name)", title: name, kept: true, folder: folder?.id, folderName: folder?.name,
                      folderOpen: folder == nil ? nil : true, folderPath: path.isEmpty ? nil : path.map(\.step), id: "tab-\(name)-\(UUID().uuidString)")
    }

    /// Each tab's folders from the top down, the one it is right in last.
    static func structure(_ rows: [Session.Shape]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for entry in rows.flatMap(\.tabs) {
            guard let id = entry.id else { continue }
            out[id] = (entry.folderPath ?? []).map(\.id) + [entry.folder].compactMap { $0 }
        }
        return out
    }

    @Test func aFreshMacKeepsFoldersWhoseRecordsComeAfterTheirTabs() throws {
        #expect(Store.testing)
        let original = Spaces.read()
        let spaces = ["Work", "Home", "Research", "Crypto"].map { Space(id: UUID(), name: $0, icon: String($0.prefix(1)), ownSignIns: false) }
        defer {
            Spaces.write(original)
            for space in spaces { Session.erase(space: space.id) }
        }
        // Mac A: four spaces of kept tabs in folders, two of them nested.
        let reading = Folder(name: "Reading"), docs = Folder(name: "Docs")
        let projects = Folder(name: "Projects"), yab = Folder(name: "Yab")
        let papers = Folder(name: "Papers"), ml = Folder(name: "ML")
        let wallets = Folder(name: "Wallets")
        let work = [Self.kept("w1", in: reading), Self.kept("w2", in: reading), Self.kept("w3", in: docs), Self.kept("w4")]
        let home = [Self.kept("h1", in: yab, path: [projects]), Self.kept("h2", in: yab, path: [projects])]
        let research = [Self.kept("r1", in: papers), Self.kept("r2", in: ml, path: [papers])]
        let crypto = [Self.kept("c1", in: wallets), Self.kept("c2", in: wallets), Self.kept("c3", in: wallets)]
        let rowsA: [UUID: Session.Shape] = [
            // w1 and w4 side by side.
            spaces[0].id: Session.Shape(tabs: work, active: 0, pairs: [.init(first: 0, second: 3, share: 0.4)]),
            spaces[1].id: Session.Shape(tabs: home, active: 0),
            spaces[2].id: Session.Shape(tabs: research, active: 0),
            spaces[3].id: Session.Shape(tabs: crypto, active: 0),
        ]
        let a = try Journal(path: nil, device: "mac-a")
        try a.reconcile(SyncShapes.space, SyncShapes.spaces(original + spaces, orders: [:]))
        let out = SyncShapes.rows(rowsA, orders: [:], device: "mac-a")
        try a.reconcile(SyncShapes.tab, out.tabs)
        try a.reconcile(SyncShapes.folder, out.folders)
        try a.reconcile(SyncShapes.pair, out.pairs)
        let expected = Self.structure(Array(rowsA.values))
        #expect(a.living(SyncShapes.folder).count == 7)

        // Mac B: a fresh install, an empty journal. The first page has the
        // spaces, the tabs but w4, the pair and the folders written last
        // long ago (Docs, Projects with only a folder in it, ML inside
        // Papers); the next has the folders opened or renamed since and w4.
        let b = try Journal(path: nil, device: "mac-b")
        let center = SyncCenter()
        let early: Set<String> = [docs.id, projects.id, ml.id]
        let late = work[3].id!
        let folders = a.all(SyncShapes.folder)
        let first = a.all(SyncShapes.space) + a.all(SyncShapes.tab).filter { $0.id != late } + a.all(SyncShapes.pair)
            + folders.filter { early.contains($0.id) }
        let second = folders.filter { !early.contains($0.id) } + a.all(SyncShapes.tab).filter { $0.id == late }

        func rowsNow() -> [UUID: Session.Shape] {
            Dictionary(Spaces.read().map { ($0.id, Session.read(space: $0.id)) }, uniquingKeysWith: { one, _ in one })
        }
        // A join takes the first page in without local rows.
        center.adopt(try SyncCenter.receive(first.map { ($0, 1) }, into: b, localRows: nil, device: "mac-b"), from: b)
        // Its rows written, Session.written asks for a save: the rows go to
        // the journal before the next page.
        _ = try SyncCenter.receive([], into: b, localRows: rowsNow(), device: "mac-b")
        // The next page; a Mac already in the account (its key in the
        // keychain) reconciles its rows first on every delivery.
        center.adopt(try SyncCenter.receive(second.map { ($0, 2) }, into: b, localRows: rowsNow(), device: "mac-b"), from: b)
        // And saves again.
        _ = try SyncCenter.receive([], into: b, localRows: rowsNow(), device: "mac-b")

        let shown = spaces.map { Session.read(space: $0.id) }
        #expect(Self.structure(shown) == expected)
        #expect(shown[0].pairs?.count == 1)
        #expect(b.living(SyncShapes.folder).count == 7)
        // What B sends doesn't empty a folder on A either.
        _ = try a.receive(b.pending().map { ($0.record, 3) })
        let back = spaces.map {
            SyncShapes.row($0.id, tabs: a.all(SyncShapes.tab), folders: a.all(SyncShapes.folder), pairs: a.all(SyncShapes.pair),
                           here: Session.Shape(tabs: [], active: 0), device: "mac-a")
        }
        #expect(Self.structure(back) == expected)
        #expect(a.living(SyncShapes.folder).count == 7)
        #expect(a.living(SyncShapes.pair).count == 1)
    }

    /// The guard is only for folders not come yet: taking a tab out of a
    /// folder, or deleting a folder, still goes everywhere.
    @Test func aFolderEmptiedHereStillGoes() throws {
        let space = UUID()
        let b = try Journal(path: nil, device: "mac-b")
        try b.reconcile(SyncShapes.space, SyncShapes.spaces([Space(id: space, name: "Work", icon: "W", ownSignIns: false)], orders: [:]))
        let outer = Folder(name: "Outer"), inner = Folder(name: "Inner"), plain = Folder(name: "Plain")
        let one = Self.kept("one", in: inner, path: [outer]), two = Self.kept("two", in: plain)
        _ = try SyncCenter.receive([], into: b, localRows: [space: Session.Shape(tabs: [one, two], active: 0)], device: "mac-b")
        #expect(b.living(SyncShapes.folder).count == 3)
        // Both tabs taken out: their folders, and the one those were in, go.
        var loose = [one, two]
        for index in loose.indices {
            loose[index].folder = nil; loose[index].folderName = nil; loose[index].folderOpen = nil; loose[index].folderPath = nil
        }
        _ = try SyncCenter.receive([], into: b, localRows: [space: Session.Shape(tabs: loose, active: 0)], device: "mac-b")
        #expect(b.living(SyncShapes.tab).allSatisfy { $0["folder"]?.string == nil })
        #expect(b.living(SyncShapes.folder).isEmpty)
    }
}
