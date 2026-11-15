import AppKit
import Foundation
import Network
import SyncKit
import Testing
import WebKit
@testable import Fast
@testable import SyncKit

@MainActor struct RemoteTaskReadTests {
    @MainActor private final class Owned {
        let folder: URL
        private var retainedClient: SyncClient?
        var client: SyncClient { retainedClient! }
        let server = MemoryServer()
        let agents = Agents()
        let browser: Browser
        let bench = Bench()
        let request: TaskRecords.Request
        let mapping: TaskLaunch.Mapping
        let session: Agents.Session
        var context: SyncTaskRead.Context?
        var reader: SyncTaskRead!
        var cookies: [(WKWebsiteDataStore, HTTPCookie)] = []

        init() throws {
            guard Store.testing else { throw TaskLaunch.Failure.context }
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("remote-task-read-\(UUID())")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let seal = Seal.make()
            let journal = try Journal(path: folder.appendingPathComponent("journal.sqlite").path, device: "mac")
            retainedClient = SyncClient(base: URL(string: "https://sync.test")!, journal: journal, seal: seal,
                                device: .init(id: "mac", name: "Owned Mac", model: "Mac"), transport: server)
            browser = Browser(windowID: UUID())
            browser.spaces = [Space(id: Space.firstID, name: "Owned public space", icon: "folder", ownSignIns: false)]
            request = try TaskRecords.Request(account: seal.account, phone: "phone", mac: "mac",
                                               space: Space.firstID.uuidString.lowercased(), words: "Read the owned loopback page")
            let raw = Record(collection: TaskRecords.requestCollection, id: request.id, fields: try request.fields(),
                             stamps: ["body": Stamp(wall: 1, device: "phone")])
            _ = try journal.receive([(record: raw, version: 1)])
            guard case let .reserved(value) = try journal.reserveTaskCommand(raw, account: seal.account, device: "mac", phone: "phone",
                                     publicSpace: request.space, cli: "codex") else { throw TaskLaunch.Failure.context }
            mapping = value
            session = try agents.prepareRemoteTask(mapping, journal: journal, account: seal.account, device: "mac")
            context = .init(client: retainedClient!, phones: [.init(id: "phone", name: "Owned phone", model: "iPhone", lastSeen: nil, revoked: false)], browser: browser)
            reader = SyncTaskRead(agents: agents, current: { [weak self] in self?.context })
        }

        func start() async throws {
            client.start()
            // Live after a sign-in whose key stretching is PBKDF2: a second
            // alone, longer with the rest of a full test run on every core.
            guard await RemoteTaskReadTests.until(seconds: 30, { self.client.queue.sync { self.client.state == .live } }) else { throw TaskLaunch.Failure.context }
            try reader.register(mapping)
            // A real native session field/event transition, with no provider process.
            session.state = .running
            agents.note(session, "Actual engine event: reading")
        }

        func call(_ verb: String, _ fields: [String: Any] = [:]) async -> [String: Any] {
            let input: [String: Any] = ["do": verb, "callerSession": session.id, "session": session.id]
            return await withCheckedContinuation { continuation in
                let handled = reader.handle(input.merging(fields) { _, b in b }, browser: browser, bench: bench) {
                    continuation.resume(returning: $0)
                }
                if !handled { continuation.resume(returning: ["ordinary": true]) }
            }
        }

        func dispose() async {
            weak var clientLease = retainedClient
            weak var journalLease = retainedClient?.journal
            reader.stop()
            reader = nil
            context = nil
            for (store, cookie) in cookies {
                await withCheckedContinuation { done in store.httpCookieStore.delete(cookie) { done.resume() } }
            }
            cookies = []
            // All tabs here belong to this disposable Browser, not the person.
            browser.close(browser.tabs)
            if let client = retainedClient {
                client.stop()
                let off = await RemoteTaskReadTests.until { client.queue.sync { client.state == .off } }
                #expect(off)
                client.queue.sync {}
            }
            retainedClient = nil
            let released = await RemoteTaskReadTests.until { clientLease == nil && journalLease == nil }
            #expect(released)
            // If an owner is still alive, retain the database instead of
            // unlinking SQLite beneath an open connection.
            if released { try? FileManager.default.removeItem(at: folder) }
        }
    }

    private func withOwned(_ body: (Owned) async throws -> Void) async throws {
        let owned = try Owned()
        do {
            try await body(owned)
        } catch {
            await owned.dispose()
            throw error
        }
        await owned.dispose()
    }

    /// Checked once more at the deadline: a main thread held past it by
    /// another suite (TypingCostTests held it 16 s in the N-Z shard) wakes
    /// with the condition met and must not count that as a timeout.
    private static func until(seconds: Double = 4, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        (try? await Loaded.until(seconds, every: .milliseconds(10)) { condition() }) ?? condition()
    }
    private func until(seconds: Double = 4, _ condition: @escaping @MainActor () -> Bool) async -> Bool { await Self.until(seconds: seconds, condition) }

    @Test func actualEngineStatesNeverInventCompletionAndFailuresRetainTheirRealReason() throws {
        let session = Agents.Session(id: UUID().uuidString, cli: "codex", name: "Actual agent", prompt: "Owned", state: .starting)
        session.title = "Actual task title"; session.now = "Actual event"
        for state in [Agents.State.starting, .signingIn, .running, .attached] {
            session.state = state
            let observation = AgentTaskObservation(session)
            #expect(observation.status == .running && observation.title == session.title && observation.progress == session.now && observation.result == nil)
        }
        session.state = .waiting
        #expect(AgentTaskObservation(session).status == .needsYou)
        session.state = .failed; session.result = "Actual provider failure"
        #expect(AgentTaskObservation(session).progress == "Actual provider failure" && AgentTaskObservation(session).result == nil)
        session.state = .done; session.result = " \n "
        #expect(AgentTaskObservation(session).status == .failed)
        session.result = "Actual completed result"
        #expect(AgentTaskObservation(session).status == .done && AgentTaskObservation(session).result == "Actual completed result")
        session.state = .stopped
        #expect(AgentTaskObservation(session).status == .stopped && AgentTaskObservation(session).result == nil)
    }

    @Test func nativeEngineEventsCheckpointActualFieldsAndStopAtTheFirstTerminalResult() async throws {
        try await withOwned { owned in
            try await owned.start()
            let journal = owned.client.journal
            let firstValue = try journal.taskObservation(mapping: owned.mapping, account: owned.request.account, device: "mac")
            let first = try #require(firstValue)
            #expect(first.status == .running && first.progress == "Actual engine event: reading" && first.revision == 1)
            owned.session.title = "Observed title"; owned.session.progress = "Observed progress"; owned.session.state = .waiting
            owned.agents.note(owned.session, "Actual waiting event")
            let waitingValue = try journal.taskObservation(mapping: owned.mapping, account: owned.request.account, device: "mac")
            let waiting = try #require(waitingValue)
            #expect(waiting.status == .needsYou && waiting.title == "Observed title" && waiting.progress == "Observed progress" && waiting.revision == 2)
            owned.session.state = .done; owned.session.result = "Actual native result"
            owned.agents.note(owned.session, "Completed native event")
            let doneValue = try journal.taskObservation(mapping: owned.mapping, account: owned.request.account, device: "mac")
            let done = try #require(doneValue)
            owned.session.state = .running; owned.agents.note(owned.session, "Late event after done")
            #expect(try journal.taskObservation(mapping: owned.mapping, account: owned.request.account, device: "mac") == done)
            #expect(done.status == .done && done.result == "Actual native result" && done.revision == 3)
            #expect(owned.session.process == nil && owned.session.server == nil && owned.session.input == nil && !owned.session.full)
        }
    }

    @Test func everyMutationAndWideningRefusesEvenPositiveAlwaysBypassAndForeignTargets() async throws {
        try await withOwned { owned in
            try await owned.start()
            let verbs = Bench.agentVerbs.union(Bench.unattended).subtracting(SyncTaskRead.verbs).union([
                "press", "act", "eval", "nav", "agent-native-click", "agent-cookie", "agent-fetch", "agent-run", "agent-permit", "future-write"
            ])
            let before = owned.browser.tabs.map(\.id)
            for verb in verbs {
                let result = await owned.call(verb, ["always": true, "bypass": true, "approved": true, "access": "full"])
                #expect(result["error"] as? String != nil && result["ordinary"] == nil)
            }
            let widened: [[String: Any]] = [["space": "other"], ["method": "POST"], ["headers": ["Authorization": "owned"]], ["body": "owned"], ["resume": "other"], ["session": "other"]]
            for fields in widened {
                let result = await owned.call("open", fields.merging(["url": "http://127.0.0.1:1/owned"]) { _, b in b })
                #expect(result["error"] as? String != nil)
            }
            let caps = await owned.call("agent-caps")
            #expect(caps["readOnly"] as? Bool == true && caps["canWrite"] as? Bool == false && caps["native"] as? Bool == false)
            #expect(owned.browser.tabs.map(\.id) == before && owned.session.process == nil && owned.session.permission == nil)
            #expect(!owned.session.full && owned.session.queue.isEmpty && owned.session.lastSent.isEmpty)
        }
    }

    @Test func revokedPhoneChangedAccountAndStoppedCoordinatorCannotReadOrPublishALateCallback() async throws {
        try await withOwned { owned in
            try await owned.start()
            let before = owned.client.journal.record(.init(collection: TaskRecords.observationCollection, id: owned.request.id))
            owned.context = .init(client: owned.client, phones: [.init(id: "phone", name: "Owned", model: "iPhone", lastSeen: nil, revoked: true)], browser: owned.browser)
            let revoked = await owned.call("agent-tabs")
            #expect(revoked["error"] as? String != nil)
            owned.agents.note(owned.session, "Late revoked event")
            #expect(owned.client.journal.record(.init(collection: TaskRecords.observationCollection, id: owned.request.id)) == before)
            let other = try SyncClient(base: URL(string: "https://sync.test")!, journal: Journal(path: nil, device: "mac"), seal: Seal.make(),
                                       device: .init(id: "mac", name: "Other", model: "Mac"), transport: MemoryServer())
            owned.context = .init(client: other, phones: [.init(id: "phone", name: "Owned", model: "iPhone", lastSeen: nil, revoked: false)], browser: owned.browser)
            #expect((await owned.call("text", ["id": UUID().uuidString]))["error"] as? String != nil)
            owned.reader.stop()
            owned.context = .init(client: owned.client, phones: [.init(id: "phone", name: "Owned", model: "iPhone", lastSeen: nil, revoked: false)], browser: owned.browser)
            #expect((await owned.call("agent-tabs"))["error"] as? String != nil)
            owned.agents.note(owned.session, "Late restored context event")
            #expect(owned.client.journal.record(.init(collection: TaskRecords.observationCollection, id: owned.request.id)) == before)
            #expect(throws: (any Error).self) { try owned.reader.register(owned.mapping) }
        }
    }

    @Test func theActualOwnedHTTPPageUsesCapturedPublicCookiesAndNeverSelectsOrAdoptsAUserTab() async throws {
        try await withOwned { owned in
            try await owned.start()
            let site = try RemoteReadSite(); defer { site.stop() }
            let blank = URL(string: "about:blank")!
            let home = owned.browser.open(blank, foreground: true, atEnd: true)
            let privateTab = owned.browser.open(blank, foreground: false, atEnd: true, shy: true)
            let active = owned.browser.activeID, homeWeb = home.page
            let store = Spaces.store(for: Space.firstID)
            let name = "owned-\(UUID().uuidString)"
            let cookie = try #require(HTTPCookie(properties: [.name: name, .value: "public-read-cookie", .domain: "127.0.0.1", .path: "/"]))
            owned.cookies.append((store, cookie))
            await withCheckedContinuation { done in store.httpCookieStore.setCookie(cookie) { done.resume() } }
            let opened = await owned.call("open", ["url": site.url.absoluteString])
            let id = try #require(opened["id"] as? String)
            let tab = try #require(owned.browser.tabs.first { $0.id.uuidString.lowercased() == id })
            #expect(tab.bench && !tab.shy && tab.agent == owned.session.id && tab.pageStore === store)
            #expect(requireNativeWebKitFixture(tab, "iPhone restricted read autoplay configuration").configuration.mediaTypesRequiringUserActionForPlayback == .all)
            #expect(tab.delegate is RemoteReadPage)
            // Up to 30 s, as `start` waits: beside the whole N-Z shard on a
            // loaded adhd the page came (the server heard its cookie) and
            // was still not done at 12.
            let finished = await until(seconds: 30) { tab.page.url == site.url && !tab.loading && tab.page.title == "Owned native read page" }
            #expect(finished, "at \(tab.page.url?.absoluteString ?? "nil"), loading \(tab.loading), Page loading \(tab.page.isLoading), titled \(tab.page.title ?? "nil"), the server heard \(site.header.isEmpty ? "nothing" : "the request")")
            let read = await owned.call("text", ["id": id])
            #expect((read["text"] as? String)?.contains("Owned actual HTTP response") == true)
            #expect(site.header.contains("\(name)=public-read-cookie"))
            #expect(owned.browser.activeID == active && home.page === homeWeb && owned.browser.tabs.prefix(2).map(\.id) == [home.id, privateTab.id])
            for target in [home.id.uuidString, privateTab.id.uuidString, String(id.prefix(8)), "all"] {
                #expect((await owned.call("text", ["id": target]))["error"] as? String != nil)
            }
            let policy = try #require(tab.delegate as? RemoteReadPage)
            owned.reader.stop()
            #expect(!policy.current() && !owned.browser.tabs.contains { $0 === tab })
            #expect(owned.browser.activeID == active && owned.browser.tabs.map(\.id) == [home.id, privateTab.id])
            #expect(owned.session.process == nil && owned.session.server == nil)
            owned.browser.close([home, privateTab])
        }
    }

    @Test func requestAndResponsePoliciesRejectPostFilesCredentialsPopupsAndDownloads() throws {
        let good = URL(string: "https://owned.test/read?q=one#two")!
        #expect(RemoteReadPage.permits(URLRequest(url: good)))
        for url in ["file:///owned", "javascript:alert(1)", "data:text/html,owned", "https://owned:secret@owned.test", "owned-app://open"] {
            #expect(!RemoteReadPage.permits(URLRequest(url: URL(string: url)!)))
        }
        var post = URLRequest(url: good); post.httpMethod = "POST"
        #expect(!RemoteReadPage.permits(post))
        var body = URLRequest(url: good); body.httpBody = Data("owned".utf8)
        #expect(!RemoteReadPage.permits(body))
        #expect(!RemoteReadPage.permits(URLRequest(url: good), download: true))
        #expect(!RemoteReadPage.permits(URLRequest(url: good), newWindow: true))
        let attachment = try #require(HTTPURLResponse(url: good, statusCode: 200, httpVersion: nil, headerFields: ["Content-Disposition": "attachment; filename=owned.txt"]))
        #expect(!RemoteReadPage.permits(attachment, canShow: true))
        let page = try #require(HTTPURLResponse(url: good, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"]))
        #expect(RemoteReadPage.permits(page, canShow: true) && !RemoteReadPage.permits(page, canShow: false))
    }
}

/// Owned loopback only, full bounded headers and a complete FIN response.
private final class RemoteReadSite: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "owned-remote-read-http")
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var requestHeader = ""
    private var stopped = false
    var url: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/owned-read")! }
    var header: String { queue.sync { requestHeader } }

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state { case .ready, .failed: ready.signal(); default: break }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 4) == .success, listener.port != nil else {
            listener.cancel(); throw TaskLaunch.Failure.context
        }
    }

    func stop() {
        queue.sync {
            stopped = true; listener.newConnectionHandler = nil; listener.stateUpdateHandler = nil; listener.cancel()
            for connection in connections.values { connection.cancel() }; connections = [:]
        }
    }

    private func serve(_ connection: NWConnection) {
        guard !stopped else { connection.cancel(); return }
        connections[ObjectIdentifier(connection)] = connection
        connection.start(queue: queue)
        receive(connection, Data())
    }

    private func receive(_ connection: NWConnection, _ previous: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, !self.stopped else { connection.cancel(); return }
            var head = previous; if let data { head.append(data) }
            guard head.count <= 65_536, error == nil else { self.finish(connection); return }
            guard head.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if complete { self.finish(connection) } else { self.receive(connection, head) }; return
            }
            self.requestHeader = String(decoding: head, as: UTF8.self)
            let body = Data("<!doctype html><title>Owned native read page</title><body><h1>Owned actual HTTP response</h1><p>Only disposable loopback data.</p></body>".utf8)
            var response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
            response.append(body)
            connection.send(content: response, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in self?.finish(connection) })
        }
    }

    private func finish(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = nil
        connection.cancel()
    }
}
