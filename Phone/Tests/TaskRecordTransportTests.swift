import Foundation
import SyncKit
import XCTest
@testable import YabPhone

@MainActor
final class TaskRecordTransportTests: XCTestCase {
    private var folder: URL!
    private var leases: [OwnedJournalLease] = []

    private final class OwnedJournalLease {
        weak var engine: PhoneSync?
        weak var client: SyncClient?
        weak var journal: Journal?
        init(_ engine: PhoneSync) {
            self.engine = engine
            client = engine.client
            journal = engine.journal
        }
        init(_ client: SyncClient) { self.client = client; journal = client.journal }
        func stop() {
            if let engine { engine.stop() }
            else { client?.stop() }
        }
        var released: Bool { engine == nil && client == nil && journal == nil }
    }
    private let space = "00000000-0000-0000-0000-000000000041"
    private let tab = "owned-source-tab"
    private let sourceURL = "http://127.0.0.1:9137/owned?q=a%2Bb#source"
    private let sourceTitle = "Owned public source"

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("TaskRecordTransportTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        leases.forEach { $0.stop() }
        // stop() queues its work. Wait for actual object release, not .off.
        let released = await until { self.leases.allSatisfy(\.released) }
        guard released else {
            XCTFail("Owned sync journals are still retained; preserving the test folder without unlinking open SQLite files")
            return
        }
        leases = []
        // Preserve owned SQLite files: weak Swift release is not a kernel
        // close barrier for every asynchronous SQLite connection.
    }

    private func until(_ done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(4)
        while Date() < end {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return done()
    }

    private func phone(_ server: SyncMemoryServer, _ seal: Seal, callbacks: DispatchQueue = .main) throws -> PhoneSync {
        let engine = try PhoneSync(seal: seal, options: .init(base: URL(string: "https://sync.test")!, folder: folder,
                                                            device: .init(id: "phone", name: "Owned task iPhone", model: "iPhone"),
                                                            transport: server, callbacks: callbacks))
        leases.append(OwnedJournalLease(engine))
        return engine
    }

    private func origin(isPrivate: Bool = false) -> TaskRecords.Origin {
        .init(space: space, tab: tab, url: sourceURL, title: sourceTitle, isPrivate: isPrivate)
    }

    private func joined(supported: Bool = true, callbacks: DispatchQueue = .main) async throws
        -> (PhoneSync, TestMac, SyncMemoryServer, Seal) {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try TestMac(server: server, seal: seal, id: "mac")
        leases.append(OwnedJournalLease(mac.client))
        mac.client.start()
        let live = await until { mac.client.state == .live }
        XCTAssertTrue(live)
        try mac.write(OpenOnMac.capability, "mac", ["device": "mac", "open": 1,
                                                   "taskRecords": supported ? 1 : .null])
        try mac.write(SyncCollection.space, space, SyncSpace(id: space, name: "Owned public space", icon: "").fields)
        try mac.write(SyncCollection.tab, tab, SyncTab(id: tab, space: space, url: sourceURL, title: sourceTitle).fields)
        let phone = try phone(server, seal, callbacks: callbacks)
        phone.start()
        let ready = await until { phone.state == .live && phone.macs.contains { $0.id == "mac" }
            && phone.journal.record(.init(collection: SyncCollection.tab, id: self.tab)) != nil }
        XCTAssertTrue(ready)
        if supported {
            let capable = await until { phone.canTransportTaskRecords(on: "mac") }
            XCTAssertTrue(capable)
        }
        return (phone, mac, server, seal)
    }

    private func phones(_ client: SyncClient) async -> [SyncClient.Listed] {
        await withCheckedContinuation { continuation in
            client.devices { continuation.resume(returning: $0 ?? []) }
        }
    }

    private func retained(_ request: TaskRecords.Request, on mac: TestMac) async throws -> Record {
        let arrived = await until { mac.journal.record(.init(collection: TaskRecords.requestCollection, id: request.id)) != nil }
        XCTAssertTrue(arrived)
        return try XCTUnwrap(mac.journal.record(.init(collection: TaskRecords.requestCollection, id: request.id)))
    }

    private func encryptedBodies(_ server: SyncMemoryServer, account: String) -> [String] {
        server.lock.lock(); defer { server.lock.unlock() }
        return (server.records[account] ?? [:]).values.map(\.blob)
    }

    @MainActor private final class Heard { var values: [TaskRecords.Observation] = [] }

    private final class DeliveryGate: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        private var failure: String?
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !claimed else { return false }
            claimed = true
            return true
        }
        func fail(_ error: String) { lock.lock(); failure = error; lock.unlock() }
        var error: String? { lock.lock(); defer { lock.unlock() }; return failure }
    }

    func testEncryptedRequestAndMacObservationKeepExactCapturedContextAndOnlyRealRevision() async throws {
        let (phone, mac, server, seal) = try await joined()
        defer { phone.stop(); mac.client.stop() }
        let heard = Heard()
        phone.onTaskRecords = { values in MainActor.assumeIsolated { heard.values += values } }
        let words = "Read this owned page and report its visible heading."
        let request = try phone.sendTaskRecord(words, on: "mac", origin: origin())
        let raw = try await retained(request, on: mac)
        XCTAssertEqual(try TaskRecords.Request.read(raw, account: seal.account, phone: "phone", mac: "mac"), request)
        XCTAssertEqual(request.url, sourceURL)
        XCTAssertEqual(request.title, sourceTitle)
        XCTAssertEqual(request.space, space)
        XCTAssertEqual(request.tab, tab)
        XCTAssertEqual(request.words, words)
        XCTAssertNotNil(UUID(uuidString: request.id))
        XCTAssertTrue(phone.taskRecords().isEmpty, "No local timer or words classifier creates a result")
        XCTAssertTrue(phone.sends().isEmpty)
        XCTAssertTrue(mac.journal.living(SyncCollection.send).isEmpty, "The old chat parser gets no fallback")
        let encrypted = encryptedBodies(server, account: seal.account)
        XCTAssertFalse(encrypted.isEmpty)
        XCTAssertFalse(encrypted.contains { $0.contains(words) || $0.contains(sourceURL) })

        let known = await phones(mac.client)
        let waiting = try TaskRecords.Observation(request: request, revision: 1, status: .waits,
                                                  title: "Owned observer", progress: "No task has been executed")
        // A read must not consume the observer's first delivery. The owned
        // record is retained before a transport callback sees the newer stamp.
        let early = Record(collection: TaskRecords.observationCollection, id: request.id, fields: try waiting.fields(),
                           stamps: ["body": Stamp(wall: 1, device: "mac")])
        _ = try phone.journal.receive([(record: early, version: 0)])
        XCTAssertTrue(phone.taskRecords().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("task-records.json").path))
        try TaskRecords.publish(waiting, requestRecord: raw, client: mac.client, knownPhones: known)
        let first = await until { heard.values.last == waiting }
        XCTAssertTrue(first)
        XCTAssertEqual(phone.taskRecords(), [waiting])
        // These are explicitly supplied records from the owned Mac test client,
        // not proof of a real agent run or browser effect.
        let done = try TaskRecords.Observation(request: request, revision: 2, session: "owned-observer-session", status: .done,
                                               title: "Owned observer", progress: "Observation received",
                                               result: "Owned visible heading", resultURL: sourceURL)
        try TaskRecords.publish(done, requestRecord: raw, client: mac.client, knownPhones: known)
        let second = await until { heard.values.last == done }
        XCTAssertTrue(second)
        XCTAssertEqual(phone.taskRecords(), [done])
        XCTAssertEqual(heard.values.map(\.revision), [1, 2])
        XCTAssertThrowsError(try TaskRecords.publish(waiting, requestRecord: raw, client: mac.client, knownPhones: known))
    }

    func testPrivateOldUnknownAndRevokedOwnersRefuseBeforeAnyRequestOrLegacySendWrite() async throws {
        let (phone, mac, server, _) = try await joined(supported: false)
        defer { phone.stop(); mac.client.stop() }
        XCTAssertThrowsError(try phone.sendTaskRecord("Owned old request", on: "mac", origin: origin()))
        XCTAssertThrowsError(try phone.sendTaskRecord("Owned unknown request", on: "unknown", origin: origin()))
        try mac.write(OpenOnMac.capability, "mac", ["taskRecords": 1])
        let supported = await until { phone.canTransportTaskRecords(on: "mac") }
        XCTAssertTrue(supported)
        XCTAssertThrowsError(try phone.sendTaskRecord("Private words must not be exported", on: "mac", origin: origin(isPrivate: true)))
        XCTAssertThrowsError(try phone.sendTaskRecord("Private space even with wrong caller flag", on: "mac",
                                                     origin: .init(space: "local.private", isPrivate: false)))
        XCTAssertTrue(phone.journal.all(TaskRecords.requestCollection).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("task-records.json").path))
        server.revoke("mac"); phone.refreshMacs()
        let revoked = await until { !phone.macs.contains { $0.id == "mac" } }
        XCTAssertTrue(revoked)
        XCTAssertFalse(phone.canTransportTaskRecords(on: "mac"), "A cached capability is not a known owner")
        XCTAssertThrowsError(try phone.sendTaskRecord("Owned revoked request", on: "mac", origin: origin()))
        XCTAssertTrue(phone.journal.all(TaskRecords.requestCollection).isEmpty)
        XCTAssertTrue(phone.sends().isEmpty)
    }

    func testChangedMovedMissingAndCredentialPageContextsFailBeforeWriting() async throws {
        let (phone, mac, _, _) = try await joined()
        defer { phone.stop(); mac.client.stop() }
        let captured = origin()
        try mac.write(SyncCollection.tab, tab, ["url": "http://127.0.0.1:9137/changed"])
        let changed = await until { phone.journal.record(.init(collection: SyncCollection.tab, id: self.tab))?["url"]?.string?.hasSuffix("changed") == true }
        XCTAssertTrue(changed)
        XCTAssertThrowsError(try phone.sendTaskRecord("Owned stale source", on: "mac", origin: captured))
        try mac.write(SyncCollection.tab, tab, ["parent": "different-space", "url": .string(sourceURL)])
        let moved = await until { phone.journal.record(.init(collection: SyncCollection.tab, id: self.tab))?["parent"]?.string == "different-space" }
        XCTAssertTrue(moved)
        XCTAssertThrowsError(try phone.sendTaskRecord("Owned moved source", on: "mac", origin: captured))
        XCTAssertThrowsError(try phone.sendTaskRecord("Owned missing source", on: "mac",
                                                     origin: .init(space: space, tab: "absent", isPrivate: false)))
        try mac.write(SyncCollection.tab, tab, ["parent": .string(space), "url": "http://user:password@127.0.0.1/owned"])
        let credentials = await until { phone.journal.record(.init(collection: SyncCollection.tab, id: self.tab))?["url"]?.string?.contains("user:password") == true }
        XCTAssertTrue(credentials)
        XCTAssertThrowsError(try phone.sendTaskRecord("Owned credential source", on: "mac",
                                                     origin: .init(space: space, tab: tab, url: "http://user:password@127.0.0.1/owned",
                                                                   title: sourceTitle, isPrivate: false)))
        XCTAssertTrue(phone.journal.all(TaskRecords.requestCollection).isEmpty)
        XCTAssertTrue(phone.sends().isEmpty)
    }

    func testMacOfflineAndPhoneRelaunchRetainTheSameRequestWithoutAnInventedResult() async throws {
        let (phone, mac, server, seal) = try await joined()
        defer { mac.client.stop() }
        mac.client.stop()
        let asleep = await until { mac.client.state == .off }
        XCTAssertTrue(asleep)
        let request = try phone.sendTaskRecord("Owned offline request", on: "mac", origin: origin())
        XCTAssertTrue(phone.taskRecords().isEmpty)
        phone.stop()
        let stopped = await until { phone.state == .off }
        XCTAssertTrue(stopped)
        let again = try self.phone(server, seal)
        defer { again.stop() }
        again.start()
        let known = await until { again.canTransportTaskRecords(on: "mac") }
        XCTAssertTrue(known)
        let original = try XCTUnwrap(again.journal.record(.init(collection: TaskRecords.requestCollection, id: request.id)))
        XCTAssertEqual(try TaskRecords.Request.read(original, account: seal.account, phone: "phone", mac: "mac"), request)
        XCTAssertTrue(again.taskRecords().isEmpty)
        XCTAssertTrue(again.sends().isEmpty)
        mac.client.start()
        let awake = await until { mac.client.state == .live }
        XCTAssertTrue(awake)
        let raw = try await retained(request, on: mac)
        let waiting = try TaskRecords.Observation(request: request, revision: 1, status: .waits,
                                                  title: "Owned observer", progress: "The retained request arrived")
        let listed = await phones(mac.client)
        try TaskRecords.publish(waiting, requestRecord: raw, client: mac.client, knownPhones: listed)
        let observed = await until { again.taskRecords() == [waiting] }
        XCTAssertTrue(observed)
        XCTAssertEqual(again.journal.living(TaskRecords.requestCollection).count, 1)
    }

    func testCapabilityLateArrivalReleasesItsRealObservationOnceAndRevocationHidesIt() async throws {
        let (phone, mac, server, _) = try await joined()
        defer { phone.stop(); mac.client.stop() }
        let request = try phone.sendTaskRecord("Owned retained request", on: "mac", origin: origin())
        let raw = try await retained(request, on: mac)
        try mac.write(OpenOnMac.capability, "mac", ["taskRecords": .null])
        let old = await until { !phone.canTransportTaskRecords(on: "mac") }
        XCTAssertTrue(old)
        let heard = Heard()
        phone.onTaskRecords = { values in MainActor.assumeIsolated { heard.values += values } }
        let observation = try TaskRecords.Observation(request: request, revision: 1, status: .waits,
                                                      title: "Owned observer", progress: "Actual retained revision")
        let listed = await phones(mac.client)
        try TaskRecords.publish(observation, requestRecord: raw, client: mac.client, knownPhones: listed)
        let arrived = await until { phone.journal.record(.init(collection: TaskRecords.observationCollection, id: request.id)) != nil }
        XCTAssertTrue(arrived)
        XCTAssertTrue(heard.values.isEmpty)
        XCTAssertTrue(phone.taskRecords().isEmpty)
        try mac.write(OpenOnMac.capability, "mac", ["taskRecords": 1])
        let released = await until { heard.values == [observation] }
        XCTAssertTrue(released)
        try mac.write(OpenOnMac.capability, "mac", ["open": 2])
        let unchanged = await until { phone.journal.record(.init(collection: OpenOnMac.capability, id: "mac"))?["open"]?.number == 2 }
        XCTAssertTrue(unchanged)
        XCTAssertEqual(heard.values, [observation])
        server.revoke("mac"); phone.refreshMacs()
        let revoked = await until { !phone.macs.contains { $0.id == "mac" } }
        XCTAssertTrue(revoked)
        XCTAssertTrue(phone.taskRecords().isEmpty, "Retained data does not bypass a revoked owner")
    }

    func testInboxRetainsHighWaterAcrossReopenAndRejectsReplacementEngineLateRollback() throws {
        let request = try ownRequest()
        let file = folder.appendingPathComponent("high-water.json")
        let first = try TaskRecordInbox(file: file, account: request.account, phone: request.phone)
        let staleEngine = try TaskRecordInbox(file: file, account: request.account, phone: request.phone)
        let one = try TaskRecords.Observation(request: request, revision: 1, status: .waits, title: "Owned", progress: "First")
        let two = try TaskRecords.Observation(request: request, revision: 2, status: .waits, title: "Owned", progress: "Second")
        XCTAssertTrue(try first.accept(one, request: request))
        XCTAssertTrue(try first.accept(two, request: request))
        XCTAssertThrowsError(try staleEngine.accept(one, request: request))
        XCTAssertFalse(try staleEngine.accept(two, request: request))
        let conflict = try TaskRecords.Observation(request: request, revision: 2, status: .failed, title: "Owned", progress: "Conflict")
        XCTAssertThrowsError(try staleEngine.accept(conflict, request: request))
        let reopened = try TaskRecordInbox(file: file, account: request.account, phone: request.phone)
        XCTAssertEqual(try reopened.current(request: request), two)
        XCTAssertThrowsError(try TaskRecordInbox(file: file, account: "other-account", phone: request.phone))
        XCTAssertThrowsError(try TaskRecordInbox(file: file, account: request.account, phone: "other-phone"))
    }

    func testStorageFailureNeverReleasesANewResultAndCorruptInboxFailsClosed() async throws {
        let (phone, mac, _, _) = try await joined()
        defer { phone.stop(); mac.client.stop() }
        let request = try phone.sendTaskRecord("Owned storage refusal", on: "mac", origin: origin())
        let raw = try await retained(request, on: mac)
        let heard = Heard()
        phone.onTaskRecords = { values in MainActor.assumeIsolated { heard.values += values } }
        let file = folder.appendingPathComponent("task-records.json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        let observation = try TaskRecords.Observation(request: request, revision: 1, status: .waits,
                                                      title: "Owned", progress: "Must be retained before callback")
        let listed = await phones(mac.client)
        try TaskRecords.publish(observation, requestRecord: raw, client: mac.client, knownPhones: listed)
        let arrived = await until { phone.journal.record(.init(collection: TaskRecords.observationCollection, id: request.id)) != nil }
        XCTAssertTrue(arrived)
        XCTAssertTrue(phone.taskRecords().isEmpty)
        XCTAssertTrue(heard.values.isEmpty)
        try FileManager.default.removeItem(at: file)
        try Data("corrupt".utf8).write(to: file)
        XCTAssertThrowsError(try TaskRecordInbox(file: file, account: request.account, phone: request.phone))
    }

    func testDedicatedShapeAndMacStampedObservationRejectMixedWrongOwnerAndUnboundedBodies() throws {
        let request = try ownRequest()
        let phoneStamp = Stamp(wall: 1, device: request.phone), macStamp = Stamp(wall: 2, device: request.mac)
        var raw = Record(collection: TaskRecords.requestCollection, id: request.id, fields: try request.fields(), stamps: ["body": phoneStamp])
        XCTAssertEqual(try TaskRecords.Request.read(raw, account: request.account, phone: request.phone), request)
        XCTAssertThrowsError(try TaskRecords.Request.read(raw, account: "another", phone: request.phone))
        XCTAssertThrowsError(try TaskRecords.Request.read(raw, account: request.account, phone: request.phone, mac: "another"))
        raw.set("text", "A legacy command must not be read", at: phoneStamp)
        XCTAssertThrowsError(try TaskRecords.Request.read(raw, account: request.account, phone: request.phone))
        raw.fields = ["body": .string(String(repeating: "x", count: 524_289))]
        XCTAssertThrowsError(try TaskRecords.Request.read(raw, account: request.account, phone: request.phone))
        XCTAssertThrowsError(try ownRequest(words: String(repeating: "x", count: 524_289)))
        XCTAssertThrowsError(try TaskRecords.Request(account: "account", phone: "phone", mac: "mac", space: space,
                                                    tab: tab, url: "http://name:secret@127.0.0.1/", words: "Owned"))
        let observation = try TaskRecords.Observation(request: request, revision: 1, status: .waits, title: "Owned", progress: "Observed")
        var seen = Record(collection: TaskRecords.observationCollection, id: request.id, fields: try observation.fields(), stamps: ["body": macStamp])
        XCTAssertEqual(try TaskRecords.Observation.read(seen, request: request), observation)
        seen.stamps["body"] = phoneStamp
        XCTAssertThrowsError(try TaskRecords.Observation.read(seen, request: request))
        seen.stamps["body"] = macStamp; seen.schema = 2
        XCTAssertThrowsError(try TaskRecords.Observation.read(seen, request: request))
        XCTAssertThrowsError(try TaskRecords.Observation(request: request, revision: 1, status: .done,
                                                        title: "Owned", progress: "No session or actual result"))
        let cap = Record(collection: OpenOnMac.capability, id: "mac", fields: ["device": "mac", "taskRecords": 1],
                         stamps: ["device": macStamp, "taskRecords": macStamp])
        XCTAssertTrue(TaskRecords.supports(cap, mac: "mac"))
        var falseCap = cap; falseCap.stamps["taskRecords"] = phoneStamp
        XCTAssertFalse(TaskRecords.supports(falseCap, mac: "mac"))
    }

    func testMacPublisherRejectsAnUnknownRequestOrRevokedPhoneBeforeWriting() async throws {
        let (phone, mac, server, seal) = try await joined()
        defer { phone.stop(); mac.client.stop() }
        let request = try phone.sendTaskRecord("Owned publisher refusal", on: "mac", origin: origin())
        let raw = try await retained(request, on: mac)
        let observed = try TaskRecords.Observation(request: request, revision: 1, status: .waits, title: "Owned", progress: "Observed")
        let known = await phones(mac.client)
        var notRetained = raw
        notRetained.stamps["body"] = Stamp(wall: (raw.stamps["body"]?.wall ?? 0) + 1, device: request.phone)
        XCTAssertThrowsError(try TaskRecords.publish(observed, requestRecord: notRetained, client: mac.client, knownPhones: known))
        XCTAssertTrue(mac.journal.all(TaskRecords.observationCollection).isEmpty)
        let wrongJournal = try Journal(path: folder.appendingPathComponent("wrong-writer.sqlite").path, device: "wrong-clock")
        let wrongClient = SyncClient(base: URL(string: "https://sync.test")!, journal: wrongJournal, seal: seal,
                                     device: .init(id: "another-mac", name: "Owned other Mac", model: "Mac16,1"), transport: server)
        leases.append(OwnedJournalLease(wrongClient))
        wrongClient.start(); defer { wrongClient.stop() }
        let live = await until { wrongClient.state == .live }
        XCTAssertTrue(live)
        let other = try TaskRecords.Request(account: seal.account, phone: "phone", mac: "another-mac", space: space, words: "Owned writer mismatch")
        let otherRaw = Record(collection: TaskRecords.requestCollection, id: other.id, fields: try other.fields(),
                              stamps: ["body": Stamp(wall: 1, device: "phone")])
        _ = try wrongJournal.receive([(record: otherRaw, version: 1)])
        let otherObserved = try TaskRecords.Observation(request: other, revision: 1, status: .waits, title: "Owned", progress: "Writer mismatch")
        XCTAssertThrowsError(try TaskRecords.publish(otherObserved, requestRecord: otherRaw, client: wrongClient, knownPhones: known))
        XCTAssertTrue(wrongJournal.all(TaskRecords.observationCollection).isEmpty, "Validate the local writer before changing a record")
        server.revoke("phone")
        let revoked = await phones(mac.client)
        XCTAssertTrue(revoked.contains { $0.id == "phone" && $0.revoked })
        XCTAssertThrowsError(try TaskRecords.publish(observed, requestRecord: raw, client: mac.client, knownPhones: revoked))
        XCTAssertTrue(mac.journal.all(TaskRecords.observationCollection).isEmpty)
    }

    func testObservationBeforeRequestReconcilesOnlyAfterItsActualEncryptedRequestArrives() async throws {
        let (phone, mac, server, seal) = try await joined()
        defer { phone.stop(); mac.client.stop() }
        let heard = Heard()
        phone.onTaskRecords = { values in MainActor.assumeIsolated { heard.values += values } }
        let request = try TaskRecords.Request(account: seal.account, phone: "phone", mac: "mac", space: space,
                                              tab: tab, url: sourceURL, title: sourceTitle, words: "Owned late request")
        let early = Record(collection: TaskRecords.requestCollection, id: request.id, fields: try request.fields(),
                           stamps: ["body": Stamp(wall: 1, device: "phone")])
        // The Mac already holds this phone-owned request, but the receiving
        // PhoneSync snapshot has not caught up to that retained request yet.
        _ = try mac.journal.receive([(record: early, version: 0)])
        let observation = try TaskRecords.Observation(request: request, revision: 1, status: .waits,
                                                      title: "Owned observer", progress: "Retained observation arrived first")
        let known = await phones(mac.client)
        try TaskRecords.publish(observation, requestRecord: early, client: mac.client, knownPhones: known)
        let arrived = await until { phone.journal.record(.init(collection: TaskRecords.observationCollection, id: request.id)) != nil }
        XCTAssertTrue(arrived)
        XCTAssertNil(phone.journal.record(.init(collection: TaskRecords.requestCollection, id: request.id)))
        XCTAssertTrue(phone.taskRecords().isEmpty && heard.values.isEmpty)

        // A separate owned SyncClient represents the same phone restoring its
        // retained request. It uses the real sealed transport, not a local UI event.
        let outgoing = try Journal(path: folder.appendingPathComponent("late-request.sqlite").path, device: "phone")
        try outgoing.change(.init(collection: TaskRecords.requestCollection, id: request.id), request.fields())
        let sender = SyncClient(base: URL(string: "https://sync.test")!, journal: outgoing, seal: seal,
                                device: .init(id: "phone", name: "Owned task iPhone", model: "iPhone"), transport: server)
        leases.append(OwnedJournalLease(sender))
        sender.start(); defer { sender.stop() }
        let released = await until { heard.values == [observation] }
        XCTAssertTrue(released)
        XCTAssertEqual(phone.taskRecords(), [observation])
        XCTAssertTrue(phone.sends().isEmpty)
        phone.refreshMacs()
        let read = await until { phone.macs.contains { $0.id == "mac" } }
        XCTAssertTrue(read)
        XCTAssertEqual(heard.values, [observation])
    }

    func testCleanRelaunchReconcilesRetainedObservationOnceBeforePollingCanConsumeIt() async throws {
        let (phone, mac, server, seal) = try await joined()
        defer { mac.client.stop() }
        let request = try phone.sendTaskRecord("Owned restart observation", on: "mac", origin: origin())
        let raw = try await retained(request, on: mac)
        let observation = try TaskRecords.Observation(request: request, revision: 1, status: .waits,
                                                      title: "Owned observer", progress: "Persisted before relaunch")
        let known = await phones(mac.client)
        try TaskRecords.publish(observation, requestRecord: raw, client: mac.client, knownPhones: known)
        let saved = await until { phone.taskRecords() == [observation] }
        XCTAssertTrue(saved)
        phone.stop()
        let stopped = await until { phone.state == .off }
        XCTAssertTrue(stopped)
        let again = try self.phone(server, seal)
        defer { again.stop() }
        let heard = Heard()
        again.onTaskRecords = { values in MainActor.assumeIsolated { heard.values += values } }
        XCTAssertTrue(again.taskRecords().isEmpty, "The restored account still needs its known-Mac reconciliation")
        again.start()
        // Repeated real reads must not swallow its exactly-once retained notification.
        let notified = await until {
            _ = again.taskRecords()
            return heard.values == [observation]
        }
        XCTAssertTrue(notified)
        XCTAssertEqual(again.taskRecords(), [observation])
        again.onTaskRecords = { values in MainActor.assumeIsolated { heard.values += values } }
        let flush = expectation(description: "callbacks drained after unchanged reconciliation")
        DispatchQueue.main.async { flush.fulfill() }
        await fulfillment(of: [flush], timeout: 4)
        XCTAssertEqual(heard.values, [observation])
        XCTAssertEqual(again.journal.living(TaskRecords.requestCollection).count, 1)
    }

    func testNewTransportRevisionBetweenSnapshotAndPendingReleaseCannotLoseItsCallback() async throws {
        let (phone, mac, _, _) = try await joined()
        defer { phone.taskRecordSnapshotRead = nil; phone.stop(); mac.client.stop() }
        let request = try phone.sendTaskRecord("Owned snapshot race", on: "mac", origin: origin())
        let raw = try await retained(request, on: mac)
        let first = try TaskRecords.Observation(request: request, revision: 1, status: .waits, title: "Owned", progress: "First")
        let second = try TaskRecords.Observation(request: request, revision: 2, status: .waits, title: "Owned", progress: "Second")
        let known = await phones(mac.client)
        let arrived = DispatchSemaphore(value: 0)
        let deliver = phone.client.deliver
        phone.client.deliver = { values in
            deliver?(values)
            if values.contains(where: { item in
                (try? TaskRecords.Observation.read(item.record, request: request)) == second
            }) { arrived.signal() }
        }
        let gate = DeliveryGate(), heard = Heard()
        phone.taskRecordSnapshotRead = {
            guard gate.claim() else { return }
            do {
                try TaskRecords.publish(second, requestRecord: raw, client: mac.client, knownPhones: known)
                if arrived.wait(timeout: .now() + 4) != .success {
                    gate.fail("The actual second encrypted revision did not reach the receiving observer")
                }
            } catch { gate.fail(String(describing: error)) }
        }
        phone.onTaskRecords = { values in MainActor.assumeIsolated { heard.values += values } }
        try TaskRecords.publish(first, requestRecord: raw, client: mac.client, knownPhones: known)
        let both = await until { heard.values == [first, second] }
        XCTAssertTrue(both, "Both real revisions must notify; polling cannot repair a lost callback")
        XCTAssertNil(gate.error)
        XCTAssertEqual(phone.taskRecords(), [second])
        XCTAssertTrue(phone.sends().isEmpty)
        let drain = expectation(description: "unchanged follow-up reconciliation drained")
        DispatchQueue.main.async { drain.fulfill() }
        await fulfillment(of: [drain], timeout: 4)
        XCTAssertEqual(heard.values, [first, second])
    }

    private func ownRequest(words: String = "Owned request") throws -> TaskRecords.Request {
        try .init(account: "owned-account", phone: "phone", mac: "mac", space: space,
                  tab: tab, url: sourceURL, title: sourceTitle, words: words)
    }
}
