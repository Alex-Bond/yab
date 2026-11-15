import Foundation

/// Local-only diagnostics, including publication failures after native completion.
/// Paths stay in the private app data directory; nothing is uploaded.
@MainActor
enum DownloadFailureLog {
    static func fields(_ error: Error, destination: URL?, staging: URL?) -> [String: Any] {
        let error = error as NSError
        var result: [String: Any] = ["domain": error.domain, "code": error.code,
                                   "description": error.localizedDescription]
        if let destination { result["destination"] = destination.path }
        if let staging { result["staging"] = staging.path }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            result["underlyingDomain"] = underlying.domain
            result["underlyingCode"] = underlying.code
        }
        return result
    }

    static func note(_ error: Error, destination: URL?, staging: URL?) {
        var record = fields(error, destination: destination, staging: staging)
        record["time"] = Date().timeIntervalSince1970
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        do { try LoadFailureLog.append(data, to: Store.file("download-failures.jsonl")) }
        catch { NSLog("Cannot write download failure diagnostic: %@", error.localizedDescription) }
    }
}
