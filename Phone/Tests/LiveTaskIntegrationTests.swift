import Foundation
import SwiftUI
import UIKit
import SyncKit
import XCTest
@testable import YabPhone

/// Sealed transport/model guards only. Explicit unit-test Macs publish supplied
/// observations. These tests never invoke a provider, signer or website action.
@MainActor
final class LiveTaskIntegrationTests: XCTestCase {
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
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("LiveTaskIntegration-\(UUID())")
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
        // Today belongs to its device. Keep this shared source on both devices.
        try mac.write(SyncCollection.tab, tab, SyncTab(id: tab, space: space, url: address, title: title, kept: true).fields)
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

    private func joinedApp() async throws -> (AppModel, TestMac, SyncMemoryServer) {
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
        return (app, mac, server)
    }


    private func publish(_ status: TaskRecords.Status, request: TaskRecords.Request, mac: TestMac,
                         revision: UInt64 = 1, progress: String = "Actual Mac progress", result: String? = nil,
                         observedTitle: String = "Actual observed title") async throws {
        await expectEventually { mac.journal.record(.init(collection: TaskRecords.requestCollection, id: request.id)) != nil }
        let raw = try XCTUnwrap(mac.journal.record(.init(collection: TaskRecords.requestCollection, id: request.id)))
        let known = await knownPhones(mac.client)
        let value = try TaskRecords.Observation(request: request, revision: revision, session: "owned-integration-session",
                                                status: status, title: observedTitle, progress: progress, result: result)
        _ = try TaskRecords.publish(value, requestRecord: raw, client: mac.client, knownPhones: known)
    }

    func testProductionWordsQueueOnlyExactAuthoredRequestAndNoFixtureWorkflow() async throws {
        let (app, _, _) = try await joinedApp()
        XCTAssertTrue(app.taskDesk.canRun)
        let words = "Read the current public heading without changing the website"
        let id = try XCTUnwrap(app.taskDesk.send(words: words))
        let engine = try XCTUnwrap(app.sync.engine)
        let request = try XCTUnwrap(engine.taskRequests().first)
        XCTAssertEqual(request.id, id); XCTAssertEqual(request.words, words)
        XCTAssertEqual(request.url, address); XCTAssertEqual(request.readOnlyEpoch, epochA)
        XCTAssertEqual(app.tasks.live.map(\.id), [id])
        XCTAssertTrue(app.tasks.runs.isEmpty); XCTAssertTrue(app.tasks.definitions.isEmpty)
        XCTAssertTrue(engine.sends().isEmpty); XCTAssertTrue(engine.taskRecords().isEmpty)
        XCTAssertEqual(app.nowItem?.subtitle, "Queued for your Mac")
        XCTAssertEqual(app.nowItem?.short, "Queued"); XCTAssertNil(app.nowItem?.action)
        let rows = app.sync.visibleLiveTasks(in: app.browser.spaceID)
        XCTAssertEqual(rows.map(\.id), [id]); XCTAssertEqual(rows.first?.progress, "Queued for your Mac")
        app.taskDesk.send("lumen", words: "Do not invent a known demo")
        XCTAssertEqual(engine.taskRequests().count, 1); XCTAssertTrue(app.tasks.runs.isEmpty)
    }

    func testActualMacObservationUpdatesNowAndDoneOpenedIsOnlyLocallySeen() async throws {
        let (app, mac, _) = try await joinedApp()
        let id = try XCTUnwrap(app.taskDesk.send(words: "Read"))
        let request = try XCTUnwrap(app.sync.engine?.taskRequests().first)
        try await publish(.running, request: request, mac: mac, progress: "Read actual heading")
        await expectEventually { app.nowItem?.subtitle == "Read actual heading" }
        XCTAssertEqual(app.nowItem?.title, "Actual observed title"); XCTAssertNil(app.nowItem?.action)
        XCTAssertNil(app.sync.visibleLiveTask(id)?.result)
        try await publish(.done, request: request, mac: mac, revision: 2, progress: "Read finished", result: "Actual saved heading")
        await expectEventually { app.nowItem?.kind == .done && app.sync.visibleLiveTask(id)?.result == "Actual saved heading" }
        XCTAssertEqual(app.nowItem?.subtitle, "Read finished")
        app.taskDesk.openChat(id, from: .other(nil))
        XCTAssertEqual(app.surfaces.chat, .task(id)); XCTAssertNil(app.nowItem?.taskID)
        XCTAssertEqual(app.sync.visibleLiveTask(id)?.result, "Actual saved heading")
        XCTAssertEqual(app.sync.engine?.taskRequests(), [request]); XCTAssertTrue(app.tasks.runs.isEmpty)
    }

    func testActualRequestTombstoneWithdrawsCachedNowColumnAndOpenChat() async throws {
        let (app, _, server) = try await joinedApp()
        let id = try XCTUnwrap(app.taskDesk.send(words: "Read"))
        let engine = try XCTUnwrap(app.sync.engine)
        app.taskDesk.openChat(id, from: .other(nil))
        XCTAssertEqual(app.surfaces.chat, .task(id))
        // A second owned client of this same phone sends its actual authored
        // tombstone through the sealed protocol; no UI callback is synthesized.
        let outgoing = try Journal(path: folder.appendingPathComponent("restored-phone.sqlite").path,
                                   device: engine.options.device.id)
        let sender = SyncClient(base: URL(string: "https://sync.test")!, journal: outgoing, seal: engine.seal,
                                device: engine.options.device, transport: server)
        clients.append(sender); sender.start()
        await expectEventually { sender.state == .live
            && outgoing.record(.init(collection: TaskRecords.requestCollection, id: id)) != nil }
        try outgoing.remove(.init(collection: TaskRecords.requestCollection, id: id))
        sender.kick()
        await expectEventually { app.tasks.live.isEmpty && app.surfaces.chat == nil }
        XCTAssertFalse(try XCTUnwrap(engine.journal.record(.init(collection: TaskRecords.requestCollection, id: id))).alive())
        XCTAssertNil(app.sync.visibleLiveTask(id)); XCTAssertNil(app.nowItem?.taskID)
        XCTAssertTrue(app.sync.visibleLiveTasks(in: app.browser.spaceID).isEmpty)
        XCTAssertEqual(app.surfaces.recede, 0); XCTAssertTrue(app.tasks.runs.isEmpty)
    }

    func testActualMacObservationTombstoneWithdrawsRetainedResultWithoutForgingAnObservation() async throws {
        let (app, mac, _) = try await joinedApp()
        let id = try XCTUnwrap(app.taskDesk.send(words: "Read"))
        let engine = try XCTUnwrap(app.sync.engine)
        let request = try XCTUnwrap(engine.taskRequests().first)
        try await publish(.done, request: request, mac: mac, progress: "Read complete", result: "Actual heading")
        await expectEventually { app.sync.visibleLiveTask(id)?.result == "Actual heading" }
        app.taskDesk.openChat(id, from: .other(nil))
        XCTAssertEqual(app.surfaces.chat, .task(id))
        try mac.journal.remove(.init(collection: TaskRecords.observationCollection, id: id))
        mac.client.kick()
        await expectEventually { engine.taskRecords().isEmpty
            && app.tasks.live.first?.observation == nil && app.sync.visibleLiveTask(id)?.result == nil }
        XCTAssertEqual(app.sync.visibleLiveTask(id)?.progress, "Queued for your Mac")
        XCTAssertEqual(engine.taskRequests(), [request]); XCTAssertEqual(app.surfaces.chat, .task(id))
        XCTAssertTrue(app.tasks.runs.isEmpty); XCTAssertTrue(engine.sends().isEmpty)
    }

    func testPrivateForegroundHidesPublicTasksAndCannotEmitOrReopenThem() async throws {
        let (app, _, _) = try await joinedApp()
        let id = try XCTUnwrap(app.taskDesk.send(words: "Read public source"))
        let publicSpace = app.browser.spaceID
        app.taskDesk.openChat(id, from: .other(nil))
        let secret = Space(id: "owned-private", name: "Private", emoji: "", tint: RGB(40, 40, 40),
                           today: [Tab(id: "owned-private-tab", title: "Owned secret", site: "Secret", icon: "globe", page: "blank", isPrivate: true)],
                           isPrivate: true)
        app.browser.adopt(app.browser.spaces + [secret]); app.browser.showSpace(secret.id)
        XCTAssertTrue(app.hasPrivateForeground)
        XCTAssertFalse(app.taskDesk.canRun); XCTAssertNil(app.taskDesk.send(words: "Private words"))
        XCTAssertNil(app.sync.visibleLiveTask(id)); XCTAssertNil(app.nowItem?.taskID)
        XCTAssertTrue(app.sync.visibleLiveTasks(in: publicSpace).isEmpty)
        await expectEventually { app.surfaces.chat == nil }
        app.taskDesk.openChat(id, from: .other(nil)); XCTAssertNil(app.surfaces.chat)
        XCTAssertEqual(app.sync.engine?.taskRequests().count, 1)
    }

    func testMultipleEligibleMacsRequireExplicitOwnerAndRevokedSelectionNeverFallsBack() async throws {
        let (app, _, server) = try await joinedApp()
        let engine = try XCTUnwrap(app.sync.engine)
        let second = try TestMac(server: server, seal: engine.seal, id: "mac-b", agentSelection: false)
        clients.append(second.client)
        try second.write(OpenOnMac.capability, "mac-b", ["device": "mac-b", "taskRecords": 1,
                        "taskReadOnly": 1, "taskReadOnlyEpoch": .string(epochB)])
        second.front = (address, title, tab); second.client.start()
        await expectEventually { engine.readOnlyTaskEpoch(on: "mac-b") == self.epochB }
        XCTAssertFalse(app.taskDesk.canRun); XCTAssertNil(app.taskDesk.send(words: "Ambiguous"))
        XCTAssertTrue(engine.taskRequests().isEmpty)
        app.taskDesk.selectedLiveMac = "mac-b"
        XCTAssertTrue(app.taskDesk.canRun)
        let id = try XCTUnwrap(app.taskDesk.send(words: "Selected owner"))
        XCTAssertEqual(engine.taskRequests().first?.mac, "mac-b")
        server.revoke("mac-b")
        await expectEventually { !engine.macs.contains { $0.id == "mac-b" } && app.tasks.live.isEmpty }
        XCTAssertFalse(app.taskDesk.canRun); XCTAssertNil(app.taskDesk.send(words: "Do not choose mac-a"))
        XCTAssertNil(app.sync.visibleLiveTask(id)); XCTAssertTrue(engine.taskRequests().isEmpty)
        XCTAssertTrue(engine.sends().isEmpty)
    }

    func testStoppedEngineAndQueuedOldCallbackCannotRestoreTaskModelOrChat() async throws {
        let (app, _, _) = try await joinedApp()
        let engine = try XCTUnwrap(app.sync.engine)
        let callback = try XCTUnwrap(engine.onTaskRecordChanges)
        let id = try XCTUnwrap(app.taskDesk.send(words: "Read"))
        app.taskDesk.openChat(id, from: .other(nil)); XCTAssertEqual(app.surfaces.chat, .task(id))
        app.sync.end()
        XCTAssertTrue(app.tasks.live.isEmpty); XCTAssertNil(app.tasks.liveAccount)
        XCTAssertNil(app.nowItem?.taskID); XCTAssertNil(app.surfaces.chat)
        callback()
        XCTAssertTrue(app.tasks.live.isEmpty); XCTAssertNil(app.surfaces.chat)
        XCTAssertFalse(app.taskDesk.canRun); XCTAssertNil(app.taskDesk.send(words: "After stop"))
        XCTAssertEqual(engine.journal.living(TaskRecords.requestCollection).count, 1)
    }

    func testActualNeedsYouAndFailedObservationsNeverCreateFixtureApprovalRetryOrResult() async throws {
        let (app, mac, _) = try await joinedApp()
        let id = try XCTUnwrap(app.taskDesk.send(words: "Read"))
        let request = try XCTUnwrap(app.sync.engine?.taskRequests().first)
        try await publish(.needsYou, request: request, mac: mac, progress: "Actual Mac asks for attention")
        await expectEventually { app.nowItem?.kind == .warn && app.nowItem?.subtitle == "Actual Mac asks for attention" }
        XCTAssertNil(app.nowItem?.action); XCTAssertTrue(app.taskDesk.codes.isEmpty); XCTAssertTrue(app.taskDesk.yeses.isEmpty)
        app.taskDesk.tapNow(try XCTUnwrap(app.nowItem), action: "Review", from: .zero)
        XCTAssertNil(app.taskDesk.sheet); XCTAssertEqual(app.surfaces.chat, .task(id))
        try await publish(.failed, request: request, mac: mac, revision: 2, progress: "Actual failure")
        await expectEventually { app.nowItem?.subtitle == "Actual failure" }
        XCTAssertNil(app.nowItem?.action); XCTAssertNil(app.sync.visibleLiveTask(id)?.result)
        XCTAssertTrue(app.tasks.runs.isEmpty); XCTAssertTrue(app.sync.engine?.sends().isEmpty == true)
    }

    // MARK: - checked presentation, local read receipts, and bounded read work

    private func restoredApp(server: SyncMemoryServer) async throws -> AppModel {
        let world = World(name: "owned-read", space: "home", spaces: [Space(id: "home", name: "Home", emoji: "", tint: RGB(238, 233, 226))])
        let app = AppModel(world: world, fixturesEnabled: false, privateLockEnabled: { false })
        apps.append(app)
        app.sync.attach(app, setup: .init(base: URL(string: "https://sync.test")!,
                                         keys: .testing(folder: folder.appendingPathComponent("keys")),
                                         folder: folder.appendingPathComponent("app-journal"), seed: false, makesKey: false,
                                         deviceName: "Owned read iPhone", transport: server, refreshEvery: 0.05, ownWorld: true))
        await expectEventually { app.sync.phase == .on && app.sync.ready && app.sync.line == .live
            && app.browser.allTabs.contains { $0.url == self.address }
            && app.sync.engine?.readOnlyTaskEpoch(on: "mac") == self.epochA }
        app.browser.select(try XCTUnwrap(app.browser.allTabs.first { $0.url == address }).id)
        return app
    }

    func testCheckedDoneSeenSurvivesRealSameAccountEngineRelaunchAndNewResultIsUnread() async throws {
        let (app, mac, server) = try await joinedApp()
        let id = try XCTUnwrap(app.taskDesk.send(words: "Read retained source"))
        let request = try XCTUnwrap(app.sync.engine?.taskRequests().first)
        try await publish(.done, request: request, mac: mac, result: "# Actual retained heading")
        await expectEventually { app.sync.visibleLiveTask(id)?.result != nil }
        app.taskDesk.openChat(id, from: .other(nil))
        XCTAssertNil(app.nowItem?.taskID)
        XCTAssertFalse(app.tasks.liveSeenPersistenceFailed)
        app.surfaces.closeChat(); app.taskDesk.dismissForLink(); app.sync.end()
        let relaunched = try await restoredApp(server: server)
        await expectEventually { relaunched.sync.visibleLiveTask(id)?.result == "# Actual retained heading" }
        XCTAssertEqual(relaunched.sync.engine?.seal.account, request.account)
        XCTAssertEqual(relaunched.sync.engine?.options.device.id, request.phone)
        XCTAssertNil(relaunched.nowItem?.taskID)
        XCTAssertFalse(relaunched.tasks.liveSeenPersistenceFailed)
        try await publish(.done, request: request, mac: mac, revision: 2, result: "# Actual changed heading")
        await expectEventually { relaunched.nowItem?.taskID == id }
        XCTAssertEqual(relaunched.sync.visibleLiveTask(id)?.result, "# Actual changed heading")
        XCTAssertTrue(relaunched.tasks.runs.isEmpty)
    }

    func testCompletedNowNoticeDismissesLocallyAndNewResultReturns() async throws {
        let (app, mac, _) = try await joinedApp()
        let id = try XCTUnwrap(app.taskDesk.send(words: "Read completed notice"))
        let request = try XCTUnwrap(app.sync.engine?.taskRequests().first)
        try await publish(.done, request: request, mac: mac, result: "Saved result")
        await expectEventually { app.nowItem?.kind == .done }
        let dismiss = try XCTUnwrap(app.nowDismissal(for: try XCTUnwrap(app.nowItem)))
        XCTAssertTrue(dismiss())
        XCTAssertNil(app.nowItem?.taskID)
        XCTAssertEqual(app.sync.visibleLiveTask(id)?.result, "Saved result")
        XCTAssertEqual(app.sync.engine?.taskRequests(), [request])
        XCTAssertTrue(app.sync.engine?.sends().isEmpty == true)
        app.sync.reconcileLiveTasks()
        XCTAssertNil(app.nowItem?.taskID)
        try await publish(.done, request: request, mac: mac, revision: 2, result: "New result")
        await expectEventually { app.nowItem?.taskID == id }
        XCTAssertFalse(dismiss())
        XCTAssertEqual(app.nowItem?.taskID, id, "a retired swipe must not hide a newer result")
    }

    func testFailedNowNoticeStaysDismissedAfterRelaunchAndNewFailureReturns() async throws {
        let (app, mac, server) = try await joinedApp()
        let id = try XCTUnwrap(app.taskDesk.send(words: "Read failed notice"))
        let request = try XCTUnwrap(app.sync.engine?.taskRequests().first)
        try await publish(.failed, request: request, mac: mac, progress: "Owned chat error")
        await expectEventually { app.nowItem?.kind == .warn }
        let snapshot = try XCTUnwrap(app.sync.visibleLiveTask(id))
        XCTAssertTrue(try XCTUnwrap(app.nowDismissal(for: try XCTUnwrap(app.nowItem)))())
        XCTAssertNil(app.nowItem?.taskID)
        XCTAssertEqual(app.sync.visibleLiveTask(id), snapshot)
        XCTAssertEqual(app.sync.engine?.taskRequests(), [request])
        XCTAssertTrue(app.sync.engine?.sends().isEmpty == true)
        app.sync.end()
        let restored = try await restoredApp(server: server)
        await expectEventually { restored.sync.visibleLiveTask(id) == snapshot }
        XCTAssertNil(restored.nowItem?.taskID)
        try await publish(.failed, request: request, mac: mac, revision: 2, progress: "Another chat error")
        await expectEventually { restored.nowItem?.taskID == id }
    }

    func testActiveTaskNoticesCannotBeDismissedAndOldSwipeCannotHideThem() async throws {
        let (app, mac, _) = try await joinedApp()
        _ = try XCTUnwrap(app.taskDesk.send(words: "Read active notice"))
        let request = try XCTUnwrap(app.sync.engine?.taskRequests().first)
        XCTAssertNil(app.nowDismissal(for: try XCTUnwrap(app.nowItem)))
        try await publish(.failed, request: request, mac: mac)
        await expectEventually { app.nowItem?.kind == .warn }
        let dismiss = try XCTUnwrap(app.nowDismissal(for: try XCTUnwrap(app.nowItem)))
        for (n, status) in [TaskRecords.Status.running, .needsYou, .waits].enumerated() {
            try await publish(status, request: request, mac: mac, revision: UInt64(n + 2))
            await expectEventually { app.sync.visibleLiveTask(request.id)?.observation?.status == status }
            XCTAssertNil(app.nowDismissal(for: try XCTUnwrap(app.nowItem)))
            XCTAssertFalse(dismiss())
            XCTAssertEqual(app.nowItem?.taskID, request.id)
        }
    }

    func testOfflineMacWordingDoesNotPreventTerminalNoticeDismissal() throws {
        let request = try TaskRecords.Request(account: "owned-account", phone: "owned-phone", mac: "owned-mac",
                                              space: space, words: "Read offline result", readOnlyEpoch: epochA)
        for status in [TaskRecords.Status.done, .failed] {
            let observation = try TaskRecords.Observation(request: request, revision: 1, session: "owned-notice-session", status: status,
                                                          title: "Owned notice", progress: "Finished",
                                                          result: status == .done ? "Owned offline result" : nil)
            let rendered = try LiveTaskSnapshot(request: request, observation: observation)
            var cached = rendered
            cached.macWait = "Waits for Owned Mac · asleep"
            let tasks = TaskStore(world: World(name: "offline", space: "home", spaces: []))
            tasks.replaceLive(account: request.account, snapshots: [cached],
                              seenScope: .init(folder: folder.appendingPathComponent(status.rawValue),
                                               account: request.account, phone: request.phone))
            XCTAssertTrue(tasks.markLiveSeen(rendered))
            XCTAssertNil(tasks.liveNow(in: [rendered]))
            cached.macWait = "Waits for Owned Mac · no word"
            tasks.replaceLive(account: request.account, snapshots: [cached],
                              seenScope: .init(folder: folder.appendingPathComponent(status.rawValue),
                                               account: request.account, phone: request.phone))
            XCTAssertNil(tasks.liveNow(in: [rendered]))
        }
    }

    func testLocalSeenScopeCannotCrossAccountPhoneOrHideDoneAfterWriteFailure() async throws {
        let (app, mac, _) = try await joinedApp()
        let id = try XCTUnwrap(app.taskDesk.send(words: "Read scoped source"))
        let engine = try XCTUnwrap(app.sync.engine)
        let request = try XCTUnwrap(engine.taskRequests().first)
        try await publish(.done, request: request, mac: mac, result: "Actual scope result")
        await expectEventually { app.sync.visibleLiveTask(id)?.result != nil }
        let snapshot = try XCTUnwrap(app.sync.visibleLiveTask(id))
        let scope = LiveTaskSeenStore.Scope(folder: folder.appendingPathComponent("local-seen"), account: request.account, phone: request.phone)
        let first = LiveTaskSeenStore(scope: scope)
        XCTAssertTrue(first.mark(snapshot)); XCTAssertTrue(first.contains(snapshot))
        XCTAssertTrue(LiveTaskSeenStore(scope: scope).contains(snapshot))
        let otherAccount = LiveTaskSeenStore(scope: .init(folder: scope.folder, account: "other-account", phone: request.phone))
        let otherPhone = LiveTaskSeenStore(scope: .init(folder: scope.folder, account: request.account, phone: "other-phone"))
        XCTAssertFalse(otherAccount.contains(snapshot)); XCTAssertFalse(otherAccount.mark(snapshot))
        XCTAssertFalse(otherPhone.contains(snapshot)); XCTAssertFalse(otherPhone.mark(snapshot))
        let notDirectory = folder.appendingPathComponent("not-a-seen-directory")
        try Data("owned sentinel".utf8).write(to: notDirectory)
        let tasks = TaskStore(world: World(name: "seen", space: "home", spaces: []))
        tasks.replaceLive(account: request.account, snapshots: [snapshot],
                          seenScope: .init(folder: notDirectory, account: request.account, phone: request.phone))
        XCTAssertFalse(tasks.markLiveSeen(snapshot))
        XCTAssertTrue(tasks.liveSeenPersistenceFailed)
        XCTAssertEqual(tasks.liveNow(in: [snapshot])?.taskID, id)
        XCTAssertEqual(try Data(contentsOf: notDirectory), Data("owned sentinel".utf8))
        XCTAssertEqual(engine.taskRequests(), [request]); XCTAssertTrue(engine.sends().isEmpty)
    }

    func testCorruptSeenReceiptFailsClosedWithoutOverwritingOrClaimingRead() async throws {
        let (app, mac, _) = try await joinedApp()
        let id = try XCTUnwrap(app.taskDesk.send(words: "Read"))
        let request = try XCTUnwrap(app.sync.engine?.taskRequests().first)
        try await publish(.done, request: request, mac: mac, result: "Actual result")
        await expectEventually { app.sync.visibleLiveTask(id)?.result != nil }
        let snapshot = try XCTUnwrap(app.sync.visibleLiveTask(id))
        let scope = LiveTaskSeenStore.Scope(folder: folder.appendingPathComponent("owned-corrupt-seen"), account: request.account, phone: request.phone)
        XCTAssertTrue(LiveTaskSeenStore(scope: scope).mark(snapshot))
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: scope.folder, includingPropertiesForKeys: nil).first)
        try Data("invalid owned JSON".utf8).write(to: file)
        let corrupt = LiveTaskSeenStore(scope: scope)
        XCTAssertFalse(corrupt.readable); XCTAssertFalse(corrupt.contains(snapshot)); XCTAssertFalse(corrupt.mark(snapshot))
        XCTAssertEqual(try Data(contentsOf: file), Data("invalid owned JSON".utf8))
        XCTAssertEqual(app.sync.visibleLiveTask(id), snapshot)
    }

    func testTaskMarkdownLinkAuthorityRefusesOldPresentationAndChangedResultBeforeLocalNavigation() async throws {
        let (app, mac, _) = try await joinedApp()
        let id = try XCTUnwrap(app.taskDesk.send(words: "Read linked heading"))
        let request = try XCTUnwrap(app.sync.engine?.taskRequests().first)
        try await publish(.done, request: request, mac: mac, result: "# Actual result\n\n- **Checked** [heading](https://example.test/read)\n\n```swift\nlet x = 1\n```")
        await expectEventually { app.sync.visibleLiveTask(id)?.result != nil }
        app.taskDesk.openChat(id, from: .other(nil))
        let first = LiveTaskChatAuthority(app: app, snapshot: try XCTUnwrap(app.sync.visibleLiveTask(id)))
        XCTAssertTrue(first.current)
        let count = app.browser.allTabs.count
        _ = first.open(URL(string: "file:///owned/file")!)
        _ = first.open(URL(string: "https://name:secret@example.test/read")!)
        XCTAssertEqual(app.browser.allTabs.count, count)
        app.surfaces.openMenu(.plate); app.surfaces.closeMenu()
        XCTAssertFalse(first.current) // a synchronous surface ABA cannot revive this callback
        first.close(); XCTAssertEqual(app.surfaces.chat, .task(id))
        app.surfaces.closeChat(); app.taskDesk.dismissForLink()
        app.taskDesk.openChat(id, from: .other(nil))
        XCTAssertFalse(first.current); first.close()
        XCTAssertEqual(app.surfaces.chat, .task(id))
        let beforeChange = LiveTaskChatAuthority(app: app, snapshot: try XCTUnwrap(app.sync.visibleLiveTask(id)))
        try await publish(.done, request: request, mac: mac, revision: 2, result: "Actual newer result")
        await expectEventually { app.sync.visibleLiveTask(id)?.result == "Actual newer result" }
        XCTAssertFalse(beforeChange.current)
        _ = beforeChange.open(URL(string: "https://example.test/old")!)
        XCTAssertEqual(app.browser.allTabs.count, count)
        XCTAssertEqual(app.surfaces.chat, .task(id))
        let current = LiveTaskChatAuthority(app: app, snapshot: try XCTUnwrap(app.sync.visibleLiveTask(id)))
        XCTAssertTrue(current.current)
        _ = current.open(URL(string: "https://example.test/checked")!)
        XCTAssertEqual(app.browser.tab?.url, "https://example.test/checked")
        XCTAssertNil(app.surfaces.chat); XCTAssertFalse(app.browser.space.isPrivate)
        XCTAssertEqual(app.sync.engine?.taskRequests(), [request]); XCTAssertTrue(app.sync.engine?.sends().isEmpty == true)
    }

    func testTaskResultLinkBecomesInertInPrivateAndAfterEngineEnd() async throws {
        let (app, mac, _) = try await joinedApp()
        let id = try XCTUnwrap(app.taskDesk.send(words: "Read"))
        let request = try XCTUnwrap(app.sync.engine?.taskRequests().first)
        try await publish(.done, request: request, mac: mac, result: "Actual result")
        await expectEventually { app.sync.visibleLiveTask(id)?.result != nil }
        app.taskDesk.openChat(id, from: .other(nil))
        let link = LiveTaskChatAuthority(app: app, snapshot: try XCTUnwrap(app.sync.visibleLiveTask(id)))
        let secret = Space(id: "owned-private-links", name: "Private", emoji: "", tint: RGB(40, 40, 40),
                           today: [Tab(id: "private-link-tab", title: "Owned secret", site: "Secret", icon: "globe", page: "blank", isPrivate: true)], isPrivate: true)
        app.browser.adopt(app.browser.spaces + [secret]); app.browser.showSpace(secret.id)
        let count = app.browser.allTabs.count
        XCTAssertFalse(link.current)
        _ = link.open(URL(string: "https://example.test/private-leak")!)
        app.sync.end(); link.close()
        XCTAssertFalse(link.current)
        XCTAssertEqual(app.browser.allTabs.count, count)
        XCTAssertTrue(app.browser.space.isPrivate)
    }

    private nonisolated final class ReadWork: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        func add(_ id: String) { lock.lock(); ids.append(id); lock.unlock() }
        func reset() { lock.lock(); ids = []; lock.unlock() }
        var values: [String] { lock.lock(); defer { lock.unlock() }; return ids }
    }

    /// Crashes 269 and 349: the Now line asks on every chrome update, and a
    /// space with no task of its own still hopped to the journal's queue.
    func testNowLineAskForSpaceWithoutTasksNeverReadsTheJournal() async throws {
        let (app, _, _) = try await joinedApp()
        XCTAssertTrue(app.tasks.live.isEmpty)
        for _ in 0..<1000 { _ = app.nowItem }
        XCTAssertTrue(app.sync.visibleLiveTasks(in: app.browser.spaceID).isEmpty)
        XCTAssertEqual(app.sync.journalSpaceReads, 0)
        _ = try XCTUnwrap(app.taskDesk.send(words: "Read current heading"))
        app.sync.reconcileLiveTasks()
        XCTAssertEqual(app.sync.visibleLiveTasks(in: app.browser.spaceID).count, 1)
        XCTAssertEqual(app.sync.journalSpaceReads, 1)
    }

    func testHeavyJournalUIReadsOnlyCurrentSpaceCachedIDsAndStillRefusesImmediateTombstone() async throws {
        let (app, mac, _) = try await joinedApp()
        let engine = try XCTUnwrap(app.sync.engine)
        let other = "00000000-0000-0000-0000-000000000091"
        try mac.write(SyncCollection.space, other, SyncSpace(id: other, name: "Other public", icon: "").fields)
        await expectEventually { engine.journal.record(.init(collection: SyncCollection.space, id: other)) != nil }
        for index in 0..<128 {
            _ = try engine.sendReadOnlyTaskRecord("Actual other-space request \(index)", on: "mac",
                                                 origin: .init(space: other, isPrivate: false), epoch: epochA)
        }
        var owned: [String] = []
        for index in 0..<3 { owned.append(try XCTUnwrap(app.taskDesk.send(words: "Actual current-space request \(index)"))) }
        app.sync.reconcileLiveTasks()
        XCTAssertEqual(app.tasks.live.count, 131)
        let work = ReadWork(); engine.taskRecordReadWork = { work.add($0) }
        defer { engine.taskRecordReadWork = nil }
        XCTAssertEqual(engine.taskRequests().count, 131)
        let global = work.values.count
        XCTAssertEqual(global, 131)
        work.reset()
        XCTAssertEqual(Set(app.sync.visibleLiveTasks(in: app.browser.spaceID).map(\.id)), Set(owned))
        XCTAssertEqual(work.values.count, 3)
        XCTAssertEqual(Set(work.values), Set(owned))
        let currentSpace = app.browser.spaceID
        try engine.journal.remove(.init(collection: TaskRecords.requestCollection, id: owned[0]))
        work.reset()
        let visible = app.sync.visibleLiveTasks(in: currentSpace)
        XCTAssertEqual(Set(visible.map(\.id)), Set(owned.dropFirst()))
        XCTAssertEqual(work.values.count, 3)
        XCTAssertEqual(app.tasks.live.count, 131) // cached membership remains; current journal still refuses it
        let receipt = "Actual committed requests:131; full getter decodes:\(global); current-space getter decodes:3; immediate tombstone result:2; no wall-clock/FPS/Release claim"
        let attachment = XCTAttachment(string: receipt); attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertTrue(engine.sends().isEmpty)
    }

    func testCloseKeepsPresentationAuthorityAfterRealProgressAndResultChangesButNotReopen() async throws {
        let (app, mac, _) = try await joinedApp()
        let id = try XCTUnwrap(app.taskDesk.send(words: "Read current heading"))
        let request = try XCTUnwrap(app.sync.engine?.taskRequests().first)
        try await publish(.running, request: request, mac: mac)
        await expectEventually { app.sync.visibleLiveTask(id)?.observation?.status == .running }
        app.taskDesk.openChat(id, from: .other(nil))
        let close = LiveTaskChatAuthority(app: app, snapshot: try XCTUnwrap(app.sync.visibleLiveTask(id)))
        try await publish(.done, request: request, mac: mac, revision: 2, result: "Actual completed result")
        await expectEventually { app.sync.visibleLiveTask(id)?.result == "Actual completed result" }
        XCTAssertTrue(close.presentationCurrent)
        XCTAssertFalse(close.current, "an old link cannot borrow the new result even though Close still owns the page")
        close.close()
        await expectEventually { app.surfaces.chat == nil }
        app.taskDesk.openChat(id, from: .other(nil))
        XCTAssertFalse(close.presentationCurrent)
        close.close(); XCTAssertEqual(app.surfaces.chat, .task(id))
        let current = LiveTaskChatAuthority(app: app, snapshot: try XCTUnwrap(app.sync.visibleLiveTask(id)))
        let engine = try XCTUnwrap(app.sync.engine)
        try engine.journal.remove(.init(collection: TaskRecords.requestCollection, id: id))
        XCTAssertFalse(current.presentationCurrent)
        current.close(); XCTAssertEqual(app.surfaces.chat, .task(id))
    }

    func testLargeDoneResultFingerprintsAreComputedOnReconciliationAndNotRepeatedUIReads() async throws {
        let (app, mac, _) = try await joinedApp()
        let engine = try XCTUnwrap(app.sync.engine)
        var ids: [String] = []
        let body = String(repeating: "Actual retained Markdown paragraph **bold** and `code`.\n\n", count: 2048)
        for index in 0..<3 {
            let id = try XCTUnwrap(app.taskDesk.send(words: "Actual large done request \(index)"))
            ids.append(id)
            let request = try XCTUnwrap(engine.taskRequests().first { $0.id == id })
            try await publish(.done, request: request, mac: mac, result: body + "Result \(index)")
        }
        await expectEventually { ids.allSatisfy { id in app.tasks.live.contains { $0.id == id && $0.observation?.status == .done } }
            && app.sync.visibleLiveTasks(in: app.browser.spaceID).filter { $0.observation?.status == .done }.count == 3 }
        app.sync.reconcileLiveTasks()
        let before = app.tasks.liveResultFingerprintComputations
        XCTAssertGreaterThanOrEqual(before, 3)
        for _ in 0..<12 {
            let visible = app.sync.visibleLiveTasks(in: app.browser.spaceID)
            XCTAssertEqual(visible.count, 3)
            XCTAssertNotNil(app.tasks.liveNow(in: visible))
            app.sync.reconcileLiveTasks()
        }
        XCTAssertEqual(app.tasks.liveResultFingerprintComputations, before,
                       "unchanged large Done observations must not be encoded/hashed by repeated UI projection or reconciliation")
        let first = try XCTUnwrap(app.sync.visibleLiveTask(ids[0]))
        XCTAssertTrue(app.tasks.markLiveSeen(first))
        XCTAssertEqual(app.tasks.liveResultFingerprintComputations, before)
        let request = first.request
        try await publish(.done, request: request, mac: mac, revision: 2, result: body + "Actually changed result")
        await expectEventually { app.tasks.live.first { $0.id == request.id }?.observation?.revision == 2 }
        XCTAssertEqual(app.tasks.liveResultFingerprintComputations, before + 1)
        let changed = try XCTUnwrap(app.sync.visibleLiveTask(request.id))
        XCTAssertEqual(app.tasks.liveNow(in: [changed])?.taskID, request.id)
        let attachment = XCTAttachment(string: "Three actual Done bodies, \(body.utf8.count) bytes each; 12 real current-journal/UI reads plus 12 reconciliations; fingerprint computations unchanged at \(before); changed result recomputed once. Model-work evidence only, not Release/FPS.")
        attachment.lifetime = .keepAlways; add(attachment)
    }

    private final class PageGeometry {
        var frames: [String: CGRect] = [:]
        func receive(_ role: String, _ frame: CGRect) { frames[role] = frame }
    }

    private struct HostedTaskPage: View {
        let id: String
        let geometry: PageGeometry
        @State private var keyboard = KeyboardWatch.shared
        var body: some View {
            GeometryReader { bounds in
                LiveTaskChatSheet(id: id, size: CGSize(width: bounds.size.width,
                    height: max(0, bounds.size.height - keyboard.height)), onLayout: geometry.receive)
            }
            .ignoresSafeArea()
        }
    }

    private func renderedTaskPage(type: DynamicTypeSize, keyboard: Bool, name: String) async throws {
        let (app, mac, _) = try await joinedApp()
        let id = try XCTUnwrap(app.taskDesk.send(words: "Read the public heading and summarize its current details in a retained conversation"))
        let request = try XCTUnwrap(app.sync.engine?.taskRequests().first)
        let observed = "Actual long public task title that wraps to two lines without covering the request"
        let progress = "Actual observed completion with a long progress description that wraps across the available header"
        let result = "# Actual result\n\n" + String(repeating: "Actual supplied paragraph with **bold**, `inline code` and a [checked link](https://example.test/read).\n\n", count: 24)
        try await publish(.done, request: request, mac: mac, progress: progress, result: result, observedTitle: observed)
        await expectEventually { app.sync.visibleLiveTask(id)?.result == result }
        app.taskDesk.openChat(id, from: .other(nil))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let wasHidden = previous?.isHidden
        let previousRoot = previous?.rootViewController
        previous?.isHidden = true; previous?.rootViewController = nil
        let owned = UIWindow(windowScene: scene)
        owned.frame = CGRect(x: 0, y: 0, width: 375, height: 812)
        let geometry = PageGeometry()
        let container = UIViewController()
        let host = UIHostingController(rootView: HostedTaskPage(id: id, geometry: geometry)
            .environment(app).environment(\.dynamicTypeSize, type))
        host.safeAreaRegions = []
        owned.rootViewController = container
        container.addChild(host); host.view.frame = owned.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.view.addSubview(host.view); host.didMove(toParent: container)
        owned.makeKeyAndVisible(); owned.layoutIfNeeded()
        var input: UITextField?
        defer {
            input?.resignFirstResponder(); input?.removeFromSuperview()
            owned.isHidden = true; owned.rootViewController = nil
            if previous?.rootViewController == nil { previous?.rootViewController = previousRoot }
            if let wasHidden { previous?.isHidden = wasHidden }
            previous?.makeKey()
        }
        if keyboard {
            let field = UITextField(frame: CGRect(x: 10, y: 4, width: 200, height: 44))
            field.text = "Owned native keyboard context"
            container.view.insertSubview(field, belowSubview: host.view); input = field
            XCTAssertTrue(field.becomeFirstResponder())
            await expectEventually { KeyboardWatch.shared.height > 0 && field.isFirstResponder }
        }
        await expectEventually {
            owned.layoutIfNeeded()
            guard let header = geometry.frames["header"], let request = geometry.frames["request"],
                  let close = geometry.frames["close"], let page = geometry.frames["page"] else { return false }
            return request.minY >= header.maxY + 11 && close.width >= 44 - 1e-9
                && page.height > header.height + 44
        }
        let page = try XCTUnwrap(geometry.frames["page"])
        let header = try XCTUnwrap(geometry.frames["header"])
        let question = try XCTUnwrap(geometry.frames["request"])
        let titleFrame = try XCTUnwrap(geometry.frames["title"])
        let progressFrame = try XCTUnwrap(geometry.frames["progress"])
        let macFrame = try XCTUnwrap(geometry.frames["mac"])
        let close = try XCTUnwrap(geometry.frames["close"])
        let initialImage = UIGraphicsImageRenderer(bounds: owned.bounds).image { _ in
            XCTAssertTrue(owned.drawHierarchy(in: owned.bounds, afterScreenUpdates: true))
        }
        let initial = XCTAttachment(image: initialImage)
        initial.name = name + " initial user bubble"; initial.lifetime = .keepAlways; add(initial)
        XCTAssertTrue(page.contains(header)); XCTAssertTrue(header.contains(close))
        XCTAssertGreaterThanOrEqual(close.width, 44 - 1e-9); XCTAssertGreaterThanOrEqual(close.height, 44 - 1e-9)
        XCTAssertGreaterThanOrEqual(progressFrame.minY, titleFrame.maxY)
        XCTAssertGreaterThanOrEqual(macFrame.minY, progressFrame.maxY)
        XCTAssertLessThanOrEqual(macFrame.maxY, header.maxY)
        XCTAssertGreaterThanOrEqual(question.minY, header.maxY + 11)
        XCTAssertLessThanOrEqual(question.maxX, page.maxX)
        XCTAssertGreaterThanOrEqual(question.minX, page.minX)
        if type == .xxxLarge { XCTAssertGreaterThan(header.height, Metrics.Chats.trayFullHeaderTop + Metrics.Chats.conversationHeader) }
        if keyboard { XCTAssertLessThan(page.height, owned.bounds.height); XCTAssertTrue(input?.isFirstResponder == true) }
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        let scroll = try XCTUnwrap(views(host.view).compactMap { $0 as? UIScrollView }.first)
        XCTAssertTrue(scroll.isDescendant(of: host.view), "only the actual task hosting subtree owns the result scroll")
        await expectEventually { scroll.contentSize.height > scroll.bounds.height }
        let end = max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        scroll.setContentOffset(CGPoint(x: 0, y: end), animated: false)
        owned.layoutIfNeeded()
        XCTAssertEqual(scroll.contentOffset.y, end, accuracy: 0.5)
        XCTAssertEqual(geometry.frames["header"], header, "scrolling the long actual result cannot move or cover Close/header")
        let finalImage = UIGraphicsImageRenderer(bounds: owned.bounds).image { _ in
            XCTAssertTrue(owned.drawHierarchy(in: owned.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: finalImage)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        // A static frame alone cannot prove that the result stays out of the
        // actual header paint. Compare its native pixels before/after scrolling.
        func headerRGBA(_ image: UIImage) throws -> [UInt8] {
            let scale = image.scale
            let rect = CGRect(x: header.minX * scale, y: header.minY * scale,
                              width: header.width * scale, height: header.height * scale)
            let cg = try XCTUnwrap(image.cgImage?.cropping(to: rect))
            var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            try bytes.withUnsafeMutableBytes { raw in
                let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: cg.width, height: cg.height,
                    bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            }
            return bytes
        }
        let initialHeader = try headerRGBA(initialImage), finalHeader = try headerRGBA(finalImage)
        XCTAssertEqual(initialHeader.count, finalHeader.count)
        XCTAssertGreaterThan(initialHeader.count, 0)
        var changedHeaderInk = 0
        for pixel in stride(from: 0, to: min(initialHeader.count, finalHeader.count), by: 4) {
            let difference = abs(Int(initialHeader[pixel]) - Int(finalHeader[pixel]))
                + abs(Int(initialHeader[pixel + 1]) - Int(finalHeader[pixel + 1]))
                + abs(Int(initialHeader[pixel + 2]) - Int(finalHeader[pixel + 2]))
            if difference > 180 { changedHeaderInk += 1 }
        }
        let changedFraction = Double(changedHeaderInk) / Double(max(1, initialHeader.count / 4))
        let paint = XCTAttachment(string: "Actual same-window header crop:\(header); native RGB difference>180 pixels:\(changedHeaderInk); fraction:\(changedFraction); fixed header before/after real result scroll. Original normal/XXXL evidence changed 5.18%/5.88%; require below 0.1% to allow only minor raster variance.")
        paint.name = name + " header paint"; paint.lifetime = .keepAlways; add(paint)
        XCTAssertLessThan(changedFraction, 0.001, "actual result ink must not cross the retained title/progress/Mac header")
        let facts = XCTAttachment(string: "Actual hosted 375x812 task page; type:\(type); native firstResponder keyboard:\(keyboard); frames:\(geometry.frames); scroll end:\(end). Supplied TestMac observation; no provider/website call, no real-finger or Release acceptance.")
        facts.name = name + " geometry"; facts.lifetime = .keepAlways; add(facts)
        XCTAssertEqual(app.sync.visibleLiveTask(id)?.request, request)
        XCTAssertTrue(app.sync.engine?.sends().isEmpty == true)
    }

    func testActualTaskConversationNormalHeaderBubbleAndLongResultScrollGeometry() async throws {
        try await renderedTaskPage(type: .large, keyboard: false, name: "Actual task normal header and user bubble")
    }

    func testActualTaskConversationXXXLMeasuresLongHeaderAboveUserBubbleAndClose() async throws {
        try await renderedTaskPage(type: .xxxLarge, keyboard: false, name: "Actual task XXXL measured header and Close")
    }

    func testActualTaskConversationWithNativeFirstResponderKeyboardKeepsHeaderCloseAndScrollableBody() async throws {
        try await renderedTaskPage(type: .large, keyboard: true, name: "Actual task native keyboard header and body")
    }
}
