import Foundation

/// Disk transactions are separate from WebKit. A bad trial never replaces a
/// kept version, and history remains usable without loading any page code.
struct BoostRecord: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var sites: [String]
    var rung: BoostPackage.Rung
    var intent: String
    var author: String
    var session: String
    var enabled: Bool = true
    var profiles: AddonProfiles? = nil
    var revision: String
    var updated: Date
    var repairs: Int? = nil
    var failures: Int = 0
    var lastCheck: Date? = nil
    var lastProblem: String? = nil
    var digest: String? = nil
    /// The device whose service ticks run it (SyncCenter.device): with
    /// sync, every Mac keeps the plugin and only this one ticks it. Nil:
    /// whichever has it.
    var runsOn: String? = nil
    /// Code (Page and higher) that came from another Mac and this one never
    /// said yes to: kept off here, and the account's on or off left as it
    /// is, until the person turns it on here (docs/sync.md, "Putting in").
    var waits: Bool? = nil
    /// Whether this Mac is the one to tick it: always, while it doesn't
    /// sync plugins (sync off, or Extensions and plugins off); else only
    /// when the account says so (SyncMirror mirrors `runsOn`).
    var runsHere: Bool { runs(on: SyncCenter.deviceID, syncing: SyncAddons.active) }

    func runs(on device: String, syncing: Bool) -> Bool {
        if let profiles, !profiles.contains(nil) { return true }
        return !syncing || runsOn == device
    }
}

struct BoostRevision: Codable, Identifiable {
    let id: String
    let date: Date
    let intent: String
    let files: [String: String]
    let sites: [String]
}

struct BoostLibrary {
    let root: URL
    var index: URL { root.appendingPathComponent("index.json") }
    func folder(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    func records() throws -> [BoostRecord] {
        guard FileManager.default.fileExists(atPath: index.path) else { return [] }
        return try JSONDecoder().decode([BoostRecord].self, from: Data(contentsOf: index))
    }
    func save(_ records: [BoostRecord]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: index, options: .atomic)
    }
    func files(_ id: String) throws -> [String: String] {
        guard id == BoostPackage.slug(id), !id.isEmpty else { throw BoostPackage.Invalid("Invalid boost name.") }
        let files = try read(folder(id))
        if let record = try records().first(where: { $0.id == id }), let expected = record.digest {
            let payload = BoostShare.Payload(format: 1, id: id, sites: record.sites, files: files)
            guard try BoostShare.digest(payload) == expected else { throw BoostPackage.Invalid("Saved files changed outside Keep. Restore a version or make a new trial.") }
        }
        return files
    }
    func read(_ directory: URL) throws -> [String: String] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw BoostPackage.Invalid("Boost folders cannot be symbolic links.") }
        var result: [String: String] = [:]
        var bytes = 0
        func visit(_ folder: URL, prefix: String, depth: Int) throws {
            guard depth <= 8 else { throw BoostPackage.Invalid("Boost folders may be at most eight levels deep.") }
            // Enumerators can silently return no entries after an I/O error.
            // Explicit directory reads propagate failures, and relative names
            // never depend on /var versus /private/var URL canonicalization.
            let children = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys), options: [])
            for file in children {
                if file.lastPathComponent == ".DS_Store" { continue }
                let path = prefix + file.lastPathComponent
                let info = try file.resourceValues(forKeys: keys)
                guard BoostPackage.validPath(path), info.isSymbolicLink != true else { throw BoostPackage.Invalid("Boost folders cannot contain hidden paths or symbolic links.") }
                if info.isDirectory == true { try visit(file, prefix: path + "/", depth: depth + 1); continue }
                guard info.isRegularFile == true, (info.fileSize ?? 0) <= 512_000, result.count < 32 else { throw BoostPackage.Invalid("This boost contains an invalid or oversized file.") }
                let text = try String(contentsOf: file, encoding: .utf8)
                bytes += text.utf8.count
                guard bytes <= 512_000 else { throw BoostPackage.Invalid("A boost may contain at most 512 KB.") }
                result[path] = text
            }
        }
        try visit(directory, prefix: "", depth: 0)
        return result
    }
    func write(_ files: [String: String], to destination: URL) throws {
        _ = try BoostPackage.merge(files.mapValues { $0 as Any }, into: [:])
        let fm = FileManager.default
        let staging = root.appendingPathComponent(".write-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        for (path, text) in files {
            let file = staging.appendingPathComponent(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = root.appendingPathComponent(".backup-" + UUID().uuidString)
        let existed = fm.fileExists(atPath: destination.path)
        if existed { try fm.moveItem(at: destination, to: backup) }
        do { try fm.moveItem(at: staging, to: destination) }
        catch { if existed { try? fm.moveItem(at: backup, to: destination) }; throw error }
        if existed { try? fm.removeItem(at: backup) }
    }
    func history(_ id: String) -> [BoostRevision] {
        guard id == BoostPackage.slug(id), !id.isEmpty else { return [] }
        let path = root.appendingPathComponent(".history/" + id)
        return ((try? FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil)) ?? [])
            .compactMap { try? JSONDecoder().decode(BoostRevision.self, from: Data(contentsOf: $0)) }
            .sorted { $0.date > $1.date }
    }
    func keep(_ package: BoostPackage, author: String, session: String, enabled: Bool = true, waits: Bool = false,
              runsOn: String? = nil, profiles: AddonProfiles? = nil) throws -> BoostRecord {
        var records = try records()
        let old = try? files(package.id)
        let revision = BoostRevision(id: UUID().uuidString, date: Date(), intent: package.intent, files: package.files, sites: package.sites)
        let historyFolder = root.appendingPathComponent(".history/" + package.id)
        try FileManager.default.createDirectory(at: historyFolder, withIntermediateDirectories: true)
        try JSONEncoder().encode(revision).write(to: historyFolder.appendingPathComponent(revision.id + ".json"), options: .atomic)
        var record = BoostRecord(id: package.id, name: package.name, sites: package.sites, rung: package.rung,
                                 intent: package.intent, author: author, session: session, revision: revision.id, updated: revision.date, digest: try BoostShare.digest(.init(format: 1, id: package.id, sites: package.sites, files: package.files)))
        // A new version keeps ticking where the last one did, unless told where.
        record.runsOn = runsOn ?? records.first { $0.id == package.id }?.runsOn
        record.enabled = enabled
        record.profiles = profiles ?? records.first { $0.id == package.id }?.profiles ?? AddonProfiles(signIn: nil, enabled: enabled)
        if waits { record.waits = true }
        do { try write(package.files, to: folder(package.id)) }
        catch { try? FileManager.default.removeItem(at: historyFolder.appendingPathComponent(revision.id + ".json")); throw error }
        records.removeAll { $0.id == package.id }; records.append(record)
        do { try save(records) }
        catch {
            try? FileManager.default.removeItem(at: historyFolder.appendingPathComponent(revision.id + ".json"))
            if let old { try? write(old, to: folder(package.id)) }
            else { try? FileManager.default.removeItem(at: folder(package.id)) }
            throw error
        }
        return record
    }
    func delete(_ id: String) throws {
        var records = try records()
        guard records.contains(where: { $0.id == id }) else { return }
        records.removeAll { $0.id == id }
        // Remove it from the loading index first. A leftover folder is inert.
        try save(records)
        try FileManager.default.removeItem(at: folder(id))
    }
}
