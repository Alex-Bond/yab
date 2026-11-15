import SwiftUI
import SyncKit
import UIKit
import XCTest
@testable import YabPhone

private enum NestedFolderFixture {
    static func tab(_ id: String) -> YabPhone.Tab {
        YabPhone.Tab(id: id, title: "Page " + id, site: "Owned", icon: "globe", url: "https://nested.example/" + id)
    }
    static func space() -> Space {
        let leaf = Folder(id: "f5", name: "Fifth level with a deliberately long folder name", open: true,
                          items: [.tab(tab("deep")), .tab(tab("sibling"))], customMark: "📊")
        var branch = leaf
        for depth in (1...4).reversed() {
            branch = Folder(id: "f\(depth)", name: "Level \(depth)", open: true,
                            items: [.folder(branch)], customMark: depth == 3 ? "icon:code" : nil)
        }
        return Space(id: "owned", name: "Owned", emoji: "", tint: RGB(238, 233, 226),
                     kept: [.tab(tab("root")), .folder(branch), .folder(Folder(id: "empty", name: "Empty", tabs: []))],
                     today: [tab("today")], current: "deep")
    }
    static func syncRow(_ folders: [SyncFolder], tabs: [SyncTab]) -> SyncRow {
        SyncRow(space: "S", tabs: tabs.map { Record(collection: "tab", id: $0.id, fields: $0.fields) },
                folders: folders.map { Record(collection: "folder", id: $0.id, fields: $0.fields) }, pairs: [])
    }
    static func syncedTab(_ id: String, _ order: String, folder: String? = nil) -> SyncTab {
        SyncTab(id: id, space: "S", order: order, url: "https://nested.example/" + id,
                title: id, kept: true, folder: folder)
    }
}

@MainActor
final class NestedFoldersModelTests: XCTestCase {
    func testProfileRejectsFoldersBeyondTheEditorDepthBeforeDecodingChildren() throws {
        func tree(_ depth: Int) -> KeptItem {
            var item = KeptItem.tab(Tab(id: "leaf", title: "Leaf", site: "Leaf", icon: "globe"))
            for level in 0..<depth { item = .folder(Folder(id: "folder-\(level)", name: "Folder", open: true, items: [item])) }
            return item
        }
        let supported = try JSONEncoder().encode(tree(KeptTree.deepest))
        XCTAssertNoThrow(try JSONDecoder().decode(KeptItem.self, from: supported))
        let corrupt = try JSONEncoder().encode(tree(KeptTree.deepest + 1))
        XCTAssertThrowsError(try JSONDecoder().decode(KeptItem.self, from: corrupt))
    }

    func testClosedParentsPeekOnlyTheCurrentTabAndRetainIndependentChildFolds() throws {
        var space = NestedFolderFixture.space()
        space.setFolder("f3", open: false)
        space.setFolder("f1", open: false)
        XCTAssertEqual(space.rows.map(\.id), ["root", "deep", "today"])
        space.setFolder("f1", open: true)
        XCTAssertFalse(try XCTUnwrap(space.folders.first { $0.id == "f3" }).open)
        space.reveal("deep")
        XCTAssertTrue(space.folders.filter { $0.id.hasPrefix("f") }.allSatisfy(\.open))
    }

    func testNestedProfileRoundTripKeepsLegacyLeavesAndFiltersPrivateAtEveryDepth() async throws {
        var space = NestedFolderFixture.space()
        var secret = NestedFolderFixture.tab("secret"); secret.isPrivate = true
        KeptTree.editFolder("f5", in: &space.kept) { $0.items.append(.tab(secret)) }
        let old = Data(#"{"id":"old","name":"Legacy","open":false,"tabs":[{"id":"old-tab","title":"Old","site":"Owned","icon":"globe"}]}"#.utf8)
        let legacy = try JSONDecoder().decode(Folder.self, from: old)
        XCTAssertEqual(legacy.tabs.map(\.id), ["old-tab"])
        XCTAssertEqual(try JSONDecoder().decode(Folder.self, from: JSONEncoder().encode(legacy)), legacy)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nested-profile-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        space.setFolder("f1", open: false)
        let browser = BrowserStore(world: World(name: "nested", space: space.id, spaces: [space]))
        XCTAssertFalse(try XCTUnwrap(browser.space.folders.first { $0.id == "f1" }).open)
        let profile = BrowserProfile(folder: directory)
        profile.capture(browser); await profile.flush()
        XCTAssertNil(profile.lastWriteError)
        let restored = BrowserProfile(folder: directory).world.spaces[0]
        XCTAssertEqual(restored.folders.map(\.id), ["f1", "f2", "f3", "f4", "f5", "empty"])
        XCTAssertEqual(restored.folder(holding: "deep")?.id, "f5")
        XCTAssertFalse(try XCTUnwrap(restored.folders.first { $0.id == "f1" }).open)
        let again = BrowserStore(world: World(name: "restored", space: restored.id, spaces: [restored]))
        XCTAssertEqual(again.space.rows.map(\.id), ["root", "deep", "today"])
        XCTAssertEqual(restored.folders.first { $0.id == "f3" }?.customMark, "icon:code")
        XCTAssertNil(restored.tab("secret"))
        XCTAssertFalse(try String(contentsOf: directory.appendingPathComponent("profile.json"), encoding: .utf8).contains("secret"))
    }

    func testDeepMutationsSearchAndStaleMenuOwnershipUseTheActualTree() throws {
        let space = NestedFolderFixture.space()
        let app = AppModel(world: World(name: "nested", space: space.id, spaces: [space]))
        // Match the actual launch attachment without keys, a line or disk.
        app.sync.attach(app, setup: nil)
        XCTAssertEqual(app.tabCandidates.first { $0.id == "deep" }?.folder, "Fifth level with a deliberately long folder name")
        var changed = try XCTUnwrap(app.browser.tab("deep")); changed.title = "Changed deep page"
        app.browser.replace("deep", with: changed)
        app.browser.setOnMac("deep")
        XCTAssertEqual(app.browser.tab("deep")?.title, changed.title)
        XCTAssertTrue(app.browser.tab("deep")?.onMac == true)
        app.browser.move("sibling", before: "deep")
        XCTAssertEqual(app.browser.space.folder(holding: "deep")?.tabs.map(\.id), ["sibling", "deep"])
        let target = try XCTUnwrap(app.browser.space.folders.first { $0.id == "empty" })
        let source = try XCTUnwrap(app.browser.tab("deep"))
        // Adopt an actual incoming owner snapshot through the public API.
        var incoming = app.browser.spaces
        let ownerIndex = try XCTUnwrap(incoming.firstIndex { $0.id == space.id })
        KeptTree.editFolder("empty", in: &incoming[ownerIndex].kept) { $0.name = "Renamed target" }
        app.browser.adopt(incoming)
        XCTAssertFalse(app.sync.moveToFolder(source, in: space.id, to: target.id, expectedFolder: target))
        let fresh = try XCTUnwrap(app.browser.space.folders.first { $0.id == "empty" })
        XCTAssertTrue(app.sync.moveToFolder(source, in: space.id, to: fresh.id, expectedFolder: fresh))
        XCTAssertEqual(app.browser.space.current, "deep")
        XCTAssertEqual(app.browser.space.folder(holding: "deep")?.id, "empty")
        let moved = try XCTUnwrap(app.browser.tab("deep"))
        XCTAssertTrue(app.sync.moveToFolder(moved, in: space.id, to: nil, expectedFolder: nil))
        XCTAssertNil(app.browser.space.folder(holding: "deep"))
        XCTAssertEqual(app.browser.space.folders.count, 6, "moving the last child never deletes any Mac folder")
    }

    func testMacOrderEmptyAncestorsAndLegacyFlatteningRetainEveryTab() throws {
        let folders = [SyncFolder(id: "parent", space: "S", order: "B", name: "Parent", open: true),
                       SyncFolder(id: "child", space: "S", order: "B", name: "Child", open: false, customMark: "📊", folder: "parent"),
                       SyncFolder(id: "empty", space: "S", order: "D", name: "Empty", folder: "parent")]
        let tabs = [NestedFolderFixture.syncedTab("root", "A"), NestedFolderFixture.syncedTab("nested", "B", folder: "child"),
                    NestedFolderFixture.syncedTab("direct", "C", folder: "parent")]
        let synced = SyncSpace(id: "S", name: "Nested", icon: "")
        let nested = SyncMapping.space(synced, row: NestedFolderFixture.syncRow(folders, tabs: tabs), old: nil, fixturesEnabled: false)
        XCTAssertEqual(nested.kept.map(\.id), ["tab:root", "folder:parent"])
        XCTAssertEqual(nested.folders.map(\.id), ["parent", "child", "empty"])
        XCTAssertEqual(nested.folders.first?.items.map(\.id), ["folder:child", "tab:direct", "folder:empty"])
        XCTAssertEqual(nested.keptTabs.map(\.id), ["root", "nested", "direct"])
        XCTAssertEqual(nested.folder(holding: "nested")?.customMark, "📊")
        // An older Mac clears folder.folder and drops the now-empty parent.
        var flatChild = folders[1]; flatChild.folder = nil
        var flatDirect = tabs[2]; flatDirect.folder = nil
        let flat = SyncMapping.space(synced, row: NestedFolderFixture.syncRow([flatChild], tabs: [tabs[0], tabs[1], flatDirect]), old: nested, fixturesEnabled: false)
        XCTAssertEqual(flat.folders.map(\.id), ["child"])
        XCTAssertEqual(flat.keptTabs.map(\.id), nested.keptTabs.map(\.id))
        XCTAssertEqual(flat.folder(holding: "nested")?.id, "child")
        XCTAssertNil(flat.folder(holding: "direct"))
    }

    func testBrokenCyclesMissingParentsAndOverdeepPathsFlattenWithoutLoss() {
        var folders: [SyncFolder] = []
        for i in 1...7 { folders.append(SyncFolder(id: "f\(i)", space: "S", order: "B", folder: i == 1 ? nil : "f\(i - 1)")) }
        folders += [SyncFolder(id: "cycle-a", space: "S", order: "C", folder: "cycle-b"),
                    SyncFolder(id: "cycle-b", space: "S", order: "C", folder: "cycle-a"),
                    SyncFolder(id: "orphan", space: "S", order: "D", folder: "missing"),
                    SyncFolder(id: "search", space: "S", order: "E", search: "query", folder: "f1")]
        let ids = folders.map(\.id)
        let tabs = ids.enumerated().map { NestedFolderFixture.syncedTab("t\($0.offset)", "V\($0.offset)", folder: $0.element) }
        let row = NestedFolderFixture.syncRow(folders, tabs: tabs)
        let mapped = SyncMapping.space(SyncSpace(id: "S", name: "Broken", icon: ""), row: row, old: nil, fixturesEnabled: false)
        XCTAssertEqual(Set(mapped.keptTabs.map(\.id)), Set(tabs.map(\.id)))
        XCTAssertEqual(mapped.keptTabs.count, tabs.count)
        XCTAssertEqual(Set(mapped.folders.map(\.id)), Set(ids))
        XCTAssertTrue(mapped.keptTabs.allSatisfy { KeptTree.path(to: $0.id, in: mapped.kept).count <= 5 })
        XCTAssertEqual(KeptTree.path(to: "t\(ids.firstIndex(of: "search")!)", in: mapped.kept).count, 1,
                       "search folders cannot become a child")
        let reversed = NestedFolderFixture.syncRow(Array(folders.reversed()), tabs: Array(tabs.reversed()))
        XCTAssertEqual(SyncKeptTree.make(row).flatMap(\.tabs), SyncKeptTree.make(reversed).flatMap(\.tabs))
    }
}

@MainActor
final class NestedFoldersSyncTests: XCTestCase {
    private var directory: URL!
    private var phone: PhoneSync?
    private var leases: [OwnedLease] = []
    private final class OwnedLease {
        weak var engine: PhoneSync?
        weak var client: SyncClient?
        weak var journal: Journal?
        init(_ engine: PhoneSync) { self.engine = engine; client = engine.client; journal = engine.journal }
        init(_ client: SyncClient) { self.client = client; journal = client.journal }
        func stop() { if let engine { engine.stop() } else { client?.stop() } }
        var released: Bool { engine == nil && client == nil && journal == nil }
    }
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("nested-sqlite-\(UUID())")
    }
    override func tearDown() async throws {
        phone?.stop(); phone = nil; leases.forEach { $0.stop() }
        let end = Date().addingTimeInterval(4)
        while Date() < end, !leases.allSatisfy(\.released) { try? await Task.sleep(for: .milliseconds(10)) }
        guard leases.allSatisfy(\.released) else {
            return XCTFail("Owned sync journals remain open; preserving SQLite files until their actual owners release")
        }
        leases = []; try FileManager.default.removeItem(at: directory)
    }
    private func makePhone() throws -> PhoneSync {
        let made = try PhoneSync(seal: Seal.make(), options: .init(folder: directory,
            device: .init(id: "owned-phone", name: "Owned phone", model: "iPhone"), transport: SyncMemoryServer()))
        phone = made; leases.append(OwnedLease(made))
        for folder in [SyncFolder(id: "parent", space: "S", order: "A", name: "Parent", open: true),
                       SyncFolder(id: "child", space: "S", order: "A", name: "Child", folder: "parent"),
                       SyncFolder(id: "deep", space: "S", order: "A", name: "Deep", customMark: "icon:code", folder: "child"),
                       SyncFolder(id: "foreign", space: "other", name: "Foreign"),
                       SyncFolder(id: "query", space: "S", search: "query")] {
            try made.journal.change(.init(collection: "folder", id: folder.id), folder.fields)
        }
        var fields = NestedFolderFixture.syncedTab("page", "A", folder: "parent").fields
        fields["future"] = .object(["retained": true])
        try made.journal.change(.init(collection: "tab", id: "page"), fields)
        return made
    }
    func testMovingIntoDeepFolderWritesOnlyTheImmediateTabFolderInRealSQLite() throws {
        let phone = try makePhone()
        let key = Record.Key(collection: "tab", id: "page")
        let before = try XCTUnwrap(phone.journal.record(key)), folders = phone.journal.all("folder")
        XCTAssertEqual(try phone.putInFolder("page", folder: "deep").folder, "deep")
        let after = try XCTUnwrap(phone.journal.record(key))
        XCTAssertEqual(after.fields.filter { $0.key != "folder" }, before.fields.filter { $0.key != "folder" })
        XCTAssertEqual(after.stamps.filter { $0.key != "folder" }, before.stamps.filter { $0.key != "folder" })
        XCTAssertNotEqual(after.stamps["folder"], before.stamps["folder"])
        XCTAssertEqual(phone.journal.all("folder"), folders, "no ancestor or empty-folder record is written")
        let disk = try Journal(path: directory.appendingPathComponent("sync.sqlite").path, device: "read-check")
        XCTAssertEqual(disk.record(key), after)
        let mapped = SyncMapping.space(SyncSpace(id: "S", name: "Owned", icon: ""), row: phone.row("S"), old: nil, fixturesEnabled: false)
        XCTAssertEqual(KeptTree.path(to: "page", in: mapped.kept).map(\.id), ["parent", "child", "deep"])
        XCTAssertEqual(try phone.putInFolder("page", folder: nil).folder, nil)
        XCTAssertEqual(phone.journal.all("folder"), folders)
    }
    func testEncryptedSyncDeliversTheDeepAssignmentToTheMacWithoutFolderWrites() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try TestMac(server: server, seal: seal)
        leases.append(OwnedLease(mac.client))
        defer { mac.client.stop() }
        for folder in [SyncFolder(id: "parent", space: "S", order: "A", name: "Parent", open: true),
                       SyncFolder(id: "child", space: "S", order: "A", name: "Child", folder: "parent"),
                       SyncFolder(id: "deep", space: "S", order: "A", name: "Deep", folder: "child")] {
            try mac.write("folder", folder.id, folder.fields)
        }
        try mac.write("tab", "page", NestedFolderFixture.syncedTab("page", "A", folder: "parent").fields)
        mac.client.start()
        func until(_ done: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(5)
            while Date() < end { if done() { return true }; try? await Task.sleep(for: .milliseconds(10)) }
            return done()
        }
        let up = await until { mac.client.state == .live && mac.pending == 0 }; XCTAssertTrue(up)
        let made = try PhoneSync(seal: seal, options: .init(folder: directory,
            device: .init(id: "owned-phone", name: "Owned phone", model: "iPhone"), transport: server))
        phone = made; leases.append(OwnedLease(made)); made.start()
        let heard = await until { made.tab("page") != nil && made.row("S").folders.count == 3 }; XCTAssertTrue(heard)
        let originals = mac.journal.all("folder")
        _ = try made.putInFolder("page", folder: "deep")
        let arrived = await until { mac.row("S").kept.first?.folder == "deep" }; XCTAssertTrue(arrived)
        XCTAssertEqual(mac.journal.all("folder"), originals)
        XCTAssertEqual(mac.row("S").kept.first?.url, "https://nested.example/page")
        XCTAssertEqual(mac.row("S").kept.first?.order, "A")
        _ = try made.putInFolder("page", folder: nil)
        let outside = await until { mac.row("S").kept.first?.folder == nil }; XCTAssertTrue(outside)
        XCTAssertEqual(mac.journal.all("folder"), originals)
    }

    func testFolderWritesPreserveUnknownFieldsAndDeleteOnlyTheContainer() throws {
        let phone = try makePhone()
        try phone.journal.change(.init(collection: "space", id: "S"), SyncSpace(id: "S", name: "Work", icon: "").fields)
        try phone.journal.change(.init(collection: "folder", id: "child"), ["future": .object(["keep": true]), "color": "#123456"])
        let before = try XCTUnwrap(phone.journal.record(.init(collection: "folder", id: "child")))
        _ = try phone.renameFolder("child", in: "S", to: "References")
        let after = try XCTUnwrap(phone.journal.record(.init(collection: "folder", id: "child")))
        XCTAssertEqual(after.fields.filter { $0.key != "name" }, before.fields.filter { $0.key != "name" })
        XCTAssertEqual(after.stamps.filter { $0.key != "name" }, before.stamps.filter { $0.key != "name" })
        let made = try phone.makeFolder(id: "new-empty", name: "New empty", in: "S", parent: "child")
        XCTAssertEqual(made.folder, "child")
        _ = try phone.deleteFolder("child", in: "S")
        XCTAssertNil(phone.row("S").folders["child"])
        XCTAssertEqual(phone.row("S").folders["deep"]?.folder, "parent")
        XCTAssertEqual(phone.row("S").folders["new-empty"]?.folder, "parent")
        XCTAssertEqual(phone.row("S").kept.map(\.id), ["page"])
        XCTAssertEqual(phone.tab("page")?.folder, "parent")
        XCTAssertThrowsError(try phone.makeFolder(id: "invalid", name: "No", in: "S", parent: "foreign"))
        XCTAssertThrowsError(try phone.makeFolder(id: "invalid", name: "No", in: "S", parent: "query"))
    }

    func testUnknownCrossSpaceSearchAndTodayMovesCannotChangeTheJournal() throws {
        let phone = try makePhone()
        let original = phone.journal.all("tab"), folders = phone.journal.all("folder")
        for invalid in ["missing", "foreign", "query"] { XCTAssertThrowsError(try phone.putInFolder("page", folder: invalid)) }
        XCTAssertEqual(phone.journal.all("tab"), original); XCTAssertEqual(phone.journal.all("folder"), folders)
        XCTAssertEqual(try phone.putInFolder("page", folder: "parent").folder, "parent")
        XCTAssertEqual(phone.journal.all("tab"), original, "a current-folder no-op does not restamp the tab")
        try phone.journal.change(.init(collection: "tab", id: "today"),
            SyncTab(id: "today", space: "S", url: "https://nested.example/today", title: "Today").fields)
        let today = phone.journal.all("tab")
        XCTAssertThrowsError(try phone.putInFolder("today", folder: "deep"))
        XCTAssertEqual(phone.journal.all("tab"), today)
    }
}

@MainActor
final class NestedFoldersNativeTests: XCTestCase {
    private var window: UIWindow?
    private weak var previous: UIWindow?
    override func tearDown() { window?.isHidden = true; window?.rootViewController = nil; window = nil; previous?.makeKey(); previous = nil }
    private func check(dark: Bool) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        previous = scene.windows.first(where: \.isKeyWindow)
        let owned = UIWindow(windowScene: scene); owned.frame = CGRect(x: 0, y: 0, width: 320, height: 740); window = owned
        let space = NestedFolderFixture.space()
        let host = UIHostingController(rootView: VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(space.folders.prefix(5).enumerated()), id: \.element.id) { depth, folder in
                HStack(spacing: Metrics.Column.rowGap + Metrics.Column.rowIcon - Metrics.Column.folderIcon) {
                    FolderMark(mark: folder.customMark, open: folder.open, tint: space.tint, dark: dark)
                    Text(folder.name).lineLimit(1)
                }
                .padding(.leading, Metrics.Column.rowPadding + CGFloat(depth) * Metrics.Column.folderIcon)
                .padding(.trailing, Metrics.Column.rowPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .frame(width: 296, height: 44)
                    .accessibilityIdentifier("owned.folder." + folder.id)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12).background(dark ? Color.black : Color.white)
            .environment(\.colorScheme, dark ? .dark : .light).dynamicTypeSize(.accessibility5))
        host.safeAreaRegions = []; owned.rootViewController = host; owned.overrideUserInterfaceStyle = dark ? .dark : .light; owned.makeKeyAndVisible()
        let end = Date().addingTimeInterval(5)
        while Date() < end, host.view.bounds.width == 0 { await Task.yield(); try? await Task.sleep(for: .milliseconds(20)) }
        owned.layoutIfNeeded(); host.view.layoutIfNeeded()
        XCTAssertEqual(host.view.bounds.width, 320)
        XCTAssertEqual(space.folders.prefix(5).count, 5)
        let actual = UIGraphicsImageRenderer(bounds: owned.bounds).image { _ in
            XCTAssertTrue(owned.drawHierarchy(in: owned.bounds, afterScreenUpdates: true))
        }
        let image = XCTAttachment(image: actual); image.name = "Actual five-level FolderGrid, long-name fade, XXXL, \(dark ? "dark" : "light"), 320 pt"; image.lifetime = .keepAlways; add(image)
        let data = try XCTUnwrap(actual.pngData()); XCTAssertGreaterThan(data.count, 1_000)
    }
    func testFiveLevelsUseTheActualMacGridAndLongNameFadeOnANarrowLightHost() async throws { try await check(dark: false) }
    func testFiveLevelsKeepTheirActualGridAndEmojiInDarkAtLargestText() async throws { try await check(dark: true) }
}
