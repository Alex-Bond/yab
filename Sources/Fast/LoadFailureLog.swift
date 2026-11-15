import Foundation

/// Bounded local page-load diagnostics, separate from native crash reporting.
/// Never retain a URL, page text, or the engine's free-form error description.
@MainActor
enum LoadFailureLog {
    static func token(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 80,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 58, 95].contains($0) }) else { return nil }
        return value
    }

    static func safeHost(_ value: String?) -> String? {
        guard let value, value.utf8.count <= 253, !value.isEmpty,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 58, 91, 93].contains($0) }) else { return nil }
        return value.lowercased()
    }

    static func fields(engine: PageEngineKind, domain: String, code: Int?, host: String?, name: String?, version: String) -> [String: Any] {
        var fields: [String: Any] = ["engine": engine.rawValue, "domain": token(domain) ?? "unknown", "version": version]
        if let code { fields["code"] = code }
        if let host = safeHost(host) { fields["host"] = host }
        if let name = token(name), name.hasPrefix("net::ERR_") || name.hasPrefix("ERR_") { fields["name"] = name }
        else if domain == "net", let code, let name = PageLoadFailure.netNames[code] {
            fields["name"] = "net::" + name
        }
        else if domain == NSURLErrorDomain, let code {
            let names = [NSURLErrorTimedOut: "NSURLErrorTimedOut", NSURLErrorCannotFindHost: "NSURLErrorCannotFindHost",
                         NSURLErrorCannotConnectToHost: "NSURLErrorCannotConnectToHost", NSURLErrorNetworkConnectionLost: "NSURLErrorNetworkConnectionLost",
                         NSURLErrorDNSLookupFailed: "NSURLErrorDNSLookupFailed", NSURLErrorNotConnectedToInternet: "NSURLErrorNotConnectedToInternet",
                         NSURLErrorSecureConnectionFailed: "NSURLErrorSecureConnectionFailed", NSURLErrorServerCertificateUntrusted: "NSURLErrorServerCertificateUntrusted"]
            fields["name"] = names[code] ?? "NSURLError"
        }
        return fields
    }

    static func append(_ data: Data, to file: URL) throws {
        // URL resource values are cached: reusing a URL after appending must
        // query the current inode size, or rotation never notices growth.
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber
        if (size?.intValue ?? 0) > 1_048_576 {
            let previous = file.appendingPathExtension("previous")
            try? FileManager.default.removeItem(at: previous)
            try FileManager.default.moveItem(at: file, to: previous)
        }
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data + Data([10]))
    }

    static func note(engine: PageEngineKind, domain: String, code: Int?, host: String?, name: String? = nil) {
        let fields = fields(engine: engine, domain: domain, code: code, host: host, name: name, version: Updater.version)
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return }
        NSLog("Load failed: %@", String(decoding: data, as: UTF8.self))
        try? append(data, to: Store.file("load-failures.jsonl"))
    }

    static func host(_ address: String?) -> String? {
        address.flatMap(URL.init(string:))?.host
    }
}
