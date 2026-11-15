import Foundation

/// The app this process was started from, still there, checked before
/// anything asks for the main bundle, and that bundle then read while it is.
///
/// An update swaps yab.app for the new copy with two renames and later
/// removes the old one (Update.Swap), and a person can drag a new copy over
/// it in Finder, which takes seconds. A `yab mcp` an agent starts in that gap
/// finds no app at its own path: Foundation then has no main bundle at all,
/// Store.testing reads that as a test run, and NSUserDefaults(suiteName:)
/// dereferences the missing bundle and dies at 0x8 in CFBundleGetIdentifier
/// (crash reports 70 and 71, 0.35.14: two `yab mcp` children of an x86_64
/// `claude`, where Rosetta's slower start widened the gap; natively too,
/// with the app removed 10 ms or more after the start, in
/// scripts/runs/mcp_bundle_gone.py). The main bundle is
/// looked up once and kept, so it is looked up first thing, while the app is
/// whole; if it is not, wait for an app to be back at the same path and start
/// that one, a process of its own that looks again, or leave with a line.
enum LaunchCopy {
    /// Waits up to `patience` seconds for the app to be whole at this
    /// process's own path, then runs that copy in this process's place. A
    /// bare binary (the build folder, a scratch copy) is not checked.
    static func ensure(patience: Double = 10) {
        guard let path = executablePath(), let files = appFiles(executable: path) else { return }
        if whole(files, exists: exists), mainBundleRead() { return }
        let again = getenv(relaunched) != nil
        let deadline = monotonic() + patience
        while monotonic() < deadline {
            usleep(200_000)
            // Whole twice, its size the same, so a copy still being written
            // is not the one started.
            guard whole(files, exists: exists), let size = fileSize(path) else { continue }
            usleep(200_000)
            guard whole(files, exists: exists), fileSize(path) == size, !again else { continue }
            setenv(relaunched, "1", 1)
            execv(path, CommandLine.unsafeArgv)
        }
        let line = "yab: the app this was started from (\(files.app)) was moved or removed while it started, an update perhaps. Start it again.\n"
        fputs(line, stderr)
        exit(75)
    }

    /// Set on the copy started in this one's place, which waits no further.
    static let relaunched = "YAB_LAUNCH_AGAIN"

    struct Files: Equatable {
        let app: String
        let executable: String
        let info: String
    }

    /// The bundle around an executable at `<app>.app/Contents/MacOS/<name>`,
    /// nil for one that is not inside an app.
    static func appFiles(executable path: String) -> Files? {
        guard let range = path.range(of: ".app/Contents/MacOS/", options: .backwards),
              !path[range.upperBound...].isEmpty, !path[range.upperBound...].contains("/")
        else { return nil }
        let app = String(path[..<range.lowerBound]) + ".app"
        return Files(app: app, executable: path, info: app + "/Contents/Info.plist")
    }

    static func whole(_ files: Files, exists: (String) -> Bool) -> Bool {
        exists(files.executable) && exists(files.info)
    }

    /// The path this process was started from, as exec was given it, before
    /// any symlink or bundle lookup.
    private static func executablePath() -> String? {
        var length: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &length)
        guard length > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(length) + 1)
        guard _NSGetExecutablePath(&buffer, &length) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Foundation's main bundle made, and its Info.plist read into it, now:
    /// both are kept for the life of the process, whatever happens to the
    /// files after.
    private static func mainBundleRead() -> Bool {
        guard let bundle: CFBundle = CFBundleGetMainBundle() else { return false }
        return CFBundleGetIdentifier(bundle) != nil
    }

    private static func exists(_ path: String) -> Bool { access(path, F_OK) == 0 }

    private static func monotonic() -> Double { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9 }
}

private func fileSize(_ path: String) -> off_t? {
    var info = stat()
    return stat(path, &info) == 0 ? info.st_size : nil
}
