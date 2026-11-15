import Foundation
import Testing
@testable import Fast

/// Row 1752: two spaces of one profile of another browser are one sign-in.
@MainActor
struct SpaceLinkTests {
    private func space(_ name: String, as profile: String?, own: Bool = true) -> Space {
        var made = Space(id: UUID(), name: name, icon: "📁", ownSignIns: own)
        made.signedInAs = profile
        return made
    }

    @Test func secondSpaceOfAProfileJoinsTheFirst() {
        var spaces = [space("Alpha", as: nil, own: false), space("Beta", as: "Arc:Profile 1"),
                      space("Gamma", as: "Arc:Profile 1"), space("Delta", as: "Arc:Profile 2")]
        let joined = Spaces.link(&spaces)
        #expect(joined.count == 1)
        #expect(joined.first?.from == spaces[2].id && joined.first?.to == spaces[1].id)
        #expect(spaces[2].signInWith == spaces[1].id)
        #expect(spaces[1].signInWith == nil && spaces[3].signInWith == nil)
        #expect(Spaces.routing(spaces) == [spaces[2].id: spaces[1].id])
        // Once: read again it is left as it is.
        #expect(Spaces.link(&spaces).isEmpty)
    }

    @Test func aSpaceJoinsTheOwnerItsProfileAlreadyHas() {
        let gone = UUID()
        var first = space("Beta", as: "Arc:Profile 1")
        first.signInWith = gone
        var spaces = [space("Gamma", as: "Arc:Profile 1"), first]
        #expect(Spaces.link(&spaces).map(\.to) == [gone])
        #expect(spaces[0].signInWith == gone)
    }

    @Test func spacesApartStayApart() {
        var spaces = [space("Mine", as: nil), space("Yours", as: nil),
                      space("Shared", as: "Arc:Profile 1", own: false), space("Own", as: "Arc:Profile 1")]
        #expect(Spaces.link(&spaces).isEmpty)
        #expect(Spaces.routing(spaces).isEmpty)
    }

    @Test func aSignInIsWrittenAndReadBack() throws {
        var made = space("Gamma", as: "Arc:Profile 1")
        made.signInWith = UUID()
        let back = try JSONDecoder().decode(Space.self, from: JSONEncoder().encode(made))
        #expect(back.signInWith == made.signInWith)
    }

    @Test func mergeBringsWhatIsMissingAndTouchesNothingElse() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let from = root.appendingPathComponent("from.json"), to = root.appendingPathComponent("to.json")
        let storage = root.appendingPathComponent("gamma"), target = root.appendingPathComponent("beta")
        for folder in ["both", "only"] {
            try FileManager.default.createDirectory(at: storage.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: target.appendingPathComponent("both"), withIntermediateDirectories: true)
        let marker = target.appendingPathComponent("both/kept")
        try Data("here".utf8).write(to: marker)
        func item(_ id: String) -> Installed {
            Installed(id: id, name: id, version: "1", enabled: true, fromStore: true, permissions: [])
        }
        try JSONEncoder().encode([item("both"), item("only")]).write(to: from)
        try JSONEncoder().encode([item("both")]).write(to: to)
        Extensions.merge(list: from, into: to, storage: storage, to: target)
        let list = try JSONDecoder().decode([Installed].self, from: Data(contentsOf: to))
        #expect(list.map(\.id) == ["both", "only"])
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("only").path))
        #expect(FileManager.default.fileExists(atPath: marker.path))
        // What it had stays where it was.
        #expect(FileManager.default.fileExists(atPath: from.path))
    }
}
