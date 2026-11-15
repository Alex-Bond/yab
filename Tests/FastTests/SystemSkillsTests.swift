import Foundation
import Testing
@testable import Fast

struct SystemSkillsTests {
    private func document(_ name: String, body: String = "Read the release page.") -> String {
        "---\nname: \(name)\ndescription: Release checks.\nsites: [example.com/releases]\nkeywords: [release check, release audit]\n---\n\n\(body)"
    }

    @Test func savingIsScopedAndRejectsStaleUpdates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = document("release-check")
        let file = try SkillWriter.save(name: "release-check", document: first, replacing: nil, in: root)
        #expect(file == root.appendingPathComponent("release-check/SKILL.md"))
        #expect(try String(contentsOf: file, encoding: .utf8) == first)
        let second = document("release-check", body: "Read both the release and changelog.")
        #expect(throws: SkillWriter.Invalid.self) {
            try SkillWriter.save(name: "release-check", document: second, replacing: nil, in: root)
        }
        try SkillWriter.save(name: "release-check", document: second, replacing: SkillWriter.revision(first), in: root)
        #expect(throws: SkillWriter.Invalid.self) {
            try SkillWriter.save(name: "release-check", document: first, replacing: SkillWriter.revision(first), in: root)
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == second)
        #expect(throws: SkillWriter.Invalid.self) {
            try SkillWriter.save(name: "missing", document: document("missing"), replacing: SkillWriter.revision(first), in: root)
        }
    }

    @Test func invalidDocumentsNeverCreateFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["../outside", "/tmp/outside", ".hidden", "two--dashes", "Uppercase", "valid\n"] {
            #expect(throws: SkillWriter.Invalid.self) {
                try SkillWriter.save(name: name, document: document(name), replacing: nil, in: root)
            }
        }
        for text in ["body only", "---\nname: valid\n---\nBody",
                     "---\nname: valid\ndescription: Test\n---\n",
                     document("other"), document("valid", body: String(repeating: "x", count: 65_536))] {
            #expect(throws: SkillWriter.Invalid.self) {
                try SkillWriter.save(name: "valid", document: text, replacing: nil, in: root)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func symlinkFoldersAndFilesCannotRedirectWrites() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let mine = root.appendingPathComponent("mine"), outside = root.appendingPathComponent("outside")
        try fm.createDirectory(at: mine, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let linkedFolder = mine.appendingPathComponent("linked")
        try fm.createSymbolicLink(at: linkedFolder, withDestinationURL: outside)
        #expect(throws: SkillWriter.Invalid.self) {
            try SkillWriter.save(name: "linked", document: document("linked"), replacing: nil, in: mine)
        }
        #expect(!fm.fileExists(atPath: outside.appendingPathComponent("SKILL.md").path))
        let folder = mine.appendingPathComponent("file-link")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        // A dangling link must not be mistaken for an absent document.
        try fm.createSymbolicLink(at: folder.appendingPathComponent("SKILL.md"),
                                  withDestinationURL: outside.appendingPathComponent("missing"))
        #expect(throws: SkillWriter.Invalid.self) {
            try SkillWriter.save(name: "file-link", document: document("file-link"), replacing: nil, in: mine)
        }
        #expect(!fm.fileExists(atPath: outside.appendingPathComponent("missing").path))
    }

    @Test func keywordDiscoveryUnderstandsPhrasesAndWordBoundaries() throws {
        let release = try #require(Skills.parse(document("release-check"), own: false, path: URL(fileURLWithPath: "/release")))
        let map = try #require(Skills.parse("---\nname: visual-reading\nkeywords: [map]\n---\nRead a map.", own: false, path: URL(fileURLWithPath: "/map")))
        let skills = [release, map]
        #expect(Skills.matching("First the RELEASE AUDIT, then publishing", in: skills).map(\.name) == ["release-check"])
        #expect(Skills.matching("a release check please", in: skills).map(\.name) == ["release-check"])
        #expect(Skills.matching("show the roadmap", in: skills).isEmpty)
        #expect(Skills.matching("read this map", in: skills).map(\.name) == ["visual-reading"])
        #expect(Skills.matching("", in: skills).isEmpty)
    }

    @Test func shippedSystemSkillsAreValidAndDiscoverable() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Skills")
        let names = ["skill-creator", "image-search", "bitwarden", "1password", "proton-pass", "nordpass", "dashlane", "lastpass", "apple-passwords",
                     "password-manager", "notification-activation", "visualize", "yab"]
        var skills: [Skills.Skill] = []
        for name in names {
            let file = root.appendingPathComponent(name + "/SKILL.md")
            let text = try String(contentsOf: file, encoding: .utf8)
            try SkillWriter.validate(name: name, document: text)
            skills.append(try #require(Skills.parse(text, own: false, path: file)))
        }
        #expect(Skills.matching("find images for this page", in: skills).map(\.name) == ["image-search"])
    }

    @Test func skillWritesAreHiddenAndRefusedForReadingAndChildTasks() throws {
        let save = try #require(Mcp.byName["skill_save"])
        for audience in [Mcp.Audience(inner: true, sub: true),
                         Mcp.Audience(inner: true, sub: true, profile: "context_explorer"),
                         Mcp.Audience(inner: true, phoneReadOnly: true)] {
            #expect(!save.listed(for: audience))
            #expect(Mcp.phoneRefusal("skill_save", audience) != nil || Mcp.refusal("skill_save", [:], audience) != nil)
        }
        #expect(save.listed(for: Mcp.Audience(inner: true)))
    }

    @Test func captchasGoStraightToTheUser() throws {
        let captcha = Mcp.page(["needs": "captcha", "tree": "challenge"], tab: "a")
        #expect(captcha.contains("needs: captcha, call handoff; do not fill it in yourself"))
        #expect(Mcp.page(["needs": "a password"], tab: "a").contains("never type it yourself"))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Skills")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("captcha-solver").path))
        let handoff = try #require(Mcp.byName["handoff"])
        #expect(handoff.description.contains("never try to solve it"))
        #expect(!Guide.main.contains("captcha-solver") && !Guide.tools.contains("captcha-solver") && !Mcp.guide.contains("captcha-solver"))
    }

    @Test func agentSkillsCantMarkPostsAsReads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let posting = "---\nname: notes\ndescription: Notes.\nsites: [example.com]\nread: POST example.com/api/send | send\n---\n\nRead notes."
        #expect(throws: SkillWriter.Invalid.self) { try SkillWriter.save(name: "notes", document: posting, replacing: nil, in: root) }
        let getting = posting.replacingOccurrences(of: "read: POST", with: "read: GET")
        try SkillWriter.save(name: "notes", document: getting, replacing: nil, in: root)
    }

    @Test func theCardSaysWhatASaveReplaces() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let mine = root.appendingPathComponent("mine"), builtIn = root.appendingPathComponent("built")
        try fm.createDirectory(at: builtIn.appendingPathComponent("gmail"), withIntermediateDirectories: true)
        try document("gmail").write(to: builtIn.appendingPathComponent("gmail/SKILL.md"), atomically: true, encoding: .utf8)
        #expect(SkillWriter.replaces("gmail", in: mine, builtIn: builtIn).contains("built-in"))
        #expect(SkillWriter.replaces("release-check", in: mine, builtIn: builtIn) == "A new skill for every task")
        try SkillWriter.save(name: "release-check", document: document("release-check"), replacing: nil, in: mine)
        #expect(SkillWriter.replaces("release-check", in: mine, builtIn: builtIn).contains("your skill"))
        // check writes nothing; the yes is bound to these exact words.
        try SkillWriter.check(name: "other", document: document("other"), replacing: nil, in: mine)
        #expect(!fm.fileExists(atPath: mine.appendingPathComponent("other").path))
        #expect(SkillWriter.key(name: "a", document: "x") != SkillWriter.key(name: "a", document: "y"))
        let permit = AgentPermit(kind: .saveSkill(name: "gmail", key: SkillWriter.key(name: "gmail", document: "x")), session: "s", detail: "")
        #expect(permit.weighty && permit.ruleLabel == nil && permit.answers.map(\.title) == ["Save"])
    }

    @Test func anEmptyQueryListsEverySkill() {
        #expect(Skills.index(query: "") == Skills.index())
        #expect(Skills.index(query: "  ") == Skills.index())
    }

    @Test func screenshotPointsRespectZoomAndViewport() {
        let size = CGSize(width: 800, height: 600)
        #expect(AgentCoordinates.point(x: 512, y: 384, size: size, zoom: 2) == CGPoint(x: 200, y: 150))
        #expect(AgentCoordinates.point(x: 1024, y: 0, size: size, zoom: 1) == nil)
        #expect(AgentCoordinates.point(x: 0, y: 768, size: size, zoom: 1) == nil)
        #expect(AgentCoordinates.point(x: -1, y: 10, size: size, zoom: 1) == nil)
        #expect(AgentCoordinates.point(x: .infinity, y: 10, size: size, zoom: 1) == nil)
        #expect(AgentCoordinates.point(x: 10, y: 10, size: size, zoom: 0) == nil)
        #expect(AgentCoordinates.point(x: 10, y: 10, size: CGSize(width: CGFloat.infinity, height: 600), zoom: 1) == nil)
    }
}
