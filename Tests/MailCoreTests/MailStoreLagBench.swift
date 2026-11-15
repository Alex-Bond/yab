import Foundation
import Testing
@testable import MailCore

/// What a keypress waits for while a backfill writes: a thread read through
/// the writer's queue against the same read through the read-only look
/// (`off`), timed while pages of mail go in on another thread, on a store in
/// a file. Numbers only, printed; run on purpose with YAB_MAIL_BENCH=1:
///   YAB_MAIL_BENCH=1 swift test --filter MailStoreLagBench
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["YAB_MAIL_BENCH"] != nil))
struct MailStoreLagBench {
    static let seeded = 20_000, page = 500, pages = 12

    static func mail(_ n: Int, at: Double) -> MailMessage {
        let body = String(repeating: "Words of mail number \(n) about the quarterly plan. ", count: 40)
        return MailMessage(id: "m\(n)", thread: "t\(n / 3)", from: MailPerson(name: "Person \(n % 97)", address: "p\(n % 97)@example.org"),
                           to: [MailPerson(name: "", address: "me@acme.io")], subject: "Subject \(n)", snippet: "Snippet \(n)",
                           date: Date(timeIntervalSince1970: at), labels: n % 4 == 0 ? ["INBOX", "UNREAD"] : ["INBOX"],
                           text: body, html: "<p>" + body + "</p>")
    }

    static func store() -> (MailStore, URL) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mail-lag-\(UUID().uuidString).sqlite")
        let store = MailStore(file: file)
        store.set("me", "me@acme.io")
        for start in stride(from: 0, to: seeded, by: page) {
            store.put((start..<start + page).map { mail($0, at: 1_800_000_000 - Double($0) * 60) })
        }
        return (store, file)
    }

    final class Lags: @unchecked Sendable {
        let lock = NSLock()
        var ms: [Double] = []
        var writing = true
        func add(_ value: Double) { lock.lock(); ms.append(value); lock.unlock() }
        var going: Bool { lock.lock(); defer { lock.unlock() }; return writing }
        func stop() { lock.lock(); writing = false; lock.unlock() }
    }

    static func line(_ name: String, _ values: [Double]) -> String {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return "\(name): none" }
        let at = { (q: Double) in sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] }
        return String(format: "%@: n=%d p50=%.2fms p95=%.2fms p99=%.2fms max=%.2fms", name, sorted.count, at(0.5), at(0.95), at(0.99), sorted.last!)
    }

    /// Pages written on one thread while another reads a thread every 2 ms.
    static func during(_ store: MailStore, from: Int, read: @escaping @Sendable (Int) -> Void) -> (reads: [Double], pages: [Double]) {
        let lags = Lags()
        var pageMs: [Double] = []
        let reader = Thread {
            var n = 0
            while lags.going {
                let start = DispatchTime.now().uptimeNanoseconds
                read(n)
                lags.add(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
                n += 1
                usleep(2000)
            }
        }
        reader.start()
        for p in 0..<pages {
            let base = from + p * page
            let batch = (base..<base + page).map { mail($0, at: 1_700_000_000 - Double($0) * 60) }
            let start = DispatchTime.now().uptimeNanoseconds
            #expect(store.put(batch, backfilled: true))
            pageMs.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        lags.stop()
        while !reader.isFinished { usleep(1000) }
        return (lags.ms, pageMs)
    }

    @Test func readsDuringABackfill() {
        let (store, file) = Self.store()
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file.path + suffix) } }
        let ids = (0..<200).map { "t\($0 * 37)" }

        // Quiet: no writer.
        var quiet: [Double] = [], quietOff: [Double] = []
        for n in 0..<400 {
            var start = DispatchTime.now().uptimeNanoseconds
            _ = store.messages(thread: ids[n % ids.count])
            quiet.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            start = DispatchTime.now().uptimeNanoseconds
            _ = store.off.messages(thread: ids[n % ids.count])
            quietOff.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }

        let writer = Self.during(store, from: Self.seeded) { n in _ = store.messages(thread: ids[n % ids.count]) }
        let reader = Self.during(store, from: Self.seeded + Self.pages * Self.page) { n in _ = store.off.messages(thread: ids[n % ids.count]) }
        let threadsWriter = Self.during(store, from: Self.seeded + 2 * Self.pages * Self.page) { _ in _ = store.threads(label: "INBOX", limit: 50) }
        let threadsReader = Self.during(store, from: Self.seeded + 3 * Self.pages * Self.page) { _ in _ = store.off.threads(label: "INBOX", limit: 50) }

        let report = [
            "MAIL-LAG-BENCH seeded=\(Self.seeded) page=\(Self.page) pages=\(Self.pages)",
            Self.line("quiet writer messages(thread:)", quiet),
            Self.line("quiet off messages(thread:)", quietOff),
            Self.line("backfill writer messages(thread:)", writer.reads),
            Self.line("backfill off messages(thread:)", reader.reads),
            Self.line("backfill writer threads(label:)", threadsWriter.reads),
            Self.line("backfill off threads(label:)", threadsReader.reads),
            Self.line("put page of \(Self.page)", writer.pages + reader.pages + threadsWriter.pages + threadsReader.pages),
        ].joined(separator: "\n")
        print(report)
        #expect(!writer.reads.isEmpty && !reader.reads.isEmpty)
    }
}
