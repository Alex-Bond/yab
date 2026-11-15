import Foundation
import Darwin

/// Local launch provenance, including orderly exits which have no crash report.
/// No URLs, page content, command arguments, or environment values are recorded.
public enum LaunchJournal {
    public static func record(_ event: String, target: URL? = nil, child: pid_t? = nil) {
        guard !Store.unitTests else { return }
        var fields: [String: Any] = ["event": event, "time": Date().timeIntervalSince1970,
            "pid": getpid(), "ppid": getppid(), "testing": Store.testing, "bundle": Bundle.main.bundlePath,
            "executable": Bundle.main.executablePath ?? "", "argv0": CommandLine.arguments.first ?? ""]
        if let target { fields["target"] = target.path }
        if let child { fields["child"] = child }
        guard var data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return }
        data.append(10)
        // One O_APPEND write also permits an app and its helper to record
        // concurrently without either replacing the other's launch history.
        let folder = Store.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fd = open(folder.appendingPathComponent("launches.jsonl").path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        data.withUnsafeBytes { bytes in _ = write(fd, bytes.baseAddress, bytes.count) }
    }
}
