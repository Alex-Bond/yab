import Foundation
import SyncKit
import Testing
@testable import Fast

/// Projects of chats (Projects.swift): how a chat carries its project on
/// disk and in sync, moving chats in and out, deleting, archiving, the
/// pinned order, what a project's chat is told, and what the iPhone may say.
@MainActor
struct ChatProjectsTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    init() { SyncShapes.register() }

    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("chat-projects-\(UUID().uuidString)")
    }

    /// A world of its own: chats and projects in temporary folders.
    private func world() -> (projects: Projects, chats: Chats, root: URL) {
        let root = folder()
        let projects = Projects(folder: root.appendingPathComponent("projects"))
        let chats = Chats(folder: root.appendingPathComponent("chats"), projects: projects)
        return (projects, chats, root)
    }

    private func chat(_ id: String, project: String? = nil) -> Chat {
        var chat = Chat(id: id, title: "Chat \(id)", began: .newTabs, cli: "claude", items: [ChatItem(id: "q", kind: .asked, text: "hi")],
                        state: "done", answer: "Answer \(id)", started: now, updated: now)
        chat.project = project
        return chat
    }

    // MARK: Chats keep their project

    @Test func aChatFromBeforeProjectsReadsAsItWas() throws {
        var plain = chat("old")
        let data = try JSONEncoder().encode(plain)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("\"project\""))
        let read = try JSONDecoder().decode(Chat.self, from: data)
        #expect(read.project == nil && read == plain)
        plain.project = "prj-abcd1234"
        let moved = try JSONDecoder().decode(Chat.self, from: JSONEncoder().encode(plain))
        #expect(moved.project == "prj-abcd1234")
    }

    @Test func aNewProjectTakesTheChatsTickedAndMovesThemBack() async throws {
        let (projects, chats, root) = world()
        defer { try? FileManager.default.removeItem(at: root) }
        for id in ["a", "b", "c"] { chats.keep(chat(id)) }
        let project = projects.add(name: "  Lisbon trip ", emoji: "🧳 extra", instructions: "Keep it cheap.", chats: ["a", "b"], in: chats, now: now)
        #expect(project.name == "Lisbon trip" && project.emoji == "🧳" && project.id.hasPrefix(Project.idPrefix))
        #expect(Set(chats.of(project: project.id).map(\.id)) == ["a", "b"])
        #expect(chats.chat("c")?.project == nil)

        chats.move(["c"], to: project.id)
        chats.move(["a"], to: nil)
        #expect(Set(chats.of(project: project.id).map(\.id)) == ["b", "c"])
        #expect(chats.chat("a")?.project == nil)

        // Kept on disk: a new Chats reads the project back.
        await chats.flush()
        #expect(Chats.read(root.appendingPathComponent("chats"), now: now).first { $0.id == "b" }?.project == project.id)
    }

    @Test func deletingAProjectLeavesItsChatsInChats() async throws {
        let (projects, chats, root) = world()
        defer { try? FileManager.default.removeItem(at: root) }
        for id in ["a", "b"] { chats.keep(chat(id)) }
        let project = projects.add(name: "Work", chats: ["a", "b"], in: chats, now: now)
        await projects.flush()
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("projects/\(project.id).json").path))

        projects.delete(project.id, chats: chats)
        #expect(projects.project(project.id) == nil)
        #expect(chats.all.count == 2)
        #expect(chats.all.allSatisfy { $0.project == nil })
        #expect(chats.chat("a")?.answer == "Answer a" && chats.chat("a")?.items.count == 1)
        await projects.flush()
        #expect(Projects.read(root.appendingPathComponent("projects")).isEmpty)
    }

    @Test func archivedProjectsLeaveTheListAndComeBack() {
        let (projects, chats, root) = world()
        defer { try? FileManager.default.removeItem(at: root) }
        let one = projects.add(name: "One", pinned: true, in: chats, now: now)
        let two = projects.add(name: "Two", in: chats, now: now.addingTimeInterval(1))
        projects.archive(one.id, true)
        #expect(projects.listed.map(\.id) == [two.id])
        #expect(projects.pinned.isEmpty)
        #expect(projects.archived.map(\.id) == [one.id])
        projects.archive(one.id, false)
        #expect(Set(projects.listed.map(\.id)) == [one.id, two.id])
        #expect(projects.pinned.map(\.id) == [one.id])
    }

    @Test func pinnedProjectsKeepTheirOrderAcrossARestart() async throws {
        let (projects, chats, root) = world()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = projects.add(name: "A", pinned: true, in: chats, now: now)
        let b = projects.add(name: "B", pinned: true, in: chats, now: now)
        let c = projects.add(name: "C", in: chats, now: now)
        #expect(projects.pinned.map(\.id) == [a.id, b.id])
        projects.pin(c.id, true)
        #expect(projects.pinned.map(\.id) == [a.id, b.id, c.id])
        projects.move(c.id, before: a.id)
        #expect(projects.pinned.map(\.id) == [c.id, a.id, b.id])
        projects.move(a.id, before: nil)
        #expect(projects.pinned.map(\.id) == [c.id, b.id, a.id])
        projects.pin(b.id, false)
        #expect(projects.pinned.map(\.id) == [c.id, a.id])
        await projects.flush()
        let again = Projects(folder: root.appendingPathComponent("projects"))
        #expect(again.pinned.map(\.id) == [c.id, a.id])
        #expect(again.all.count == 3)
    }

    @Test func anEditKeepsOneEmojiAndAKnownColor() {
        let (projects, chats, root) = world()
        defer { try? FileManager.default.removeItem(at: root) }
        var one = projects.add(name: "One", tint: "green", in: chats, now: now)
        #expect(one.tint == "green")
        one.emoji = ""
        one.tint = "chartreuse"
        one.instructions = "Answer in French."
        projects.update(one, now: now.addingTimeInterval(5))
        let read = projects.project(one.id)
        #expect(read?.emoji == "📁" && read?.tint == "green" && read?.instructions == "Answer in French.")
        #expect(read?.updated == now.addingTimeInterval(5))
        // New circles take the next color.
        #expect(projects.add(name: "Two", in: chats, now: now.addingTimeInterval(1)).tint == "orange")
    }

    // MARK: What its chats are told

    @Test func aProjectsChatIsToldItsInstructionsThenItsMemory() {
        var project = Project(id: "prj-abcd1234", name: "Lisbon", emoji: "🧳", tint: "blue",
                              instructions: "Keep hotels under €150.", created: now, updated: now, order: "m")
        let brief = project.brief(memory: ["The user flies from Berlin."], full: false)
        let said = brief.range(of: "Keep hotels under €150.")
        let known = brief.range(of: "- The user flies from Berlin.")
        #expect(brief.contains("\u{201C}Lisbon\u{201D}"))
        #expect(said != nil && known != nil)
        if let said, let known { #expect(said.lowerBound < known.lowerBound) }
        #expect(!brief.contains(project.files.path))
        #expect(project.brief(memory: [], full: true).contains(project.files.path))
        // Its memory off: nothing it remembers is told.
        project.memoryOn = false
        #expect(!project.brief(memory: ["The user flies from Berlin."], full: false).contains("Berlin"))
    }

    @Test func aChatOnItsOwnHasNoProjectBrief() {
        // No project, or one this Mac doesn't have: no brief to add.
        #expect(Projects(folder: folder()).project(nil) == nil)
        #expect(Projects(folder: folder()).project("prj-missing0") == nil)
    }

    @Test func aProjectsMemoryPageStaysOutOfTheSharedBrief() {
        #expect(Memory.projectPage("projects/prj-abcd1234.md"))
        #expect(!Memory.projectPage("projects/yab.md"))
        #expect(Memory.projectFile("prj-abcd1234")?.lastPathComponent == "prj-abcd1234.md")
    }

    // MARK: Routines

    @Test func aRoutineCarriesItsProjectThroughSync() throws {
        var routine = Routine(id: "r1", when: "every day at 9:00", prompt: "Check rent")
        routine.project = "prj-abcd1234"
        let records = SyncShapes.routines([routine], device: "mac")
        #expect(records["r1"]?["project"] == .string("prj-abcd1234"))
        let journal = try Journal(path: nil, device: "mac")
        try SyncShapes.reconcileRoutines(journal, [routine], device: "mac")
        #expect(SyncShapes.routines(from: journal.all(SyncShapes.routine)).first?.project == "prj-abcd1234")
        // One from before projects reads as on its own.
        let old = try JSONDecoder().decode(Routine.self, from: Data(#"{"id":"r2","when":"daily","prompt":"x"}"#.utf8))
        #expect(old.project == nil)
    }

    // MARK: Sync

    @Test func aProjectGoesWholeAndComesBack() throws {
        let (projects, chats, root) = world()
        defer { try? FileManager.default.removeItem(at: root) }
        let made = projects.add(name: "Lisbon", emoji: "🧳", tint: "teal", instructions: "Cheap.", pinned: true, in: chats, now: now)
        let records = SyncShapes.projects(projects.all)
        let fields = try #require(records[made.id])
        #expect(fields["name"] == .string("Lisbon") && fields["pinned"] == .bool(true) && fields["archived"] == .null)
        let journal = try Journal(path: nil, device: "mac")
        try journal.reconcile(SyncShapes.project, records)
        let read = try #require(SyncShapes.projects(from: journal.all(SyncShapes.project)).first)
        #expect(read.id == made.id && read.emoji == "🧳" && read.tint == "teal" && read.instructions == "Cheap." && read.pinned)
        #expect(read.order == made.order && read.created == now.timeIntervalSince1970)

        // Another Mac takes it in; one removed there goes here, its chats stay.
        let other = world()
        defer { try? FileManager.default.removeItem(at: other.root) }
        other.chats.keep(chat("x", project: made.id))
        other.projects.adopt([read], removed: [], chats: other.chats)
        #expect(other.projects.project(made.id)?.name == "Lisbon")
        other.projects.adopt([], removed: [made.id], chats: other.chats)
        #expect(other.projects.all.isEmpty)
        #expect(other.chats.chat("x")?.project == nil)
    }

    @Test func aRecordThatIsNoProjectIsLeftOut() {
        #expect(SyncProject(Record(collection: SyncCollection.project, id: "nope", fields: ["name": "x"])) == nil)
        #expect(SyncProject(Record(collection: SyncCollection.project, id: "prj-abcd1234", fields: [:])) == nil)
        #expect(SyncProject(Record(collection: SyncCollection.chat, id: "prj-abcd1234", fields: ["name": "x"])) == nil)
        let plain = SyncProject(Record(collection: SyncCollection.project, id: "prj-abcd1234", fields: ["name": "x", "created": 5]))
        #expect(plain?.memoryOn == true && plain?.pinned == false && plain?.updated == 5)
    }

    @Test func aChatsHeadCarriesItsProjectOnlyWhenItHasOne() throws {
        var head = SyncChat(id: "a:r", device: "mac", title: "Rent", state: "done", answer: "", cli: "claude", started: 1, updated: 2)
        #expect(head.fields["project"] == nil)
        head.project = "prj-abcd1234"
        let read = try #require(SyncChat(Record(collection: SyncCollection.chat, id: head.id, fields: head.fields)))
        #expect(read.project == "prj-abcd1234")
        var mine = chat("r", project: "prj-abcd1234")
        #expect(SyncChats.head(mine, kind: "agent", device: "mac")["project"] == .string("prj-abcd1234"))
        mine.project = nil
        #expect(SyncChats.head(mine, kind: "agent", device: "mac")["project"] == nil)
    }

    @Test func thePhoneMovesAChatByItsHead() throws {
        let (projects, chats, root) = world()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = projects.add(name: "Work", in: chats, now: now)
        chats.keep(chat("m"))
        let id = SyncChats.id(agent: "m")
        let mac = try Journal(path: nil, device: "mac")
        try mac.reconcile(SyncChats.chat, [id: SyncChats.head(try #require(chats.chat("m")), kind: "agent", device: "mac")])
        try mac.sent(mac.pending().map { ($0.record, Int64(1)) })

        func phone(_ fields: [String: Value], seq: Int64) throws -> [Record] {
            let phone = try Journal(path: nil, device: "phone")
            _ = try phone.receive(mac.all(SyncChats.chat).map { ($0, Int64(seq)) })
            try phone.change(.init(collection: SyncChats.chat, id: id), fields)
            return try mac.receive(phone.pending().map { ($0.record, seq + 1) })
        }

        // Into a project this Mac has.
        #expect(SyncChats.adopt(try phone(["project": .string(project.id)], seq: 1), device: "mac", chats: chats) == [id])
        #expect(chats.chat("m")?.project == project.id)
        // The Mac's own head says the same, no echo back.
        let echo = try mac.reconcile(SyncChats.chat, [id: SyncChats.head(try #require(chats.chat("m")), kind: "agent", device: "mac")])
        #expect(echo.isEmpty)
        try mac.sent(mac.pending().map { ($0.record, Int64(3)) })
        // Out of it again.
        _ = SyncChats.adopt(try phone(["project": .null], seq: 3), device: "mac", chats: chats)
        #expect(chats.chat("m")?.project == nil)
        try mac.sent(mac.pending().map { ($0.record, Int64(5)) })
        // Into one this Mac doesn't have, or a malformed id: stays where it is.
        _ = SyncChats.adopt(try phone(["project": .string("prj-gone0000")], seq: 5), device: "mac", chats: chats)
        #expect(chats.chat("m")?.project == nil)
        _ = SyncChats.adopt(try phone(["project": .string("../x")], seq: 7), device: "mac", chats: chats)
        #expect(chats.chat("m")?.project == nil)
    }

    @Test func theMacSaysItTakesProjects() {
        let fields = SyncChats.capability(device: "mac")
        #expect(ChatProjects.supports(Record(collection: OpenOnMac.capability, id: "mac", fields: fields), device: "mac"))
        var older = fields
        older[ChatProjects.field] = nil
        #expect(!ChatProjects.supports(Record(collection: OpenOnMac.capability, id: "mac", fields: older), device: "mac"))
    }

    @Test func aNewChatInAProjectFromThePhoneIsTaken() throws {
        let base: [String: Value] = ["device": "mac", "clientDevice": "phone", "clientChat": "local", "text": "Plan day two",
                                    "at": .number(now.timeIntervalSince1970)]
        let fine = Record(collection: SyncChats.send, id: "s1", fields: base.merging(["project": "prj-abcd1234"]) { _, b in b })
        #expect(ChatCommand.refusal(fine) == nil)
        let words = try #require(SyncChats.waiting([fine], device: "mac").first)
        #expect(words.project == "prj-abcd1234" && !words.invalidAgent)
        // With an agent picked too.
        let picked = Record(collection: SyncChats.send, id: "s2", fields: [
            "device": "mac", "kind": "agent", "cli": "claude", "agentText": "Plan day two", "project": "prj-abcd1234",
            "at": .number(now.timeIntervalSince1970)])
        #expect(ChatCommand.refusal(picked) == nil)
        #expect(SyncChats.waiting([picked], device: "mac").first?.invalidAgent == false)
        // Into an existing chat, or not a project's id: refused.
        for bad: [String: Value] in [["project": "prj-abcd1234", "chat": "a:x"], ["project": "known"], ["project": .bool(true)]] {
            let record = Record(collection: SyncChats.send, id: "bad", fields: base.merging(bad) { _, b in b })
            #expect(ChatCommand.refusal(record) != nil)
        }
        // A project this Mac doesn't have: said so, nothing run.
        let missing = SyncChats.Words(id: "s3", chat: nil, text: "hi", kind: "agent", project: "prj-gone0000", choice: nil, at: now)
        #expect(SyncCenter().say(missing).reason == ChatProjects.missing)
    }
}
