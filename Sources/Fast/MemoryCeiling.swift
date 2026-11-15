import Darwin
import Foundation

// The last word on a page's memory, said off the main thread.
//
// A page grown heavy is put to sleep or loaded again by the stuck watch
// (Stuck.swift's `lighten`), once a minute, on the main thread. Three
// agents working in Yab at once (2026-10-22) froze the main thread, and a
// page an agent drove grew to 39 GB with nothing left to look. WebKit
// itself ends only pages out of sight past its limit, and an agent's pages
// count as seen. So: every few seconds, from a queue of its own, every page
// process's memory is read, and one past the ceiling is ended. The tab then says what happened, as for
// any page that ended (Dialogs.swift).
//
// The pages are named by the main thread when it can (`publish`); frozen,
// the last ones it named are still watched, and the page that froze it is
// among them.

enum MemoryCeiling {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pages: [Int32: UInt64] = [:]
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?
    nonisolated(unsafe) private static var naming: DispatchSourceTimer?
    nonisolated(unsafe) private static var override: UInt64 = 0
    nonisolated(unsafe) private static var pageCount: Int?
    nonisolated(unsafe) private static var latest: Sample?

    /// Numbers from the existing watch, with no process or page identifiers.
    struct Sample {
        let at: TimeInterval
        let yabFootprintBytes: UInt64?
        let webProcessCount: Int?
        let measuredWebProcessCount: Int
        let largestWebProcessFootprintsBytes: [UInt64]

        init(at: TimeInterval, yabFootprintBytes: UInt64?, webProcessCount: Int?, footprints: [UInt64]) {
            self.at = at
            self.yabFootprintBytes = yabFootprintBytes
            self.webProcessCount = webProcessCount
            measuredWebProcessCount = footprints.count
            largestWebProcessFootprintsBytes = Array(footprints.sorted(by: >).prefix(3))
        }
    }

    static var sample: Sample? {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    /// Half the Mac's memory, between 8 and 24 GB, or `memory.ceiling` in
    /// MB for the bench. No page needs more; one that took it took the Mac.
    static var ceiling: UInt64 {
        lock.lock(); defer { lock.unlock() }
        if override > 0 { return override }
        let half = ProcessInfo.processInfo.physicalMemory / 2
        return min(max(half, 8 << 30), 24 << 30)
    }

    /// Started once, at launch.
    static func start() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        let set = Store.settings.double(forKey: "memory.ceiling")
        if set > 0 { override = UInt64(set) << 20 }
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "memory.ceiling", qos: .utility))
        source.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
        source.setEventHandler { look() }
        source.resume()
        timer = source
        // WebKit's own list of its page processes, read where it may be.
        let names = DispatchSource.makeTimerSource(queue: .main)
        names.schedule(deadline: .now() + 1, repeating: 5, leeway: .seconds(1))
        names.setEventHandler {
            MainActor.assumeIsolated { publish(PageProcesses.census()?.map(\.pid)) }
        }
        names.resume()
        naming = names
    }

    /// The page processes running now, from the main thread.
    static func publish(_ pids: [Int32]?) {
        var next: [Int32: UInt64] = [:]
        for pid in pids ?? [] { if let born = started(pid) { next[pid] = born } }
        lock.lock()
        pages = next
        pageCount = pids.map { Set($0).count }
        lock.unlock()
    }

    private static func look() {
        lock.lock()
        let watched = pages
        let count = pageCount
        lock.unlock()
        let limit = ceiling
        var footprints: [UInt64] = []
        for (pid, born) in watched {
            guard let size = footprint(pid), started(pid) == born else { continue }
            footprints.append(size)
            guard size > limit else { continue }
            let sent = kill(pid, SIGKILL)
            if sent != 0 {
                let failure = errno
                // The main thread may be frozen: no fresh census will put a
                // failed attempt back. Only a process already gone retires.
                guard failure == ESRCH else {
                    Watchdog.note("page \(pid) past its memory ceiling could not be ended (error \(failure)): watching it again")
                    continue
                }
            } else {
                Watchdog.note(String(format: "page %d at %.1f GB, past the ceiling of %.1f GB: ended",
                                     pid, Double(size) / Double(1 << 30), Double(limit) / Double(1 << 30)))
            }
            lock.lock()
            pages[pid] = nil
            lock.unlock()
        }
        let measured = Sample(at: ProcessInfo.processInfo.systemUptime, yabFootprintBytes: footprint(getpid()),
                              webProcessCount: count, footprints: footprints)
        lock.lock()
        latest = measured
        lock.unlock()
    }

    static func footprint(_ pid: Int32) -> UInt64? {
        var info = rusage_info_v2()
        let ok = withUnsafeMutablePointer(to: &info) { raw in
            raw.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return ok == 0 ? info.ri_phys_footprint : nil
    }

    private static func started(_ pid: Int32) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec
    }
}
