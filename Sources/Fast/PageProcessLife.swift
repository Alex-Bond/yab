import AppKit

/// Local process identity checks, shared by page engines on this Mac.
enum PageProcessLife {
    /// A helper process ended by its pid, if it is still the one that began
    /// at `born`. SIGKILL: an XPC service holds SIGTERM until its work is
    /// done, and the GPU process ended on 2026-10-08 never was.
    static func end(_ pid: Int32, born: UInt64) {
        guard started(pid) == born else { return }
        kill(pid, SIGKILL)
    }

    /// When a process began, to tell it from a later one with its number.
    static func started(_ pid: Int32) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec
    }
}
