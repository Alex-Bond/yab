import Foundation
import Testing
@testable import Fast

/// Extensions follow sign-ins (ExtensionSignIns.swift): each space with
/// sign-ins of its own keeps its own list and WebKit storage, the split
/// copies what every space ran before it, and what is keyed by extension
/// for Yab's ports carries the sign-in.
@MainActor
@Suite(.serialized)
struct ExtensionSignInsTests {
    private func item(_ id: String, _ name: String) -> Installed {
        Installed(id: id, name: name, version: "1.0", enabled: true, fromStore: true, permissions: [], pinned: nil)
    }

    private func folder() throws -> URL {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("signins-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        return made
    }

    @Test func splitGivesEachOwnSpaceTheListAndItsStorage() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = FileManager.default
        let lists = root.appendingPathComponent("Sign-Ins")
        let shared = root.appendingPathComponent("WebExtensions/Default")
        // What the shared sign-in's extensions kept: one listed, one long
        // removed, and the mark that stale origins were swept.
        let listed = "aeblfdkhhhdcdjpifhhbdiojplfjncoa", gone = "ddkjiahejlhfcafbddmgiahcphecmpfh"
        for id in [listed, gone] {
            try files.createDirectory(at: shared.appendingPathComponent(id), withIntermediateDirectories: true)
            try Data("local \(id)".utf8).write(to: shared.appendingPathComponent(id).appendingPathComponent("LocalStorage.db"))
        }
        try Data().write(to: shared.appendingPathComponent("StaleExtensionOriginsCleared"))

        let work = UUID(), home = UUID()
        // Home already has a list of its own: the split leaves it.
        try files.createDirectory(at: lists, withIntermediateDirectories: true)
        try JSONEncoder().encode([item("other", "Other")]).write(to: lists.appendingPathComponent(home.uuidString + ".json"))
        let list = [item(listed, "1Password"), item("cjpalhdlnbpafiamejdnhcphjbkeiagm", "uBlock Origin")]
        let storage = { (space: UUID) in root.appendingPathComponent("WebExtensions/" + space.uuidString) }
        Extensions.split(list, into: [work, home], lists: lists, storage: shared, root: storage)

        let read = { (space: UUID) in
            try JSONDecoder().decode([Installed].self, from: Data(contentsOf: lists.appendingPathComponent(space.uuidString + ".json")))
        }
        #expect(try read(work).map(\.id) == list.map(\.id))
        #expect(try read(home).map(\.id) == ["other"])
        // Work's storage: the listed one's, cloned, and the sweep's mark;
        // never one no longer installed.
        let copied = try Data(contentsOf: storage(work).appendingPathComponent(listed).appendingPathComponent("LocalStorage.db"))
        #expect(String(decoding: copied, as: UTF8.self) == "local \(listed)")
        #expect(files.fileExists(atPath: storage(work).appendingPathComponent("StaleExtensionOriginsCleared").path))
        #expect(!files.fileExists(atPath: storage(work).appendingPathComponent(gone).path))
        // Home kept its own: no storage put under it.
        #expect(!files.fileExists(atPath: storage(home).path))

        // Again, as a second launch would: nothing it has is written over.
        try Data("changed in work".utf8).write(to: storage(work).appendingPathComponent(listed).appendingPathComponent("LocalStorage.db"))
        try JSONEncoder().encode([item(listed, "1Password")]).write(to: lists.appendingPathComponent(work.uuidString + ".json"))
        Extensions.split(list, into: [work], lists: lists, storage: shared, root: storage)
        #expect(try read(work).map(\.id) == [listed])
        let kept = try Data(contentsOf: storage(work).appendingPathComponent(listed).appendingPathComponent("LocalStorage.db"))
        #expect(String(decoding: kept, as: UTF8.self) == "changed in work")
    }

    @Test func splitWithNoStorageStillGivesTheList() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let lists = root.appendingPathComponent("Sign-Ins")
        let space = UUID()
        Extensions.split([item("a", "A")], into: [space], lists: lists, storage: nil, root: { _ in nil })
        let read = try JSONDecoder().decode([Installed].self, from: Data(contentsOf: lists.appendingPathComponent(space.uuidString + ".json")))
        #expect(read.map(\.id) == ["a"])
    }

    @Test func spacesSignInWhereTheirStoreIs() {
        let own = UUID(), sharing = UUID()
        let before = Spaces.sharing
        defer { Spaces.sharing = before }
        Spaces.sharing = [sharing]
        #expect(Extensions.signIn(of: Space.firstID) == nil)
        #expect(Extensions.signIn(of: Space.mailID) == nil)
        #expect(Extensions.signIn(of: Space.pinsID) == nil)
        #expect(Extensions.signIn(of: sharing) == nil)
        #expect(Extensions.signIn(of: own) == own)
    }

    @Test func portsAreKeptBySignIn() throws {
        let id = "fcoeoabgfenejglbffodgkkbkcdhcgfn", space = UUID()
        // The shared sign-in's key is the id alone, as it always was.
        #expect(ExtensionExternal.key(id, in: nil) == id)
        #expect(ExtensionExternal.parts(id).signIn == nil)
        #expect(ExtensionExternal.parts(id).id == id)
        let key = ExtensionExternal.key(id, in: space)
        #expect(key != id)
        #expect(ExtensionExternal.parts(key).signIn == space)
        #expect(ExtensionExternal.parts(key).id == id)
        // A folder's extension, "local-…", keeps its dash.
        #expect(ExtensionExternal.parts(ExtensionExternal.key("local-1a2b3c4d", in: space)).id == "local-1a2b3c4d")
        // A key stands as an omnibox row's host and is read back whole.
        let url = try #require(ExtensionOmnibox.address(key, content: "words"))
        #expect(ExtensionOmnibox.content(of: url)?.id == key)
    }

    /// Bringing Arc in (#358): each extension is read with the profiles
    /// it is on in, and goes to the sign-in of the space its profile came
    /// in as; the first profile's, and one with no space, to the shared.
    @Test func broughtExtensionsGoToTheirProfilesSpaces() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = FileManager.default
        let data = root.appendingPathComponent("User Data")
        let unpacked = { (name: String) throws -> URL in
            let made = root.appendingPathComponent("unpacked/" + name)
            try files.createDirectory(at: made, withIntermediateDirectories: true)
            try Data(#"{"manifest_version":3,"name":"\#(name)","version":"1.0"}"#.utf8).write(to: made.appendingPathComponent("manifest.json"))
            return made
        }
        let rabby = try unpacked("Rabby"), blocker = try unpacked("Blocker"), both = try unpacked("Both")
        func profile(_ name: String, _ entries: [(String, URL, Bool)]) throws {
            let folder = data.appendingPathComponent(name)
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            var settings: [String: Any] = [:]
            for (id, path, on) in entries { settings[id] = ["location": 4, "path": path.path, "state": on ? 1 : 0] }
            try JSONSerialization.data(withJSONObject: ["extensions": ["settings": settings]]).write(to: folder.appendingPathComponent("Secure Preferences"))
        }
        let a = String(repeating: "a", count: 32), b = String(repeating: "b", count: 32), c = String(repeating: "c", count: 32)
        try profile("Default", [(b, blocker, true), (c, both, true), (a, rabby, false)])
        try profile("Profile 1", [(a, rabby, true), (c, both, true)])
        var arc = try #require(Chromium.known.first { $0.name == "Arc" })
        arc.dataRoot = data
        let found = Chromium.extensions(in: arc)
        let by = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0.profiles) })
        // Off in Default, on in Profile 1: Profile 1's alone.
        #expect(by[a] == ["Profile 1"])
        #expect(by[b] == ["Default"])
        #expect(by[c] == ["Default", "Profile 1"])

        var work = Space(id: UUID(), name: "Work", icon: "💼", ownSignIns: true)
        work.signedInAs = "Arc:Profile 1"
        var chrome = Space(id: UUID(), name: "Chrome", icon: "🧪", ownSignIns: true)
        chrome.signedInAs = "Chrome:Profile 1"
        let home = Space(id: UUID(), name: "Home", icon: "🏠", ownSignIns: false)
        var lost = try #require(found.first { $0.id == a })
        lost.profiles = ["Profile 2"]
        let groups = Extensions.profileTargets(found + [lost], from: "Arc", spaces: [home, chrome, work])
        #expect(groups.map(\.signIn) == [nil, work.id])
        // Shared: Default's, and a profile's that has no space here.
        #expect(Set(groups[0].items.map(\.id)) == [b, c, a])
        #expect(Set(groups[1].items.map(\.id)) == [a, c])
    }
}
