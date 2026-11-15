import Foundation
import Darwin

/// The engine owns only a unique staging file. The destination is published
/// after completion, so failures/cancel can never delete a user's file or
/// expose a partial installer as a completed download.
struct DownloadFile: Sendable {
    let destination: URL
    let staging: URL
    /// What Finder shows in the destination's folder meanwhile, if anything.
    let partial: DownloadPartial?
    private let activity = Activity()
    private let replacesExisting: Bool

    private final class Activity: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func check() throws {
            lock.lock(); let stopped = cancelled; lock.unlock()
            if stopped { throw URLError(.cancelled) }
        }
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    }

    init(destination: URL, root: URL, showsPartial: Bool = false, replacesExisting: Bool = false) throws {
        self.destination = destination
        self.replacesExisting = replacesExisting
        // Named with its process: a headless Yab shares this folder with a
        // browser, and `leftovers` must not take a transfer still running.
        let folder = root.appendingPathComponent("\(getpid()).\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        staging = folder.appendingPathComponent("transfer")
        partial = showsPartial ? DownloadPartial(destination: destination, note: folder.appendingPathComponent(Self.noteName)) : nil
    }

    /// Media assembly already has an owned temporary workspace.
    init(destination: URL, ownedStaging: URL) {
        self.destination = destination
        replacesExisting = false
        staging = ownedStaging
        partial = nil
    }

    func publish() throws -> URL {
        try activity.check()
        let values = try staging.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw URLError(.cannotOpenFile) }
        // Only an explicit save-panel choice authorizes replacement. Automatic
        // destinations retain RENAME_EXCL, including a competing writer.
        if rename(staging, to: destination) != 0 {
            let failure = errno
            guard failure == EXDEV else { throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO) }
            // Another disk: copy beside the destination under a private
            // name, then publish that complete file with the same replacement policy.
            let copied = destination.deletingLastPathComponent().appendingPathComponent(".yab-download-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: copied) }
            try FileManager.default.copyItem(at: staging, to: copied)
            try activity.check()
            guard rename(copied, to: destination) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        discard()
        return destination
    }

    private func rename(_ source: URL, to target: URL) -> Int32 {
        source.path.withCString { from in
            target.path.withCString { to in renamex_np(from, to, replacesExisting ? 0 : UInt32(RENAME_EXCL)) }
        }
    }

    func discard() {
        activity.cancel()
        partial?.remove()
        try? FileManager.default.removeItem(at: staging.deletingLastPathComponent())
    }

    private static let noteName = "partial"

    /// Transfers a killed or crashed Yab left: nothing can go on from them,
    /// since no row and no resume data outlive the process. Read at launch,
    /// before this process has a transfer of its own; cleared off the main
    /// thread, as a note can point at a disk that no longer answers.
    static func leftovers(in root: URL) -> [URL] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.filter { folder in
            guard let owner = folder.lastPathComponent.split(separator: ".").first.flatMap({ pid_t($0) }),
                  owner != getpid() else { return true }
            return kill(owner, 0) != 0 && errno != EPERM
        }
    }

    static func clear(_ leftovers: [URL]) {
        for folder in leftovers {
            if let path = try? String(contentsOf: folder.appendingPathComponent(noteName), encoding: .utf8) {
                DownloadPartial.removeLeftover(URL(fileURLWithPath: path))
            }
            try? FileManager.default.removeItem(at: folder)
        }
    }
}

/// A download's bytes stay in Yab's own staging folder, where the network
/// process may always write (`DownloadFile`), so its destination is empty
/// until it is whole, and Finder used to show nothing at all. This is the
/// empty "name.zip.yabdownload" beside where it will land, with a published
/// progress Finder draws its bar from. Nothing depends on it: a folder that
/// refuses it costs only the sign, and it never holds the file's bytes.
/// A file of that name already there is left alone, and only an empty file
/// this transfer noted is ever removed.
final class DownloadPartial: @unchecked Sendable {
    static let suffix = ".yabdownload"

    private let destination: URL
    private let note: URL
    private let lock = NSLock()
    private var gone = false
    private var file: URL?
    private var source: Progress?
    private var shown: Progress?
    private var watch: NSKeyValueObservation?
    private var told: CFAbsoluteTime = 0

    init(destination: URL, note: URL) {
        self.destination = destination
        self.note = note
    }

    var placed: URL? { lock.withLock { file } }
    var published: Progress? { lock.withLock { shown } }

    /// The name for a try: never past what a file name may hold.
    static func name(for destination: URL, attempt: Int) -> String {
        let tail = (attempt > 1 ? " \(attempt)" : "") + suffix
        var base = destination.lastPathComponent
        while base.utf8.count + tail.utf8.count > 255 { base.removeLast() }
        return base + tail
    }

    /// Off the main thread: a folder can take its time to answer (#400).
    func place() {
        guard !lock.withLock({ gone }) else { return }
        let folder = destination.deletingLastPathComponent()
        for attempt in 1...50 {
            let candidate = folder.appendingPathComponent(Self.name(for: destination, attempt: attempt))
            // Noted first: a crash right after creating it still finds it.
            guard (try? candidate.path.write(to: note, atomically: true, encoding: .utf8)) != nil else { return }
            let made = open(candidate.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
            guard made >= 0 else {
                if errno == EEXIST { continue }
                return
            }
            close(made)
            let stopped: Bool = lock.withLock {
                if !gone { file = candidate; show() }
                return gone
            }
            if stopped { try? FileManager.default.removeItem(at: candidate) }
            return
        }
    }

    /// Its numbers come from this transfer, or a resumed one's new progress.
    func follow(_ progress: Progress) {
        lock.withLock {
            guard !gone else { return }
            hide()
            source = progress
            show()
        }
        let observation = progress.observe(\.completedUnitCount) { [weak self] progress, _ in
            self?.moved(progress)
        }
        lock.withLock { if !gone, source === progress { watch = observation } }
    }

    /// Stopped but able to go on: the name stays, the bar doesn't.
    func stop() { lock.withLock { source = nil; hide() } }

    /// The file landed, or was given up on. Said any number of times.
    func remove() {
        let left: URL? = lock.withLock {
            gone = true
            source = nil
            hide()
            defer { file = nil }
            return file
        }
        if let left { try? FileManager.default.removeItem(at: left) }
    }

    deinit { shown?.unpublish() }

    private func moved(_ progress: Progress) {
        // WebKit reports every chunk it writes, and Finder needs far fewer.
        let now = CFAbsoluteTimeGetCurrent()
        let target: Progress? = lock.withLock {
            guard now - told >= 0.25 else { return nil }
            told = now
            return shown
        }
        guard let target else { return }
        target.totalUnitCount = progress.totalUnitCount
        target.completedUnitCount = progress.completedUnitCount
    }

    /// With the lock held.
    private func show() {
        guard shown == nil, let file, let source else { return }
        let progress = Progress(parent: nil, userInfo: nil)
        progress.kind = .file
        progress.fileOperationKind = .downloading
        progress.fileURL = file
        progress.isCancellable = false
        progress.isPausable = false
        progress.totalUnitCount = source.totalUnitCount
        progress.completedUnitCount = source.completedUnitCount
        progress.publish()
        shown = progress
    }

    /// With the lock held.
    private func hide() {
        watch?.invalidate()
        watch = nil
        shown?.unpublish()
        shown = nil
    }

    /// Only the sign itself: the name it was given and nothing in it.
    static func removeLeftover(_ file: URL) {
        guard file.lastPathComponent.hasSuffix(suffix),
              let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == 0 else { return }
        try? FileManager.default.removeItem(at: file)
    }
}
