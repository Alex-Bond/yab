import Foundation
import Testing
@testable import Fast

// Settings › Agents › Memory and Skills: notes grouped by what they are
// about, when each changed in words, a note's name, and the files New
// Skill… and Duplicate to Edit write.
struct MemorySkillsSettingsTests {
    private static let now = Date(timeIntervalSince1970: 1_790_000_000) // Sep 21, 2026, in UTC
    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test func notesFindTheirKinds() {
        #expect(MemoryKind(path: "USER.md") == .you)
        #expect(MemoryKind(path: "users/me.md") == .you)
        #expect(MemoryKind(path: "MEMORY.md") == .agent)
        #expect(MemoryKind(path: "agent/replies.md") == .agent)
        #expect(MemoryKind(path: "people/jane-doe.md") == .people)
        #expect(MemoryKind(path: "sites/github.com.md") == .sites)
        #expect(MemoryKind(path: "episodic/2026-09-20.md") == .days)
        #expect(MemoryKind(path: "TAXONOMY.md") == nil)
        #expect(MemoryKind(path: "elsewhere/x.md") == nil)
    }

    @Test func notesAreGroupedInTheKindsOrder() {
        let day = Self.now
        let notes = [
            MemoryNote(path: "episodic/2026-09-19.md", title: "Saturday, September 19", changed: day),
            MemoryNote(path: "people/zoe.md", title: "Zoe", changed: day),
            MemoryNote(path: "episodic/2026-09-20.md", title: "Sunday, September 20", changed: day),
            MemoryNote(path: "users/more.md", title: "More about you", changed: day),
            MemoryNote(path: "people/adam.md", title: "Adam", changed: day),
            MemoryNote(path: "USER.md", title: "About you", changed: day),
            MemoryNote(path: "MEMORY.md", title: "How to work for you", changed: day),
        ]
        let groups = MemoryShelf.group(notes)
        #expect(groups.map(\.kind) == [.you, .agent, .people, .days])
        #expect(groups[0].notes.map(\.path) == ["USER.md", "users/more.md"])
        #expect(groups[2].notes.map(\.title) == ["Adam", "Zoe"])
        #expect(groups[3].notes.map(\.path) == ["episodic/2026-09-20.md", "episodic/2026-09-19.md"])
    }

    @Test func whenANoteChangedInWords() {
        let calendar = Self.utc
        let now = Self.now
        func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }
        #expect(MemoryShelf.when(now, now: now, calendar: calendar) == "Today")
        #expect(MemoryShelf.when(ago(1), now: now, calendar: calendar) == "Yesterday")
        #expect(MemoryShelf.when(ago(3), now: now, calendar: calendar) == "3 days ago")
        #expect(MemoryShelf.when(ago(9), now: now, calendar: calendar) == "Sep 12")
        #expect(MemoryShelf.when(ago(400), now: now, calendar: calendar) == "Aug 17, 2025")
        #expect(MemoryShelf.changed(now, now: now, calendar: calendar) == "Changed today")
        #expect(MemoryShelf.changed(ago(3), now: now, calendar: calendar) == "Changed 3 days ago")
        #expect(MemoryShelf.changed(ago(9), now: now, calendar: calendar) == "Changed on Sep 12")
    }

    @Test func aNoteIsNamedByWhatItSays() {
        #expect(MemoryShelf.title(path: "USER.md", body: "# User Briefing\n- Sam") == "About you")
        #expect(MemoryShelf.title(path: "people/jane-doe.md", body: "---\nname: Jane Doe\nkind: person\n---\n## Current") == "Jane Doe")
        #expect(MemoryShelf.title(path: "projects/yab.md", body: "# yab, the browser\n\n- ships Fridays") == "yab, the browser")
        #expect(MemoryShelf.title(path: "concepts/quiet-motion.md", body: "- frequent paths quiet") == "Quiet Motion")
        #expect(MemoryShelf.title(path: "sites/github.com.md", body: "- reviews on Files changed") == "github.com")
        #expect(MemoryShelf.title(path: "episodic/2026-09-24.md", body: "# 2026-09-24") == "Thursday, September 24")
    }

    @Test func newSkillIsNamedForItsSite() {
        #expect(SkillFiles.named("github.com")! == ("github", "github.com"))
        #expect(SkillFiles.named("https://www.Figma.com/")! == ("figma", "figma.com"))
        #expect(SkillFiles.named("docs.google.com/spreadsheets")! == ("docs-google", "docs.google.com/spreadsheets"))
        #expect(SkillFiles.named("My Bank")! == ("my-bank", nil))
        #expect(SkillFiles.named("  ") == nil)
        #expect(SkillFiles.named("!!!") == nil)
        #expect(SkillFiles.host("docs.google.com/spreadsheets") == "docs.google.com")
        #expect(SkillFiles.actions(0) == "")
        #expect(SkillFiles.actions(1) == "1 action")
        #expect(SkillFiles.actions(3) == "3 actions")
    }

    @Test func theTemplateIsASkill() throws {
        let text = SkillFiles.template(name: "github", site: "github.com")
        let skill = try #require(Skills.parse(text, own: true, path: URL(fileURLWithPath: "/tmp/github/SKILL.md")))
        #expect(skill.name == "github")
        #expect(skill.sites == ["github.com"])
        #expect(skill.keywords == ["github"])
        #expect(skill.body.hasPrefix("# github.com"))
        let bare = try #require(Skills.parse(SkillFiles.template(name: "my-bank", site: nil), own: true, path: URL(fileURLWithPath: "/tmp/x")))
        #expect(bare.sites.isEmpty)
        #expect(bare.body.hasPrefix("# My Bank"))
    }

    @Test func createAndDuplicateWriteWhereTheyShould() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skills-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let builtIn = root.appendingPathComponent("built-in/github")
        try FileManager.default.createDirectory(at: builtIn, withIntermediateDirectories: true)
        try "---\nname: github\n---\nbuilt in".write(to: builtIn.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "extra".write(to: builtIn.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        let mine = root.appendingPathComponent("mine")

        // Duplicated: the whole folder, into yours, under its own name.
        let copy = try SkillFiles.duplicate(builtIn.appendingPathComponent("SKILL.md"), into: mine)
        #expect(copy == mine.appendingPathComponent("github/SKILL.md"))
        #expect(FileManager.default.fileExists(atPath: mine.appendingPathComponent("github/notes.md").path))
        // A copy of yours already there is kept as it is.
        try "---\nname: github\n---\nmine".write(to: copy, atomically: true, encoding: .utf8)
        _ = try SkillFiles.duplicate(builtIn.appendingPathComponent("SKILL.md"), into: mine)
        #expect(try String(contentsOf: copy, encoding: .utf8).hasSuffix("mine"))

        // Made: a folder by its name with the template, never over one there.
        let made = try SkillFiles.create(name: "figma", site: "figma.com", in: mine)
        #expect(made == mine.appendingPathComponent("figma/SKILL.md"))
        #expect(try String(contentsOf: made, encoding: .utf8) == SkillFiles.template(name: "figma", site: "figma.com"))
        _ = try SkillFiles.create(name: "github", site: nil, in: mine)
        #expect(try String(contentsOf: copy, encoding: .utf8).hasSuffix("mine"))
    }
}
