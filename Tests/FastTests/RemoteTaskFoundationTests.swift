import Foundation
import SyncKit
import Testing
@testable import Fast

@MainActor struct RemoteTaskFoundationTests {
    private func owned() throws -> (Agents, Agents.Session, Journal, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("remote-task-foundation-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let journal = try Journal(path: folder.appendingPathComponent("journal.sqlite").path, device: "mac")
        let request = try TaskRecords.Request(account: "owned-account", phone: "phone", mac: "mac", space: "owned-space", words: "Owned public task")
        let raw = Record(collection: TaskRecords.requestCollection, id: request.id, fields: try request.fields(),
                         stamps: ["body": Stamp(wall: 1, device: "phone")])
        _ = try journal.receive([(record: raw, version: 1)])
        guard case let .reserved(mapping) = try journal.reserveTaskCommand(raw, account: "owned-account", device: "mac", phone: "phone",
                                                                          publicSpace: "owned-space", cli: "codex") else { throw TaskLaunch.Failure.context }
        let agents = Agents()
        let session = try agents.prepareRemoteTask(mapping, journal: journal, account: "owned-account", device: "mac")
        return (agents, session, journal, folder)
    }

    @Test func aPreparedSessionHasItsImmutableOriginAndNoProcessUntilLaunched() throws {
        let (agents, session, journal, folder) = try owned()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(agents.sessions.count == 1 && session.state == .starting && session.fromPhone && session.cli == "codex")
        #expect(session.remoteTask?.mapping.session == session.id)
        #expect(!session.full && !session.movable && session.process == nil && session.server == nil)
        let mapping = try #require(session.remoteTask?.mapping)
        let again = try agents.prepareRemoteTask(mapping, journal: journal,
                                                account: "owned-account", device: "mac")
        #expect(again === session && agents.sessions.count == 1 && again.prompt == "Owned public task")
    }

    /// A task sent for an earlier run of Yab, one that came too late, or one
    /// for a space this Mac hasn't is told back as failed, with words.
    @Test func aStaleALateOrAPlacelessTaskIsRefusedWithWords() throws {
        let now = Date()
        let request = try TaskRecords.Request(account: "owned-account", phone: "phone", mac: "mac", space: "owned-space",
                                              words: "Read the page", created: now, readOnlyEpoch: SyncCenter.taskEpoch)
        #expect(SyncCenter.taskRefusal(request, epoch: SyncCenter.taskEpoch, hasSpace: true, now: now) == nil)
        let earlier = UUID().uuidString.lowercased()
        #expect(SyncCenter.taskRefusal(request, epoch: earlier, hasSpace: true, now: now)?.contains("restarted") == true)
        #expect(SyncCenter.taskRefusal(request, epoch: SyncCenter.taskEpoch, hasSpace: false, now: now) == "That space isn't on your Mac.")
        let late = now.addingTimeInterval(SyncCenter.taskLifetime + 1)
        #expect(SyncCenter.taskRefusal(request, epoch: SyncCenter.taskEpoch, hasSpace: true, now: late)?.contains("too late") == true)
    }

    /// Its agent gets the read-only MCP server and the read-only brief; an
    /// ordinary task's server is unchanged.
    @Test func itsAgentIsGivenOnlyTheReadOnlyServer() throws {
        let (agents, session, _, folder) = try owned()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(agents.mcpArgs(session).contains("--phone-read-only"))
        let ordinary = Agents.Session(id: "ordinary", cli: "claude", name: "Claude", prompt: "Owned", state: .starting)
        #expect(!agents.mcpArgs(ordinary).contains("--phone-read-only"))
        #expect(Agents.remoteBrief.contains("only read"))
        // Only its own words may start it or reach its provider.
        #expect(session.lastSent.isEmpty)
    }

    @Test func everyCurrentBenchVerbAndUnknownVerbRefusesAllRemoteRequestRoutes() throws {
        let (agents, session, _, folder) = try owned()
        defer { try? FileManager.default.removeItem(at: folder) }
        let verbs = Bench.unattended.union(Bench.agentVerbs).union([
            "open", "close", "press", "act", "nav", "eval", "snapshot", "settle", "agent-native-click", "agent-native-key",
            "agent-plugin-call", "agent-run", "agent-ask", "agent-spawn", "agent-resume", "agent-computer", "agent-folder-access",
            "agent-cookie", "agent-cookies", "agent-sign-in", "agent-autofill", "agent-upload", "agent-fetch", "agent-read",
            "agent-mail-draft", "agent-message-send", "agent-eval", "agent-hold", "agent-use", "agent-name", "agent-boost",
            "agent-routine-add", "agent-routine-run", "agent-reply", "agent-permit", "future-unlisted-mutation"
        ])
        for verb in verbs {
            for key in ["callerSession", "session", "resume"] {
                let request: [String: Any] = ["do": verb, key: session.id, "always": true, "bypass": true, "approved": true]
                #expect(RemoteTaskBoundary.refusal(request, agents: agents) == RemoteTaskBoundary.unavailable)
            }
            #expect(RemoteTaskBoundary.refusal(["do": verb, "session": "unrelated-ordinary"], agents: agents) == nil)
        }
        #expect(session.process == nil && session.queue.isEmpty && !session.full)
    }

    @Test func directMCPTaskAndForeignTargetsCannotDetachTheActualInnerCaller() throws {
        let (agents, session, _, folder) = try owned()
        defer { try? FileManager.default.removeItem(at: folder) }
        for verb in ["agent-run", "agent-steer", "agent-queue", "agent-stop", "agent-wait", "agent-caps"] {
            let request: [String: Any] = ["do": verb, "session": "foreign-target", "callerSession": "spoofed", "resume": "foreign-target"]
            let bound = RemoteTaskBoundary.bindMCP(request, inner: true, session: session.id)
            #expect(bound["session"] as? String == "foreign-target")
            #expect(bound["callerSession"] as? String == session.id)
            #expect(RemoteTaskBoundary.refusal(bound, agents: agents) == RemoteTaskBoundary.unavailable)
            let ordinary = RemoteTaskBoundary.bindMCP(request, inner: false, session: "ordinary")
            #expect(NSDictionary(dictionary: ordinary).isEqual(NSDictionary(dictionary: request)))
        }
    }

    @Test func localResumeQueueSteerSpawnAndAccessUpgradeDoNotReachAProvider() throws {
        let (agents, session, _, folder) = try owned()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = session.prompt
        for _ in 0..<100 {
            let resumed = agents.run(prompt: "Do not launch this", cli: "claude", access: "full", resume: session.id)
            #expect(resumed === session)
            agents.queue(session.id, "Do not queue this")
            #expect(agents.steer(session.id, "Do not steer this") == RemoteTaskBoundary.unavailable)
            agents.allowMacAccess(session)
            agents.start(session, message: "Do not spawn a process")
            agents.send(session, "Do not write to a provider")
            #expect(agents.spawn(from: session.id, prompt: "Do not spawn a child", profile: "default", name: nil).0 == nil)
            #expect(agents.resume("foreign", from: session.id, prompt: "Do not resume a child").0 == nil)
        }
        #expect(session.prompt == original && session.queue.isEmpty && session.lastSent.isEmpty)
        #expect(session.input == nil && session.process == nil && session.server == nil && !session.full)
        #expect(agents.sessions.count == 1)
    }

    @Test func anOrdinaryPositiveAlwaysPermitCannotWriteToTheRemoteProvider() throws {
        let (agents, session, _, folder) = try owned()
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("owned-control-output")
        FileManager.default.createFile(atPath: output.path, contents: Data())
        let writer = try FileHandle(forWritingTo: output)
        defer { try? writer.close() }
        session.input = writer
        session.permission = .init(request: "owned-permit", tool: "click", title: "Owned action", detail: "Owned",
                                   input: Data("{}".utf8), suggestions: Data("[]".utf8))
        agents.permit(session.id, allow: true, always: true)
        #expect(session.permission?.request == "owned-permit")
        #expect(try writer.offset() == 0)
        #expect(try Data(contentsOf: output).isEmpty)
        #expect(session.process == nil && !session.full)
    }

    @Test func aRejectedFollowUpDoesNotAddAnUnsentTurn() throws {
        let (agents, session, _, folder) = try owned()
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = session.saying
        for state: Agents.State in [.starting, .done] {
            session.state = state
            #expect(agents.followUpProblem(session.id)?.contains("Start a new chat") == true)
            agents.followUp(session.id, "Keep these words", queue: true)
            #expect(session.saying == before && session.carrying.isEmpty && session.queue.isEmpty)
            #expect(session.process == nil && session.lastSent.isEmpty)
        }
        #expect(agents.followUpProblem("ordinary") == nil)
    }

    @Test func savedChatCodecAndLaterLocalMetadataCannotStripOrReplaceTheOrigin() throws {
        let (_, session, _, folder) = try owned()
        defer { try? FileManager.default.removeItem(at: folder) }
        let origin = try #require(session.remoteTask)
        var old = ChatTests.chat([])
        old.remoteTask = origin
        let restored = try JSONDecoder().decode(Chat.self, from: JSONEncoder().encode(old))
        #expect(restored.remoteTask == origin)
        var update = old
        update.remoteTask = nil
        update.title = "Local title"
        #expect(update.keepingMetadata(from: restored).remoteTask == origin)
        let ordinary = ChatTests.chat([])
        let bytes = try JSONEncoder().encode(ordinary)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("remoteTask"))
        #expect(try JSONDecoder().decode(Chat.self, from: bytes).remoteTask == nil)
    }

    @Test func oldOrChangedReservationCannotCreateANewLocalSession() throws {
        let (agents, session, journal, folder) = try owned()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mapping = try #require(session.remoteTask?.mapping)
        let changed = try TaskRecords.Request(id: mapping.request, account: mapping.account, phone: mapping.phone, mac: mapping.mac,
                                              space: mapping.space, words: "Changed remote request")
        let raw = Record(collection: TaskRecords.requestCollection, id: mapping.request, fields: try changed.fields(),
                         stamps: ["body": Stamp(wall: 2, device: "phone")])
        _ = try journal.receive([(record: raw, version: 2)])
        #expect(throws: (any Error).self) {
            try agents.prepareRemoteTask(mapping, journal: journal, account: mapping.account, device: mapping.mac)
        }
        #expect(agents.sessions.count == 1 && session.process == nil)
    }
}
