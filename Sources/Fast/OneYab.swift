import Foundation

// One Yab on one set of files. A second process on the same folder, `open
// -n`, a probe started twice in one world, would take the bench's socket
// over from the first (Bench.start unlinks it) and write the same session
// and history files as the first. So before anything else, the browser
// holds a lock on a file of its folder for as long as it runs, and a
// second one says whose it is and goes. The system lets the lock go with
// the process, however it ends.
enum OneYab {
    /// The open file the lock is held on, kept open for good.
    private static var held: Int32 = -1

    /// Holds the lock, or says who does and exits. A yab relaunching
    /// itself (an update, the move into Applications) opens the new one
    /// once the old is gone, but the lock is given a few seconds anyway.
    static func take() {
        let path = Store.file("yab.lock").path
        try? FileManager.default.createDirectory(at: Store.folder, withIntermediateDirectories: true)
        let fd = open(path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { return }
        let limit = Date().addingTimeInterval(5)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard Date() < limit else {
                var said = [UInt8](repeating: 0, count: 32)
                let n = pread(fd, &said, said.count, 0)
                let pid = n > 0 ? String(decoding: said[0..<n], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : "?"
                FileHandle.standardError.write(Data("Yab is already running on these files (pid \(pid)).\n".utf8))
                exit(1)
            }
            usleep(100_000)
        }
        ftruncate(fd, 0)
        let mine = Array("\(getpid())\n".utf8)
        _ = pwrite(fd, mine, mine.count, 0)
        held = fd
    }
}
