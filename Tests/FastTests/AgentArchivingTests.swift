import Foundation
import Testing
@testable import Fast

@MainActor
struct AgentArchivingTests {
    private func session(cli: String = "codex", state: Agents.State = .done) -> Agents.Session {
        Agents.Session(id: UUID().uuidString, cli: cli, name: "Background", prompt: "Read", state: state)
    }

    @Test func onlyAutomaticBackgroundConversationsAreArchived() {
        for cli in ["claude", "codex"] {
            let user = session(cli: cli)
            #expect(!Agents.archivesProvider(user))
            user.providerBackground = true
            #expect(Agents.archivesProvider(user))
            user.providerBackground = false
            user.parent = "main-agent"
            #expect(Agents.archivesProvider(user))
            user.parent = nil
            user.quiet = true
            #expect(Agents.archivesProvider(user))
            user.quiet = false
            user.sealed = true
            #expect(Agents.archivesProvider(user))
        }
        let external = session(cli: "external")
        external.quiet = true
        external.parent = "main-agent"
        #expect(!Agents.archivesProvider(external))
    }

    @Test func chatsYabBeganAreArchivedButStayOrdinaryChats() {
        for cli in ["claude", "codex"] {
            let task = session(cli: cli)
            #expect(!Agents.archivesAfterAnswer(task))
            task.task = true
            #expect(Agents.archivesAfterAnswer(task))
            let routine = session(cli: cli)
            routine.routine = "daily"
            #expect(Agents.archivesAfterAnswer(routine))
            // `yab "…"` from a terminal, a script or another agent.
            for person in ["tty", "caller", "none"] {
                let command = session(cli: cli)
                command.person = person
                #expect(Agents.archivesAfterAnswer(command))
                #expect(!Agents.archivesProvider(command))
            }
            for began in [Chat.Began.newTabs, .here] {
                let revived = session(cli: cli)
                revived.origin = began
                #expect(Agents.archivesAfterAnswer(revived))
                // Still the person's chat: remembered, not labelled an agent's.
                #expect(!Agents.archivesProvider(revived))
            }
        }
        let external = session(cli: "external")
        external.task = true
        #expect(!Agents.archivesAfterAnswer(external))
    }

    @Test func activeOrUnknownConversationsAreLeftAlone() {
        let agents = Agents()
        for state in [Agents.State.starting, .running, .waiting, .signingIn] {
            let active = session(state: state)
            active.parent = "main"
            active.thread = "only-after-the-answer"
            agents.archiveProvider(active)
            #expect(active.archiveTask == nil)
        }
        let unknown = session()
        unknown.quiet = true
        agents.archiveProvider(unknown)
        #expect(unknown.archiveTask == nil)
        let ordinary = session()
        ordinary.thread = "user-owned"
        agents.archiveProvider(ordinary)
        #expect(ordinary.archiveTask == nil)
    }

    @Test func legacyForkNeverArchivesItsParentsProviderThread() {
        let agents = Agents()
        let parent = agents.attach(name: "Parent fixture")
        parent.cli = "codex"
        parent.state = .done
        parent.thread = "shared-provider"
        let child = session()
        child.parent = parent.id
        child.profile = "fork_self"
        child.thread = parent.thread
        agents.archiveProvider(child)
        #expect(child.archiveTask == nil)
        #expect(parent.archiveTask == nil)
        #expect(parent.thread == "shared-provider")
    }

    @Test func finalAnswerIsKeptAndStdinStaysOpenUntilArchiveAcknowledged() async throws {
        let fixture = IsolatedProviderConsent("codex")
        defer { fixture.close() }
        let agents = Agents()
        let (server, wire) = CodexServerTests.opened()
        _ = CodexServerTests.ready(server, wire, id: "child-thread")
        let child = session()
        child.providerPermit = try #require(fixture.consent.permit("codex"))
        child.parent = "main"
        child.thread = "child-thread"
        child.server = server
        child.result = "The useful answer"
        child.items = [ChatItem(id: "answer", kind: .message, text: child.result, state: .done)]
        let pipe = Pipe()
        child.input = pipe.fileHandleForWriting
        // Told by the reading end, which this test alone holds: EOF only
        // once every writer is closed. A number checked with F_GETFD can
        // be handed to another test's file in between.
        let reader = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(reader, F_SETFL, fcntl(reader, F_GETFL) | O_NONBLOCK)
        let stdinEnded = { () -> Bool in
            var byte: UInt8 = 0
            return read(reader, &byte, 1) == 0
        }

        agents.archiveProvider(child)
        let retirement = try #require(child.archiveTask)
        for _ in 0..<20 where wire.last["method"] as? String != "thread/archive" { await Task.yield() }
        #expect(wire.last["method"] as? String == "thread/archive")
        #expect(child.input == nil)
        #expect(!stdinEnded())
        let count = wire.lines.count
        agents.archiveProvider(child)
        #expect(wire.lines.count == count)
        _ = server.heard(["id": wire.last["id"]!, "result": [:]])
        await retirement.value
        #expect(stdinEnded())
        #expect(child.archiveError == nil)
        #expect(child.result == "The useful answer")
        #expect(child.items.first?.text == child.result)
        #expect(child.state == .done)
    }

    @Test func cleanupFailureDoesNotReplaceTheAnswerOrItsState() async throws {
        let fixture = IsolatedProviderConsent("codex")
        defer { fixture.close() }
        let agents = Agents()
        let child = session(state: .failed)
        child.providerPermit = try #require(fixture.consent.permit("codex"))
        child.quiet = true
        child.thread = "failed-child"
        child.binary = "/nonexistent-yab-archive-stub"
        child.result = "Could not read the page"
        agents.archiveProvider(child)
        await child.archiveTask?.value
        #expect(child.archiveError != nil)
        #expect(child.result == "Could not read the page")
        #expect(child.state == .failed)
    }

    @Test func aTurnEndingBeforeItsStartReplyStillFinishesAndArchives() async throws {
        let fixture = IsolatedProviderConsent("codex")
        defer { fixture.close() }
        let agents = Agents()
        let (server, wire) = CodexServerTests.opened()
        _ = CodexServerTests.ready(server, wire, id: "early-child")
        let child = session(state: .running)
        child.providerPermit = try #require(fixture.consent.permit("codex"))
        child.parent = "main"
        child.thread = "early-child"
        child.server = server
        child.result = "Finished before the acknowledgement"
        agents.send(child, "task")
        let start = wire.last["id"]!
        agents.hear(server.heard(["method": "turn/completed", "params": ["threadId": "early-child", "turn": ["id": "u1", "status": "completed"]]]), on: child)
        #expect(child.state == .running)
        #expect(child.archiveTask == nil)
        agents.hear(server.heard(["id": start, "result": ["turn": ["id": "u1"]]]), on: child)
        #expect(child.state == .done)
        let retirement = try #require(child.archiveTask)
        for _ in 0..<20 where wire.last["method"] as? String != "thread/archive" { await Task.yield() }
        #expect(wire.last["method"] as? String == "thread/archive")
        _ = server.heard(["id": wire.last["id"]!, "result": [:]])
        await retirement.value
        #expect(child.archiveError == nil)
        #expect(child.result == "Finished before the acknowledgement")
    }

    @Test func backgroundOwnershipSurvivesSavedChatDecoding() throws {
        let child = session()
        child.providerBackground = true
        let saved = Agents().chat(of: child)
        let reloaded = try JSONDecoder().decode(Chat.self, from: JSONEncoder().encode(saved))
        #expect(reloaded.providerBackground == true)
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as! [String: Any]
        legacy.removeValue(forKey: "providerBackground")
        let old = try JSONDecoder().decode(Chat.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(old.providerBackground == nil)
    }

    @Test func fallbackUsesTheLaunchedHomeAndArchivesWithoutResumingOrStartingATurn() async throws {
        let fixture = IsolatedProviderConsent("codex")
        defer { fixture.close() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-archive-wire-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = root.appendingPathComponent("codex-stub")
        let log = root.appendingPathComponent("wire.jsonl")
        try """
        #!/usr/bin/python3
        import json, os, sys
        with open(os.environ['ARCHIVE_WIRE'], 'a') as log:
            log.write(json.dumps({'home': os.environ['CODEX_HOME'], 'args': sys.argv[1:]}) + '\\n')
            log.flush()
            for line in sys.stdin:
                message = json.loads(line)
                log.write(json.dumps(message) + '\\n')
                log.flush()
                if 'id' in message:
                    print(json.dumps({'id': message['id'], 'result': {}}), flush=True)
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)
        let child = session()
        child.providerPermit = try #require(fixture.consent.permit("codex"))
        child.quiet = true
        child.thread = "exact-child"
        child.binary = stub.path
        child.folder = root.path
        child.full = true
        child.env = ["CODEX_HOME": "/wrong-account"]
        child.providerEnvironment = ["CODEX_HOME": root.appendingPathComponent("probe-account").path, "ARCHIVE_WIRE": log.path]
        child.providerArchiveArgs = ["-c", "sqlite_home=\"isolated-index\"", "-c", "cli_auth_credentials_store=\"file\""]
        Agents().archiveProvider(child)
        await child.archiveTask?.value
        #expect(child.archiveError == nil)
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
        #expect(lines.first?["home"] as? String == child.providerEnvironment["CODEX_HOME"])
        #expect(lines.first?["args"] as? [String] == ["app-server"] + child.providerArchiveArgs)
        #expect(lines.dropFirst().compactMap { $0["method"] as? String } == ["initialize", "initialized", "thread/archive"])
        #expect((lines.last?["params"] as? [String: Any])?["threadId"] as? String == "exact-child")
    }

    @Test func aRevokedPermitCannotWriteTheArchiveProtocol() async throws {
        let fixture = IsolatedProviderConsent("codex")
        defer { fixture.close() }
        let permit = try #require(fixture.consent.permit("codex"))
        let (server, wire) = CodexServerTests.opened()
        _ = CodexServerTests.ready(server, wire, id: "denied-child")
        let child = session()
        child.providerPermit = permit
        child.parent = "main"
        child.thread = "denied-child"
        child.server = server
        child.result = "Preserved answer"
        let before = wire.lines.count
        fixture.consent.revoke("codex")
        Agents().archiveProvider(child)
        await child.archiveTask?.value
        #expect(wire.lines.count == before)
        #expect(child.result == "Preserved answer" && child.state == .done)
        #expect(!permit.valid && !fixture.consent.allows("codex"))
    }
}
