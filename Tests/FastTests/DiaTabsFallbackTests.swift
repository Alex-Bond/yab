import Foundation
import Testing
@testable import Fast

struct DiaTabsFallbackTests {
    private func fixture() throws -> (ImportFixture, Chromium.Source) {
        let fixture = ImportFixture()
        let root = fixture.root.appendingPathComponent("User Data")
        var source = Chromium.known[0]
        source.dataRoot = root
        for profile in ["Default", "Profile 1"] {
            try fixture.write("User Data/\(profile)/Sessions/Session_1", ChromiumSessionTests.session)
        }
        try fixture.json("User Data/Local State", ["profile": ["info_cache": ["Default": ["name": "Personal"], "Profile 1": ["name": "Work"]]]])
        return (fixture, source)
    }

    @Test func missingContainersUsesChromiumSessionsAndKeepsProfilesApart() throws {
        let (fixture, source) = try fixture()
        defer { fixture.remove() }
        let places = try TabImport.places(in: source)
        #expect(places.map(\.profile) == ["Default", "Profile 1"])
        #expect(places.map(\.shared) == [true, false])
        #expect(places.map(\.name) == ["Personal", "Work"])
        #expect(places.allSatisfy { $0.pinned.count == 1 && $0.open.count == 1 })
    }

    @Test(arguments: [Data("{".utf8), Data("{\"version\":2}".utf8)])
    func unreadableContainersFallsBackWithoutWritingSource(_ data: Data) throws {
        let (fixture, source) = try fixture()
        defer { fixture.remove() }
        try fixture.write("StorableProfileContainers.json", data)
        #expect(try TabImport.places(in: source).count == 2)
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent("StorableProfileContainers.json")) == data)
    }

    @Test func validEmptyContainersDoesNotBringAnOlderSessionBack() throws {
        let (fixture, source) = try fixture()
        defer { fixture.remove() }
        try fixture.json("StorableProfileContainers.json", ["version": 1, "containers": []])
        // Work is still offered, as a profile of its own, with no tabs.
        let places = try TabImport.places(in: source)
        #expect(places.map(\.profile) == ["Profile 1"])
        #expect(places.allSatisfy { $0.isEmpty && $0.apart })
    }

    @Test func neitherFormatReadableIsStillAnError() throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        var source = Chromium.known[0]
        source.dataRoot = fixture.root.appendingPathComponent("User Data")
        #expect(throws: TabImport.Trouble.missing) { try TabImport.places(in: source) }
        #expect(TabImport.explain(TabImport.Trouble.missing, from: source) == "Couldn't read Dia's tabs: there is no tab file or session to read")
    }

    /// No sessions to fall back on: the error says what is wrong with the
    /// tab file.
    @Test(arguments: [
        (Data("{\"version\":4,\"spaces\":[]}".utf8), TabImport.Trouble.newer(version: 4)),
        (Data("[1, 2]".utf8), TabImport.Trouble.newer(version: nil)),
        (Data("{\"containers\": [".utf8), TabImport.Trouble.damaged),
    ])
    func anUnreadableTabFileSaysWhy(_ data: Data, _ trouble: TabImport.Trouble) throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        var source = Chromium.known[0]
        source.dataRoot = fixture.root.appendingPathComponent("User Data")
        try fixture.write("StorableProfileContainers.json", data)
        #expect(throws: trouble) { try TabImport.places(in: source) }
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent("StorableProfileContainers.json")) == data)
    }

    /// A tab file that is there but can't be opened says so, not that
    /// there is none; with sessions beside it they are read instead.
    @Test func aTabFileThatCantBeOpenedIsntCalledMissing() throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        var source = Chromium.known[0]
        source.dataRoot = fixture.root.appendingPathComponent("User Data")
        // A folder where the file should be: reading it fails.
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("StorableProfileContainers.json"),
                                                withIntermediateDirectories: true)
        #expect(throws: TabImport.Trouble.unreadable) { try TabImport.places(in: source) }
        let (sessions, withSessions) = try self.fixture()
        defer { sessions.remove() }
        try FileManager.default.createDirectory(at: sessions.root.appendingPathComponent("StorableProfileContainers.json"),
                                                withIntermediateDirectories: true)
        #expect(try TabImport.places(in: withSessions).count == 2)
    }

    /// The words said, and the code, all feedback's diagnostics carry.
    @MainActor
    @Test func eachTroubleHasItsWordsAndCode() {
        let dia = Chromium.known[0]
        #expect(TabImport.explain(TabImport.Trouble.newer(version: 4), from: dia)
                == "Couldn't read Dia's tabs: its tab file is in a format this Yab doesn't know yet (version 4)")
        #expect(TabImport.explain(TabImport.Trouble.newer(version: nil), from: dia)
                == "Couldn't read Dia's tabs: its tab file is in a format this Yab doesn't know yet")
        #expect(TabImport.explain(TabImport.Trouble.damaged, from: dia) == "Couldn't read Dia's tabs: its tab file is damaged")
        #expect(TabImport.explain(TabImport.Trouble.unreadable, from: dia) == "Couldn't read Dia's tabs: its tab file is there but can't be opened")
        #expect(TabImport.explain(CocoaError(.fileReadUnknown), from: dia) == "Couldn't read Dia's tabs")
        let troubles: [TabImport.Trouble] = [.missing, .damaged, .unreadable, .newer(version: 4), .newer(version: nil), .newer(version: 5000)]
        #expect(troubles.map(\.code) == [1, 2, 3, 1004, 1000, 1999])
        // The corner's notice after the welcome: the cause when only the
        // tabs didn't come, short enough for it.
        #expect(Bringing.notice(dia, tabs: .damaged) == "Dia's tab file is damaged")
        #expect(Bringing.notice(dia, tabs: .newer(version: 4)) == "Dia's tab file is in a newer format")
        #expect(Bringing.notice(dia, tabs: .unreadable) == "Dia's tab file can't be opened")
        #expect(Bringing.notice(dia, tabs: .missing) == "Dia has no tab file to read")
        #expect(Bringing.notice(dia, tabs: nil) == "Not all of Dia came over")
        #expect(troubles.allSatisfy { Notice.headWidth($0.briefly(dia.name)) < Notice.longest })
    }

    @Test func aProfileWithNoSessionIsOfferedBesideTheSessions() throws {
        let (fixture, source) = try fixture()
        defer { fixture.remove() }
        try fixture.json("User Data/Local State", ["profile": [
            "info_cache": ["Default": ["name": "Personal"], "Profile 1": ["name": "Work"], "Profile 3": ["name": "Side"]],
            "profiles_order": ["Default", "Profile 3", "Profile 1"],
        ]])
        #expect(TabImport.profileOrder(in: source) == ["Default", "Profile 3", "Profile 1"])
        let places = try TabImport.places(in: source)
        #expect(places.map(\.profile) == ["Default", "Profile 1", "Profile 3"])
        #expect(places.map(\.name) == ["Personal", "Work", "Side"])
        #expect(places.last.map { $0.isEmpty && $0.apart && $0.id == "Dia:Profile 3" } == true)
    }
}
