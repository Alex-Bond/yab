import Foundation
import SyncKit
import XCTest
@testable import YabPhone

/// Sealed transport/model guards only. Explicit unit-test Macs publish supplied
/// observations. These tests never invoke a provider, signer or website action.
@MainActor
final class LiveTaskFoundationTests: XCTestCase {
    private var folder: URL!
    private var engines: [PhoneSync] = []
    private var clients: [SyncClient] = []
    private var apps: [AppModel] = []
    private let space = "00000000-0000-0000-0000-000000000071"
    private let tab = "owned-read-source"
    private let address = "http://127.0.0.1:9137/owned?read=only#source"
    private let title = "Owned read source"
    private let epochA = "00000000-0000-0000-0000-000000000081"
    private let epochB = "00000000-0000-0000-0000-000000000082"

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("LiveTaskFoundation-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        apps.forEach { $0.sync.end() }
        engines.forEach { $0.stop() }; clients.forEach { $0.stop() }
        apps = []; engines = []; clients = []
        // Preserve owned SQLite files. Releasing Swift objects is not a proof
        // that every asynchronous SQLite close has reached the kernel.
        try? await Task.sleep(for: .milliseconds(30))
    }

    private func until(_ done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(4)
        while Date() < end {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return done()
    }

    private func expectEventually(_ done: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let passed = await until(done)
        XCTAssertTrue(passed, file: file, line: line)
    }

    private func capability(epoch: String? = nil) -> SyncFields {
        var fields: SyncFields = ["device": "mac", "open": 1, "taskRecords": 1]
        if let epoch { fields["taskReadOnly"] = 1; fields["taskReadOnlyEpoch"] = .string(epoch) }
        return fields
    }

    private func origin(privateMode: Bool = false) -> TaskRecords.Origin {
        .init(space: space, tab: tab, url: address, title: title, isPrivate: privateMode)
    }

    private func mac(_ server: SyncMemoryServer, _ seal: Seal, epoch: String?) async throws -> TestMac {
        let mac = try TestMac(server: server, seal: seal, id: "mac", agentSelection: false)
        clients.append(mac.client)
        try mac.write(OpenOnMac.capability, "mac", capability(epoch: epoch))
        try mac.write(SyncCollection.space, space, SyncSpace(id: space, name: "Owned public", icon: "").fields)
        try mac.write(SyncCollection.tab, tab, SyncTab(id: tab, space: space, url: address, title: title).fields)
        mac.front = (address, title, tab)
        mac.client.start()
        await expectEventually { mac.client.state == .live }
        return mac
    }

    private func joined(epoch: String? = nil) async throws -> (PhoneSync, TestMac, SyncMemoryServer, Seal) {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await mac(server, seal, epoch: epoch)
        let phone = try PhoneSync(seal: seal, options: .init(base: URL(string: "https://sync.test")!, folder: folder,
                                                          device: .init(id: "phone", name: "Owned read iPhone", model: "iPhone"),
                                                          transport: server, callbacks: .main, refreshEvery: 0.05))
        engines.append(phone); phone.start()
        await expectEventually { phone.state == .live && phone.canTransportTaskRecords(on: "mac")
            && phone.macs.first?.front != nil
            && phone.journal.record(.init(collection: SyncCollection.tab, id: self.tab)) != nil }
        return (phone, mac, server, seal)
    }

    private func knownPhones(_ client: SyncClient) async -> [SyncClient.Listed] {
        await withCheckedContinuation { done in client.devices { done.resume(returning: $0 ?? []) } }
    }

    func testLegacyRequestEncodingAndMissingOrForeignEpochCannotBecomeExecutionAuthority() throws {
        let request = try TaskRecords.Request(account: "account", phone: "phone", mac: "mac", space: space, words: "Read this")
        let encoded = try JSONEncoder().encode(request)
        XCTAssertNil((try JSONSerialization.jsonObject(with: encoded) as? [String: Any])?["readOnlyEpoch"])
        XCTAssertEqual(try JSONDecoder().decode(TaskRecords.Request.self, from: encoded), request)
        XCTAssertThrowsError(try TaskRecords.Request(account: "account", phone: "phone", mac: "mac", space: space,
                                                     words: "Read this", readOnlyEpoch: "not-an-epoch"))
        let owner = try Journal(path: nil, device: "mac")
        let transport = try owner.change(.init(collection: OpenOnMac.capability, id: "mac"), capability())
        XCTAssertTrue(TaskRecords.supports(transport, mac: "mac"))
        XCTAssertNil(TaskRecords.readOnlyEpoch(transport, mac: "mac"))
        let eligible = try owner.change(transport.key, capability(epoch: epochA))
        XCTAssertEqual(TaskRecords.readOnlyEpoch(eligible, mac: "mac"), epochA)
        let foreign = try Journal(path: nil, device: "foreign")
        _ = try foreign.receive([(record: eligible, version: 0)])
        let tampered = try foreign.change(eligible.key, ["taskReadOnlyEpoch": .string(epochB)])
        XCTAssertNil(TaskRecords.readOnlyEpoch(tampered, mac: "mac"))
    }

    func testTransportOnlyMacRefusesNewSendWithoutInventingTaskOrLegacyChat() async throws {
        let (phone, _, _, _) = try await joined()
        XCTAssertNil(phone.readOnlyTaskEpoch(on: "mac"))
        XCTAssertThrowsError(try phone.sendReadOnlyTaskRecord("Read this", on: "mac", origin: origin(), epoch: epochA))
        XCTAssertTrue(phone.taskRequests().isEmpty)
        XCTAssertTrue(phone.taskRecords().isEmpty)
        XCTAssertTrue(phone.sends().isEmpty)
        XCTAssertTrue(phone.journal.living(TaskRecords.requestCollection).isEmpty)
    }

    func testCapturedEpochAndPublicSourceCommitExactRequestWithoutOptimisticObservation() async throws {
        let (phone, mac, _, seal) = try await joined(epoch: epochA)
        XCTAssertEqual(phone.readOnlyTaskEpoch(on: "mac"), epochA)
        let request = try phone.sendReadOnlyTaskRecord("Read the visible heading", on: "mac", origin: origin(), epoch: epochA)
        await expectEventually { mac.journal.record(.init(collection: TaskRecords.requestCollection, id: request.id)) != nil }
        let raw = try XCTUnwrap(mac.journal.record(.init(collection: TaskRecords.requestCollection, id: request.id)))
        XCTAssertEqual(try TaskRecords.Request.read(raw, account: seal.account, phone: "phone", mac: "mac"), request)
        XCTAssertEqual(request.readOnlyEpoch, epochA)
        XCTAssertEqual(request.url, address); XCTAssertEqual(request.title, title)
        XCTAssertEqual(phone.taskRequests(), [request])
        let snapshot = try LiveTaskSnapshot(request: request, observation: nil)
        XCTAssertEqual(snapshot.state, .pending)
        XCTAssertEqual(snapshot.progress, "Queued for your Mac", "Durable local commit is not proof of Mac delivery")
        XCTAssertNil(snapshot.result); XCTAssertNil(snapshot.resultURL)
        XCTAssertTrue(phone.taskRecords().isEmpty)
        XCTAssertTrue(mac.journal.living(SyncCollection.send).isEmpty)
    }

    func testReplacedEpochPrivateSourceAndStaleDocumentRefuseBeforeNewCommit() async throws {
        let (phone, mac, _, _) = try await joined(epoch: epochA)
        try mac.write(OpenOnMac.capability, "mac", capability(epoch: epochB))
        await expectEventually { phone.readOnlyTaskEpoch(on: "mac") == self.epochB }
        XCTAssertThrowsError(try phone.sendReadOnlyTaskRecord("Read", on: "mac", origin: origin(), epoch: epochA))
        XCTAssertThrowsError(try phone.sendReadOnlyTaskRecord("Read", on: "mac", origin: origin(privateMode: true), epoch: epochB))
        let stale = TaskRecords.Origin(space: space, tab: tab, url: address + "-replaced", title: title, isPrivate: false)
        XCTAssertThrowsError(try phone.sendReadOnlyTaskRecord("Read", on: "mac", origin: stale, epoch: epochB))
        XCTAssertTrue(phone.taskRequests().isEmpty); XCTAssertTrue(phone.sends().isEmpty)
    }

    func testActualSleepAndRosterRevocationWithdrawSendAuthorityWithCapabilityStillRetained() async throws {
        let (phone, mac, server, _) = try await joined(epoch: epochA)
        mac.asleep = true; mac.client.sayPresence()
        await expectEventually { phone.macs.first?.front?.asleep == true }
        XCTAssertNil(phone.readOnlyTaskEpoch(on: "mac"))
        XCTAssertTrue(TaskRecords.supports(phone.journal.record(.init(collection: OpenOnMac.capability, id: "mac")), mac: "mac"))
        XCTAssertThrowsError(try phone.sendReadOnlyTaskRecord("Read", on: "mac", origin: origin(), epoch: epochA))
        server.revoke("mac")
        await expectEventually { !phone.macs.contains { $0.id == "mac" } }
        XCTAssertNil(phone.readOnlyTaskEpoch(on: "mac")); XCTAssertTrue(phone.taskRequests().isEmpty)
    }

    func testMissingStaleAndFutureActualPresenceCannotAuthorizeSend() async throws {
        let (phone, mac, _, _) = try await joined(epoch: epochA)
        for at in [0.0, Date().timeIntervalSince1970 - PhoneSync.onlineFor - 1, Date().timeIntervalSince1970 + 60] {
            mac.client.presence = { Record(collection: "presence", id: "mac", fields: ["name": "Owned Mac", "at": .number(at)]) }
            mac.client.sayPresence()
            await expectEventually { phone.macs.first?.front?.at == at }
            XCTAssertNil(phone.readOnlyTaskEpoch(on: "mac"))
            XCTAssertThrowsError(try phone.sendReadOnlyTaskRecord("Read", on: "mac", origin: origin(), epoch: epochA))
        }
        XCTAssertTrue(phone.taskRequests().isEmpty); XCTAssertTrue(phone.sends().isEmpty)
    }

    func testOnlyCheckedMatchingMacObservationSuppliesResultAndTombstoneWithdrawsIt() async throws {
        let (phone, mac, _, _) = try await joined(epoch: epochA)
        let request = try phone.sendReadOnlyTaskRecord("Read", on: "mac", origin: origin(), epoch: epochA)
        await expectEventually { mac.journal.record(.init(collection: TaskRecords.requestCollection, id: request.id)) != nil }
        let raw = try XCTUnwrap(mac.journal.record(.init(collection: TaskRecords.requestCollection, id: request.id)))
        let known = await knownPhones(mac.client)
        let observed = try TaskRecords.Observation(request: request, revision: 1, session: "owned-unit-session", status: .done,
                                                   title: "Actual supplied unit observation", progress: "Read complete", result: "Owned heading")
        _ = try TaskRecords.publish(observed, requestRecord: raw, client: mac.client, knownPhones: known)
        await expectEventually { phone.taskRecords() == [observed] }
        let snapshot = try LiveTaskSnapshot(request: request, observation: observed)
        XCTAssertEqual(snapshot.state, .observed(.done)); XCTAssertEqual(snapshot.result, "Owned heading")
        let labels: [(TaskRecords.Status, String)] = [(.running, "Working on your Mac"), (.needsYou, "Needs your attention"),
            (.waits, "Waiting on your Mac"), (.failed, "Failed"), (.done, "Completed"), (.stopped, "Stopped")]
        for (status, label) in labels {
            let empty = try TaskRecords.Observation(request: request, revision: 1, session: "owned-unit-session", status: status,
                                                    title: "Owned observation", progress: "", result: status == .done ? "Owned result" : nil)
            XCTAssertEqual(try LiveTaskSnapshot(request: request, observation: empty).progress, label)
        }
        let another = try TaskRecords.Request(account: request.account, phone: request.phone, mac: request.mac,
                                              space: request.space, words: "Other", readOnlyEpoch: epochA)
        XCTAssertThrowsError(try LiveTaskSnapshot(request: another, observation: observed))
        try phone.journal.remove(.init(collection: TaskRecords.requestCollection, id: request.id))
        XCTAssertTrue(phone.taskRequests().isEmpty); XCTAssertTrue(phone.taskRecords().isEmpty)
        XCTAssertTrue(phone.sends().isEmpty)
    }

    private func joinedApp() async throws -> (AppModel, TestMac) {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await mac(server, seal, epoch: epochA)
        let keys = folder.appendingPathComponent("keys")
        try FileManager.default.createDirectory(at: keys, withIntermediateDirectories: true)
        try seal.raw.write(to: keys.appendingPathComponent("key-shared"))
        let world = World(name: "owned-read", space: "home", spaces: [Space(id: "home", name: "Home", emoji: "", tint: RGB(238, 233, 226))])
        let app = AppModel(world: world, fixturesEnabled: false, privateLockEnabled: { false })
        apps.append(app)
        app.sync.attach(app, setup: .init(base: URL(string: "https://sync.test")!, keys: .testing(folder: keys),
                                         folder: folder.appendingPathComponent("app-journal"), seed: false, makesKey: false,
                                         deviceName: "Owned read iPhone", transport: server, refreshEvery: 0.05, ownWorld: true))
        await expectEventually { app.sync.phase == .on && app.sync.ready && app.sync.line == .live
            && app.browser.allTabs.contains { $0.url == self.address }
            && app.sync.engine?.readOnlyTaskEpoch(on: "mac") == self.epochA }
        let source = try XCTUnwrap(app.browser.allTabs.first { $0.url == address })
        app.browser.select(source.id)
        XCTAssertEqual(app.sync.currentTaskOrigin()?.url, address)
        return (app, mac)
    }

    func testRetainedBackendCannotSendAfterActualDisplayedSourceChanges() async throws {
        let (app, _) = try await joinedApp()
        let backend = try XCTUnwrap(SyncTaskBackend.capture(in: app, mac: "mac"))
        var source = try XCTUnwrap(app.browser.tab)
        source.url = address + "-different"
        app.browser.replace(source.id, with: source)
        XCTAssertThrowsError(try backend.send("Read captured page"))
        XCTAssertTrue(app.sync.engine?.taskRequests().isEmpty == true)
        XCTAssertTrue(app.tasks.runs.isEmpty, "No fixture workflow is fabricated")
    }

    func testRetainedBackendCannotSendOrExposeSnapshotsAfterEngineIsStopped() async throws {
        let (app, _) = try await joinedApp()
        let backend = try XCTUnwrap(SyncTaskBackend.capture(in: app, mac: "mac"))
        let request = try backend.send("Read actual public source")
        XCTAssertEqual(backend.snapshots().map(\.id), [request.id])
        XCTAssertTrue(app.tasks.runs.isEmpty)
        app.sync.end()
        XCTAssertThrowsError(try backend.send("Read again"))
        XCTAssertTrue(backend.snapshots().isEmpty)
    }
}
