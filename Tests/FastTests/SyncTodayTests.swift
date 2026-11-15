import Foundation
import Testing
import SyncKit
@testable import Fast

/// Today is each device's own (docs/sync.md, "Today is each device's
/// own"): a tab of today's carries the device it is open on, a Mac shows
/// its own and those from before, never another device's, and never
/// removes another device's for missing from its rows.
struct SyncTodayTests {
    init() { SyncShapes.register() }

    private let space = UUID()

    /// A tab's record as the device it is open on wrote it.
    private func record(_ id: String, kept: Bool = false, pin: String? = nil, device: String?) -> SyncKit.Record {
        let tab = SyncTab(id: id, space: space.uuidString, order: id, url: "https://today.test/\(id)", title: id, pin: pin, kept: kept, device: device)
        let other = try! Journal(path: nil, device: device ?? "old")
        return try! other.change(.init(collection: SyncShapes.tab, id: id), tab.fields)
    }

    @Test func whoShowsWhat() {
        let pin = SyncTab(space: "s", url: "https://p.test", title: "", pin: "a")
        let kept = SyncTab(space: "s", url: "https://k.test", title: "", kept: true)
        let old = SyncTab(space: "s", url: "https://o.test", title: "")
        let phone = SyncTab(space: "s", url: "https://i.test", title: "", device: "iphone")
        let mac = SyncTab(space: "s", url: "https://m.test", title: "", device: "mac")
        // Pins and the kept: every device.
        #expect(pin.shown(to: "iphone", mac: false) && kept.shown(to: "iphone", mac: false))
        #expect(pin.shown(to: "mac", mac: true) && kept.shown(to: "mac", mac: true))
        // A tab of today's from before is a Mac's.
        #expect(old.shown(to: "mac", mac: true) && !old.shown(to: "iphone", mac: false))
        #expect(phone.shown(to: "iphone", mac: false) && !phone.shown(to: "mac", mac: true))
        #expect(mac.shown(to: "mac", mac: true) && !mac.shown(to: "other-mac", mac: true) && !mac.shown(to: "iphone", mac: false))
        // No device asking: everything, as before.
        #expect(phone.shown(to: nil, mac: true) && mac.shown(to: nil, mac: false))
    }

    @Test func aKeptTabCarriesNoDevice() {
        #expect(SyncTab(space: "s", url: "https://k.test", title: "", kept: true, device: "iphone").fields["device"] == nil)
        #expect(SyncTab(space: "s", url: "https://t.test", title: "", device: "iphone").fields["device"] == .string("iphone"))
    }

    @Test func aRowPutsOtherDevicesTodayElsewhere() {
        let tabs = [record("a", device: nil), record("b", device: "iphone"), record("c", device: "mac"), record("d", kept: true, device: nil)]
        let phone = SyncRow(space: space.uuidString, tabs: tabs, folders: [], pairs: [], device: "iphone", mac: false)
        #expect(phone.today.map(\.id) == ["b"])
        #expect(phone.kept.map(\.id) == ["d"])
        #expect(phone.elsewhere.map(\.id) == ["a", "c"])
        let mac = SyncRow(space: space.uuidString, tabs: tabs, folders: [], pairs: [], device: "mac", mac: true)
        #expect(mac.today.map(\.id) == ["a", "c"])
        #expect(mac.elsewhere.map(\.id) == ["b"])
    }

    @Test func theMacsRowLeavesThePhonesTabsOut() {
        let tabs = [record("A", device: nil), record("B", device: "iphone"), record("C", device: SyncCenter.deviceID)]
        let shape = SyncShapes.row(space, tabs: tabs, folders: [], pairs: [], here: .init(tabs: [], active: 0), device: SyncCenter.deviceID)
        #expect(shape.tabs.compactMap(\.id) == ["A", "C"])
    }

    @Test func theMacNeverClosesThePhonesTabsAndMarksItsOwn() throws {
        let journal = try Journal(path: nil, device: SyncCenter.deviceID)
        // The iPhone's tab of today and one from before Today was each device's.
        let phone = record("B0000000-0000-0000-0000-00000000000B", device: "iphone")
        let old = record("A0000000-0000-0000-0000-00000000000A", device: nil)
        _ = try journal.receive([(phone, 1), (old, 2)])
        // The Mac's row: the old tab, and a tab it just opened. Not the iPhone's.
        let fresh = "C0000000-0000-0000-0000-00000000000C"
        let row = Session.Shape(tabs: [
            Session.Entry(url: "https://today.test/old", title: "old", id: old.id),
            Session.Entry(url: "https://today.test/new", title: "new", id: fresh),
        ], active: 1)
        _ = try SyncCenter.receive([], into: journal, localRows: [space: row])
        let byID = Dictionary(uniqueKeysWithValues: journal.all(SyncShapes.tab).map { ($0.id, $0) })
        #expect(byID[phone.id]?.alive() == true)
        #expect(byID[old.id]?["device"] == nil || byID[old.id]?["device"] == .null)
        #expect(byID[fresh]?["device"]?.string == SyncCenter.deviceID)
        // Cleared on the Mac: its tabs go, the iPhone's stays.
        _ = try SyncCenter.receive([], into: journal, localRows: [space: Session.Shape(tabs: [], active: 0)])
        let after = Dictionary(uniqueKeysWithValues: journal.all(SyncShapes.tab).map { ($0.id, $0) })
        #expect(after[phone.id]?.alive() == true)
        #expect(after[old.id]?.alive() == false)
        #expect(after[fresh]?.alive() == false)
    }

    /// An iPhone from before `device` opens tabs without saying whose: the
    /// Mac takes a new one as that iPhone's and leaves it out; a tab it
    /// already held stays its own to show; kept there, it is everyone's.
    @Test func aNewTabFromAnOlderIPhoneIsTheIPhones() throws {
        let journal = try Journal(path: nil, device: SyncCenter.deviceID)
        let had = record("E0000000-0000-0000-0000-00000000000E", device: nil)
        _ = try journal.receive([(had, 1)])
        let fresh = record("F0000000-0000-0000-0000-00000000000F", device: nil)
        var marked = SyncShapes.mark([had, fresh], in: journal, device: SyncCenter.deviceID, marked: [:])
        #expect(marked == [fresh.id: "old"])
        _ = try journal.receive([(fresh, 2)])
        let shape = SyncShapes.row(space, tabs: journal.all(SyncShapes.tab), folders: [], pairs: [], here: .init(tabs: [], active: 0),
                                   device: SyncCenter.deviceID, marked: marked)
        #expect(shape.tabs.compactMap(\.id) == [had.id])
        #expect(SyncShapes.elsewhere(fresh, device: SyncCenter.deviceID, marked: marked))
        // The Mac's own tabs this Mac opened are never marked.
        let mine = try Journal(path: nil, device: SyncCenter.deviceID)
            .change(.init(collection: SyncShapes.tab, id: "G0000000-0000-0000-0000-00000000000G"),
                    SyncTab(space: space.uuidString, url: "https://today.test/g", title: "g").fields)
        #expect(SyncShapes.mark([mine], in: journal, device: SyncCenter.deviceID, marked: marked)[mine.id] == nil)
        // Kept on the iPhone, it is everyone's.
        let kept = record(fresh.id, kept: true, device: nil)
        marked = SyncShapes.mark([kept], in: journal, device: SyncCenter.deviceID, marked: marked)
        #expect(marked.isEmpty)
    }

    @Test func aTabKeptOnTheMacBecomesEveryones() throws {
        let journal = try Journal(path: nil, device: SyncCenter.deviceID)
        let id = "D0000000-0000-0000-0000-00000000000D"
        let open = Session.Shape(tabs: [Session.Entry(url: "https://today.test/d", title: "d", id: id)], active: 0)
        _ = try SyncCenter.receive([], into: journal, localRows: [space: open])
        #expect(journal.all(SyncShapes.tab).first?["device"]?.string == SyncCenter.deviceID)
        let kept = Session.Shape(tabs: [Session.Entry(url: "https://today.test/d", title: "d", kept: true, id: id)], active: 0)
        _ = try SyncCenter.receive([], into: journal, localRows: [space: kept])
        let tab = journal.all(SyncShapes.tab).first.flatMap(SyncTab.init)
        #expect(tab?.kept == true && tab?.device == nil)
        #expect(tab?.shown(to: "iphone", mac: false) == true)
    }
    /// Row 965: two Macs. Mac B's today tabs in a folder of their own, side
    /// by side. Mac A never writes them (they are B's), and reconciling its
    /// own row must not remove B's folder or pair for missing from it.
    @Test func aMacNeverRemovesAnotherMacsTodayFolderOrPair() throws {
        let a = try Journal(path: nil, device: "mac-a"), b = try Journal(path: nil, device: "mac-b")
        let t1 = "11111111-0000-0000-0000-000000000001", t2 = "11111111-0000-0000-0000-000000000002"
        let folder = "22222222-0000-0000-0000-000000000002"
        let rowB = Session.Shape(tabs: [
            Session.Entry(url: "https://b.test/1", title: "1", folder: folder, folderName: "Work", folderToday: true, id: t1),
            Session.Entry(url: "https://b.test/2", title: "2", folder: folder, folderName: "Work", folderToday: true, id: t2),
        ], active: 0, pairs: [Session.Pair(first: 0, second: 1, share: 0.5)])
        _ = try SyncCenter.receive([], into: b, localRows: [space: rowB], device: "mac-b")
        let fromB = [SyncShapes.tab, SyncShapes.folder, SyncShapes.pair].flatMap { b.all($0) }
        #expect(fromB.count == 4)
        // Mac A has a tab of its own; B's arrive while it writes its row.
        let rowA = Session.Shape(tabs: [Session.Entry(url: "https://a.test", title: "a", id: "33333333-0000-0000-0000-000000000003")], active: 0)
        _ = try SyncCenter.receive(fromB.enumerated().map { ($1, Int64($0 + 1)) }, into: a, localRows: [space: rowA], device: "mac-a")
        _ = try SyncCenter.receive([], into: a, localRows: [space: rowA], device: "mac-a")
        #expect(a.record(.init(collection: SyncShapes.tab, id: t1))?.alive() == true)
        #expect(a.record(.init(collection: SyncShapes.folder, id: folder))?.alive() == true)
        #expect(a.record(.init(collection: SyncShapes.pair, id: "\(t1)|\(t2)"))?.alive() == true)
        // B's row read back from A's journal still has its folder and pair.
        let back = SyncShapes.row(space, tabs: a.all(SyncShapes.tab), folders: a.all(SyncShapes.folder), pairs: a.all(SyncShapes.pair),
                                  here: rowB, device: "mac-b")
        #expect(back.tabs.compactMap(\.folder) == [folder, folder])
        #expect(back.pairs?.count == 1)
        // Mac A's own folder still goes when A takes its tab out of it.
        let own = "44444444-0000-0000-0000-000000000004"
        let inFolder = Session.Shape(tabs: [Session.Entry(url: "https://a.test", title: "a", folder: own, folderName: "Mine", folderToday: true,
                                                          id: "33333333-0000-0000-0000-000000000003")], active: 0)
        _ = try SyncCenter.receive([], into: a, localRows: [space: inFolder], device: "mac-a")
        #expect(a.record(.init(collection: SyncShapes.folder, id: own))?.alive() == true)
        _ = try SyncCenter.receive([], into: a, localRows: [space: rowA], device: "mac-a")
        #expect(a.record(.init(collection: SyncShapes.folder, id: own))?.alive() == false)
    }
}
