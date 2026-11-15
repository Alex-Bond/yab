import Foundation
import SyncKit
import Testing
@testable import Fast

/// Exercise the real Pairing.ask completion and SyncCenter account-entry routes.
/// The key keeper and activation are in memory; no sync client or Keychain runs.
@MainActor
@Suite(.serialized)
struct SyncAccountEntryTests {
    @Test func freshTurnOnCannotBeReplacedByAnEarlierCode() async throws {
        let world = try World()
        defer { world.restore() }
        let box = HeldPairing()
        let account = Account()
        let center = account.center(box)
        defer { center.stopAsking(); box.finish() }
        let pending = try await ask(center, box)
        let earlier = Seal.make()

        center.startSyncing()
        let chosen = try #require(account.kept.first)
        #expect(center.joining == nil)
        #expect(center.recovery == Seal(raw: chosen)?.recovery)
        try box.answer(pending, with: earlier)
        await drainMainQueue()

        #expect(account.kept == [chosen], "the earlier code must not overwrite the new account's key")
        #expect(account.activated == [chosen], "only the account selected by Turn On may start")
        #expect(chosen != earlier.raw)
        #expect(center.joining == nil)
        #expect(center.recovery == Seal(raw: chosen)?.recovery)
        #expect(box.unexpected == 0)
    }

    @Test func turnOnMakesNoAccountUntilThePersonSaysItIsTheirFirstDevice() async throws {
        let world = try World()
        defer { world.restore() }
        let account = Account()
        let center = account.center(HealthyLine(), lookFor: 0.1)
        center.turnOn()
        #expect(center.arrival == .looking)
        #expect(account.kept.isEmpty)
        #expect(await until { center.arrival == .nobody })
        #expect(account.kept.isEmpty, "a second account is made only by choice")
        center.startSyncing()
        #expect(account.kept.count == 1)
        #expect(center.arrival == .ready)
    }

    @Test func turnOnTakesTheKeyThatArrivesWhileItLooks() async throws {
        let world = try World()
        defer { world.restore() }
        let account = Account()
        let center = account.center(HealthyLine(), lookFor: 5)
        center.turnOn()
        let chosen = Seal.make()
        account.shared = chosen
        #expect(await until { account.activated == [chosen.raw] })
        #expect(center.arrival == .ready)
        #expect(center.recovery == nil)
    }

    @Test func turnOnOfflineMakesNoAccountAndSaysSo() async throws {
        let world = try World()
        defer { world.restore() }
        let account = Account()
        let center = account.center(DeadLine(), lookFor: 0.1)
        center.turnOn()
        #expect(await until { center.arrival == .offline })
        #expect(account.kept.isEmpty)
    }

    private func until(_ seconds: Double = 10, _ done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return done()
    }

    @Test func sharedTurnOnAlsoSupersedesAnEarlierCode() async throws {
        let world = try World()
        defer { world.restore() }
        let box = HeldPairing()
        let chosen = Seal.make()
        let account = Account(shared: chosen)
        let center = account.center(box)
        defer { center.stopAsking(); box.finish() }
        let pending = try await ask(center, box)

        center.turnOn()
        try box.answer(pending, with: Seal.make())
        await drainMainQueue()

        #expect(account.kept == [chosen.raw])
        #expect(account.activated == [chosen.raw])
        #expect(center.joining == nil)
        #expect(center.recovery == nil, "joining the shared account does not create a new recovery card")
        #expect(box.unexpected == 0)
    }

    @Test func cancelRejectsTheAnswerAlreadyInFlight() async throws {
        let world = try World()
        defer { world.restore() }
        let box = HeldPairing()
        let account = Account()
        let center = account.center(box)
        defer { center.stopAsking(); box.finish() }
        let pending = try await ask(center, box)

        center.stopAsking()
        try box.answer(pending, with: Seal.make())
        await drainMainQueue()

        #expect(account.kept.isEmpty && account.activated.isEmpty)
        #expect(center.joining == nil)
        #expect(box.unexpected == 0)
    }

    @Test func aNewCodeRejectsTheOldAnswerButAcceptsItsOwn() async throws {
        let world = try World()
        defer { world.restore() }
        let box = HeldPairing()
        let account = Account()
        let center = account.center(box)
        defer { center.stopAsking(); box.finish() }
        let old = try await ask(center, box)
        let current = try await ask(center, box)
        let chosen = Seal.make()

        try box.answer(old, with: Seal.make())
        await drainMainQueue()
        #expect(account.kept.isEmpty && account.activated.isEmpty)
        #expect(center.joining?.code == current.code)

        try box.answer(current, with: chosen)
        await drainMainQueue()
        #expect(account.kept == [chosen.raw])
        #expect(account.activated == [chosen.raw])
        #expect(center.joining == nil)
        #expect(box.unexpected == 0)
    }

    @Test func aRecoveryKeyCannotBeReplacedByAnEarlierCode() async throws {
        let world = try World()
        defer { world.restore() }
        let box = HeldPairing()
        let chosen = Seal.make()
        let account = Account()
        let center = account.center(box)
        defer { center.stopAsking(); box.finish() }
        let pending = try await ask(center, box)

        #expect(center.join(recovery: chosen.recovery))
        try box.answer(pending, with: Seal.make())
        await drainMainQueue()

        #expect(account.kept == [chosen.raw])
        #expect(account.activated == [chosen.raw])
        #expect(center.joining == nil)
        #expect(box.unexpected == 0)
    }

    @Test func anInvalidEnvelopeNeverKeepsOrStartsAnAccount() async throws {
        let world = try World()
        defer { world.restore() }
        let box = HeldPairing()
        let account = Account()
        let center = account.center(box)
        defer { center.stopAsking(); box.finish() }
        let pending = try await ask(center, box)

        try box.deliver(pending, envelope: Data([1, 2, 3]))
        await drainMainQueue()

        #expect(account.kept.isEmpty && account.activated.isEmpty)
        #expect(center.joining == nil)
        #expect(box.unexpected == 0)
    }

    /// The code another Mac shows under Add a Device, typed on this one
    /// (register 1628): this Mac waits under it with the digits that Mac
    /// asks about, and joins on its yes.
    @Test func aMacJoinsByTheCodeAnotherMacShows() async throws {
        let world = try World()
        defer { world.restore() }
        let box = HeldPairing()
        let account = Account()
        let center = account.center(box)
        defer { center.stopAsking(); box.finish() }

        center.askToJoin(invite: "https://example.com")
        #expect(center.joining == nil && center.joinTrouble != nil)
        center.askToJoin(invite: "k7qm 4xtd")
        let joining = try #require(center.joining)
        #expect(center.joiningInvited)
        #expect(center.joinTrouble == nil)
        #expect(joining.code == "K7QM-4XTD")
        #expect(center.joiningCheck == JoinInvite.check(code: "K7QM-4XTD", publicKey: joining.publicKey))
        let end = Date().addingTimeInterval(30)
        while !box.isWaiting(joining), Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        let chosen = Seal.make()
        try box.answer(joining, with: chosen)
        await drainMainQueue()

        #expect(account.kept == [chosen.raw])
        #expect(account.activated == [chosen.raw])
        #expect(center.joining == nil && !center.joiningInvited)
        #expect(box.unexpected == 0)
    }

    private func ask(_ center: SyncCenter, _ box: HeldPairing) async throws -> Joining {
        center.askToJoin()
        let joining = try #require(center.joining)
        let end = Date().addingTimeInterval(30)
        while !box.isWaiting(joining), Date() < end {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(box.isWaiting(joining), "the real Pairing.ask must reach its held GET")
        return joining
    }

    /// answer() runs the actual decryption/completion synchronously, which queues
    /// SyncCenter's MainActor block before this FIFO barrier. No timing guess.
    private func drainMainQueue() async {
        await withCheckedContinuation { done in
            DispatchQueue.main.async { done.resume() }
        }
    }

    @MainActor
    private final class Account {
        var shared: Seal?
        var kept: [Data] = []
        var activated: [Data] = []

        init(shared: Seal? = nil) { self.shared = shared }

        func center(_ box: any Transport, lookFor: TimeInterval = 6) -> SyncCenter {
            SyncCenter(sharedKey: { self.shared }, keepKey: { self.kept.append($0.raw) },
                       activateAccount: { _, seal in self.activated.append(seal.raw) }, pairingTransport: box, lookFor: lookFor)
        }
    }

    /// join() retains its real snapshot/SharedPins prelude. Preserve its test-world
    /// inputs and output; suppress the optional pins-default transition so no open
    /// test window's preferences change. No additional production seam is needed.
    @MainActor
    private final class World {
        private let manager = FileManager.default
        private let backup: URL
        private let snapshot: URL
        private let hadSnapshot: Bool
        private let files: [String: Data]
        private let defaults: [String: Any]
        private static let keys = ["sync.snapshot", SharedPins.key, SharedPins.decidedKey, SharedPins.joiningKey]

        init() throws {
            try #require(Store.testing)
            Session.settle()
            backup = manager.temporaryDirectory.appendingPathComponent("sync-entry-" + UUID().uuidString)
            snapshot = Store.folder.appendingPathComponent("Sync Snapshot", isDirectory: true)
            hadSnapshot = manager.fileExists(atPath: snapshot.path)
            files = try Self.inputFiles()
            defaults = Dictionary(uniqueKeysWithValues: Self.keys.compactMap { key in
                Store.settings.object(forKey: key).map { (key, $0) }
            })
            if hadSnapshot { try manager.copyItem(at: snapshot, to: backup) }
            Store.settings.removeObject(forKey: SharedPins.decidedKey)
        }

        func restore() {
            Session.settle()
            let current: [String: Data]
            do { current = try Self.inputFiles() }
            catch { Issue.record(error); current = [:] }
            for name in current.keys where files[name] == nil {
                restoreFile { try manager.removeItem(at: Store.folder.appendingPathComponent(name)) }
            }
            for (name, data) in files {
                restoreFile { try data.write(to: Store.folder.appendingPathComponent(name), options: .atomic) }
            }
            if manager.fileExists(atPath: snapshot.path) { restoreFile { try manager.removeItem(at: snapshot) } }
            if hadSnapshot { restoreFile { try manager.copyItem(at: backup, to: snapshot) } }
            if manager.fileExists(atPath: backup.path) { restoreFile { try manager.removeItem(at: backup) } }
            for key in Self.keys {
                if let value = defaults[key] { Store.settings.set(value, forKey: key) }
                else { Store.settings.removeObject(forKey: key) }
            }
        }

        private func restoreFile(_ action: () throws -> Void) {
            do { try action() } catch { Issue.record(error) }
        }

        private static func inputFiles() throws -> [String: Data] {
            let names = try FileManager.default.contentsOfDirectory(atPath: Store.folder.path).filter {
                $0 == "spaces.json" || $0 == "bookmarks.json" || ($0.hasPrefix("session") && $0.hasSuffix(".json"))
            }
            return try Dictionary(uniqueKeysWithValues: names.map { name in
                (name, try Data(contentsOf: Store.folder.appendingPathComponent(name)))
            })
        }
    }
}

/// No timer or live URLSession: hold the real Pairing.ask GET until the test
/// supplies an envelope sealed to the exact posted Joining public key.
private final class HeldPairing: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var posted: [String: String] = [:]
    private var waiting: [String: (Int?, Data?) -> Void] = [:]
    private var closed = false
    private var unexpectedRequests = 0

    var unexpected: Int { lock.lock(); defer { lock.unlock() }; return unexpectedRequests }

    func request(_ request: URLRequest, _ done: @escaping (Int?, Data?) -> Void) {
        lock.lock()
        if closed { lock.unlock(); return done(410, nil) }
        let path = request.url?.path ?? ""
        if path == "/v1/pair", request.httpMethod == "POST",
           let data = request.httpBody,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let box = json["code"], let pub = json["pub"] {
            posted[box] = pub
            lock.unlock()
            done(204, nil)
        } else if path.hasPrefix("/v1/pair/"), request.httpMethod == nil || request.httpMethod == "GET" {
            let box = String(path.dropFirst("/v1/pair/".count))
            if posted[box] != nil {
                waiting[box] = done
                lock.unlock()
            } else { unexpectedRequests += 1; lock.unlock(); done(404, nil) }
        } else { unexpectedRequests += 1; lock.unlock(); done(404, nil) }
    }

    func isWaiting(_ joining: Joining) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return waiting[joining.box] != nil
    }

    func answer(_ joining: Joining, with seal: Seal) throws {
        lock.lock()
        let publicKey = posted[joining.box]
        lock.unlock()
        let pub = try #require(Joining.verified(publicKey, code: joining.code))
        let envelope = try Joining.seal(seal, to: pub, code: joining.code)
        try deliver(joining, envelope: envelope)
    }

    func deliver(_ joining: Joining, envelope: Data) throws {
        let data = try JSONSerialization.data(withJSONObject: ["envelope": envelope.base64EncodedString()])
        lock.lock()
        let done = waiting.removeValue(forKey: joining.box)
        lock.unlock()
        let respond = try #require(done)
        respond(200, data)
    }

    func finish() {
        lock.lock()
        closed = true
        let callbacks = Array(waiting.values)
        waiting.removeAll()
        lock.unlock()
        for done in callbacks { done(410, nil) }
    }

    func open(_ request: URLRequest, received: @escaping (String) -> Void, closed: @escaping (Int?) -> Void) -> Line {
        lock.lock(); unexpectedRequests += 1; lock.unlock()
        return Silent()
    }

    private final class Silent: Line {
        func send(_ text: String) {}
        func close() {}
    }
}

private final class HealthyLine: Transport, @unchecked Sendable {
    func request(_ request: URLRequest, _ done: @escaping (Int?, Data?) -> Void) { done(200, Data()) }
    func open(_ request: URLRequest, received: @escaping (String) -> Void, closed: @escaping (Int?) -> Void) -> Line { PairBox.Silent() }
}

private final class DeadLine: Transport, @unchecked Sendable {
    func request(_ request: URLRequest, _ done: @escaping (Int?, Data?) -> Void) { done(nil, nil) }
    func open(_ request: URLRequest, received: @escaping (String) -> Void, closed: @escaping (Int?) -> Void) -> Line { PairBox.Silent() }
}
