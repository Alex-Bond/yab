import Foundation
import Testing
@testable import SyncKit

/// Two devices against the deployed server, over the real web: run with
/// `YAB_SYNC_LIVE=1` (and `YAB_SYNC_URL` for another server). Each run makes
/// a throwaway account and deletes it at the end.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["YAB_SYNC_LIVE"] != nil))
struct SyncLiveTests {
    let base = URL(string: ProcessInfo.processInfo.environment["YAB_SYNC_URL"] ?? "https://yab-sync.21st.workers.dev")!

    private func until(_ client: SyncClient, seconds: Double = 15, _ done: @escaping () -> Bool) async -> Bool {
        for _ in 0..<Int(seconds * 20) {
            if client.queue.sync(execute: done) { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    @Test func twoMacsOverTheWeb() async throws {
        Kind.register(Kind("live.mark", groups: [Kind.place]))
        let seal = Seal.make()
        let a = SyncClient(base: base, journal: try Journal(path: nil, device: "live-a"), seal: seal, device: .init(id: "live-a", name: "A", model: "test"))
        let b = SyncClient(base: base, journal: try Journal(path: nil, device: "live-b"), seal: seal, device: .init(id: "live-b", name: "B", model: "test"))
        defer { a.deleteAccount { _ in } }
        a.start()
        #expect(await until(a) { a.state == .live })
        try a.journal.change(.init(collection: "live.mark", id: "1"), ["title": "Hello from A"])
        a.kick()
        b.start()
        #expect(await until(b) { b.journal.record(.init(collection: "live.mark", id: "1"))?["title"] == "Hello from A" })
        // Live: a change made now arrives without a new hello.
        let sent = Date()
        try b.journal.change(.init(collection: "live.mark", id: "2"), ["title": "Back from B"])
        b.kick()
        #expect(await until(a) { a.journal.record(.init(collection: "live.mark", id: "2"))?["title"] == "Back from B" })
        print("sync live: B to A in \(Int(Date().timeIntervalSince(sent) * 1000)) ms")

        var listed: [SyncClient.Listed]?
        a.devices { listed = $0 }
        #expect(await until(a) { listed != nil })
        #expect(Set(listed?.map(\.id) ?? []) == ["live-a", "live-b"])

        // A device let in by a code.
        let joining = Joining()
        var joined: Seal?
        Pairing.ask(joining, base: base, timeout: 30) { joined = $0 }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        var answered = false
        Pairing.answer(code: joining.code, seal: seal, base: base) { answered = $0 }
        #expect(await until(a, seconds: 20) { answered && joined != nil })
        #expect(joined?.raw == seal.raw)

        // The other way round (register 1628): a Mac types the code A's Add
        // a Device shows, both show the same digits, A lets it in.
        let host = JoinInviteHost(base: base)
        let heard = Heard()
        host.start { heard.set($0) }
        let guest = Joining(code: JoinInvite.code(scanned: host.code.lowercased()))
        let got = Got()
        let asking = Pairing.wait(guest, base: base, timeout: 60) { got.set($0) }
        #expect(await until(a, seconds: 30) { heard.value != nil })
        #expect(heard.value == .arrived(check: JoinInvite.check(code: host.code, publicKey: guest.publicKey)))
        host.letIn(seal)
        #expect(await until(a, seconds: 30) { got.value != nil })
        #expect(try got.value?.get().raw == seal.raw)
        asking.cancel()
        host.cancel()

        // Removed: b stops.
        var removed = false
        a.remove(device: "live-b") { removed = $0 }
        #expect(await until(b) { if case .refused = b.state { return removed }; return false })
    }
}

/// The last thing an invite said, from any queue.
final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var event: JoinInviteHost.Event?
    func set(_ event: JoinInviteHost.Event) { lock.lock(); self.event = event; lock.unlock() }
    var value: JoinInviteHost.Event? { lock.lock(); defer { lock.unlock() }; return event }
}
