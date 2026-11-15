import Foundation
import WebKit

/// A logical WebKit sign-in and a physical CEF directory are independent.
/// Unknown old directories are quarantined, never attached to today's store.
@MainActor
enum ChromiumPersistentProfiles {
    enum Refused: Error { case unverifiedAssociation, candidateAlreadyExists }
    struct Plan: Equatable {
        let logical: UUID
        let aliases: Set<UUID>
        let existing: Set<UUID>
        let associated: Set<UUID>
        let fresh: UUID
        init(logical: UUID, aliases: Set<UUID>, existing: Set<UUID>, associated: Set<UUID> = [], fresh: UUID = UUID()) {
            self.logical = logical; self.aliases = aliases
            self.existing = existing
            self.associated = associated.intersection(existing)
            self.fresh = fresh
        }
        var primary: UUID {
            if associated.contains(logical) { return logical }
            if let known = associated.sorted(by: { $0.uuidString < $1.uuidString }).first { return known }
            return existing.contains(logical) ? fresh : logical
        }
        var needsMerge: Bool { !existing.subtracting([primary]).isEmpty }
        var quarantined: Set<UUID> { existing.subtracting(associated) }
        func physical(for placement: UUID) -> UUID { primary }
    }
    private struct Key: Hashable { let root: String; let logical: UUID; let shared: Bool }
    private struct Association: Codable {
        let version: Int
        let logical: UUID
        let shared: Bool
        let physical: UUID
        let provenance: String
        let generation: String
    }
    private final class Record {
        let key: Key
        let plan: Plan
        let receipt: URL
        let generation: String
        var authorized: Bool
        var claimed = false
        init(key: Key, plan: Plan, receipt: URL, generation: String, authorized: Bool) {
            self.key = key; self.plan = plan; self.receipt = receipt; self.generation = generation; self.authorized = authorized
        }
    }
    private static var records: [Key: Record] = [:]
    // Input asks for the endpoint on every wheel/pointer event. A live store
    // already has a resolved association; migration discovery is not input
    // work. Weak keys do not keep a closed website store alive. Retirement
    // removes its Record from `records`, invalidating this shortcut as well.
    private static let liveRecords = NSMapTable<WKWebsiteDataStore, Record>.weakToStrongObjects()

    private static func record(for store: WKWebsiteDataStore) -> Record {
        precondition(store.isPersistent)
        if let record = liveRecords.object(forKey: store), records[record.key] === record { return record }
        let sharedStore = Store.websites
        let shared = store === sharedStore || store.identifier == sharedStore.identifier
        let logical = shared ? Space.firstID : (store.identifier ?? Space.firstID)
        let root = Store.file("Chromium"), metadata = Store.file("ChromiumImports")
        let key = Key(root: root.path, logical: logical, shared: shared)
        if let record = records[key] {
            liveRecords.setObject(record, forKey: store)
            return record
        }
        // Aliases discover legacy data once. Adding/moving a space cannot
        // reinterpret an association already used by this logical store.
        let aliases: Set<UUID> = shared
            ? Set(Spaces.read().filter { !$0.ownSignIns }.map(\.id)).union(Spaces.sharing)
                .union([Space.firstID, Space.mailID, Space.pinsID]) : [logical]
        let receipt = Store.file("ChromiumProfiles").appendingPathComponent(logical.uuidString + (shared ? "-shared" : "-named") + ".json")
        let generation = Store.settings.string(forKey: "chromium.profile.generation." + logical.uuidString) ?? "initial"
        var existing = Set(aliases.filter {
            FileManager.default.fileExists(atPath: root.appendingPathComponent("space-" + $0.uuidString).path)
            || FileManager.default.fileExists(atPath: metadata.appendingPathComponent($0.uuidString + ".json").path)
        })
        var associated: Set<UUID> = []
        if let data = try? Data(contentsOf: receipt), data.count <= 65_536,
           let state = try? JSONDecoder().decode(Association.self, from: data),
           state.version == 2, state.logical == logical, state.shared == shared, state.generation == generation,
           ["fresh", "verified-migration"].contains(state.provenance),
           FileManager.default.fileExists(atPath: root.appendingPathComponent("space-" + state.physical.uuidString).path) {
            associated.insert(state.physical); existing.insert(state.physical)
        }
        // Spaces.store(for:) always maps these three special stores to the
        // shared store and Spaces.erase excludes them; no mutable space ID is
        // trusted merely because it equals today's WK identifier.
        if shared { associated.formUnion(existing.intersection([Space.firstID, Space.mailID, Space.pinsID])) }
        var fresh = UUID()
        while FileManager.default.fileExists(atPath: root.appendingPathComponent("space-" + fresh.uuidString).path) { fresh = UUID() }
        let plan = Plan(logical: logical, aliases: aliases, existing: existing, associated: associated, fresh: fresh)
        let record = Record(key: key, plan: plan, receipt: receipt, generation: generation, authorized: associated.contains(plan.primary))
        records[key] = record
        liveRecords.setObject(record, forKey: store)
        return record
    }
    static func plan(for store: WKWebsiteDataStore) -> Plan { record(for: store).plan }
    static func profile(store: WKWebsiteDataStore, placement: UUID) -> String { record(for: store).plan.primary.uuidString }
    static func profile(for browser: Browser) -> String { profile(store: Spaces.store(for: browser.spaceID), placement: browser.spaceID) }

    /// Required BEFORE constructing cookie/extension bridges or opening CEF.
    /// A new context is claimed and journaled before it can receive any data.
    static func authorize(_ profile: String, store: WKWebsiteDataStore) throws {
        guard store.isPersistent else { throw Refused.unverifiedAssociation }
        let record = record(for: store)
        guard profile == record.plan.primary.uuidString else { throw Refused.unverifiedAssociation }
        if record.authorized { return }
        let manager = FileManager.default
        let directory = URL(fileURLWithPath: record.key.root).appendingPathComponent("space-" + profile)
        if !record.claimed {
            guard !manager.fileExists(atPath: directory.path) else { throw Refused.candidateAlreadyExists }
            try manager.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            record.claimed = true
        }
        try manager.createDirectory(at: record.receipt.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        if manager.fileExists(atPath: record.receipt.path) {
            try manager.moveItem(at: record.receipt, to: record.receipt.appendingPathExtension("retired-" + UUID().uuidString))
        }
        let association = Association(version: 2, logical: record.plan.logical, shared: record.key.shared,
                                      physical: record.plan.primary, provenance: "fresh", generation: record.generation)
        try JSONEncoder().encode(association).write(to: record.receipt, options: [.atomic])
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: record.receipt.path)
        record.authorized = true
    }

    private static let erasingKey = "chromium.profiles.erasing"

    /// A deleted space's Chromium folder goes with its sign-ins. A loaded
    /// profile keeps its files open, so the folder is removed while no helper
    /// runs: at the next launch, or before the next helper starts.
    static func sweepErased() {
        guard ChromiumProcess.shared.processID == nil else { return }
        let waiting = Store.settings.stringArray(forKey: erasingKey) ?? []
        guard !waiting.isEmpty else { return }
        let manager = FileManager.default
        // A ledger is named by the physical folder and the logical store, and
        // the two differ when the space's own id was taken: every pair of
        // the ids waiting, so both are found.
        let ids = waiting.compactMap(UUID.init(uuidString:))
        for physical in ids {
            for logical in ids {
                try? manager.removeItem(at: ChromiumSwitchCookieLedger.file(profile: physical.uuidString, store: logical))
                try? manager.removeItem(at: EngineStorageCarry.ledger(profile: physical.uuidString, store: logical))
            }
        }
        let left = waiting.filter { name in
            guard let id = UUID(uuidString: name) else { return false }
            let folder = Store.file("Chromium").appendingPathComponent("space-" + id.uuidString)
            try? manager.removeItem(at: Store.file("ChromiumImports").appendingPathComponent(id.uuidString + ".json"))
            // Chrome keeps a profile's HTTP and code caches under ~/Library/Caches.
            if let caches = manager.urls(for: .cachesDirectory, in: .userDomainMask).first {
                try? manager.removeItem(at: caches.appendingPathComponent(Store.name).appendingPathComponent("Chromium/space-" + id.uuidString))
            }
            guard manager.fileExists(atPath: folder.path) else { return false }
            do { try manager.removeItem(at: folder); return false } catch { return true }
        }
        Store.settings.set(left, forKey: erasingKey)
    }

    /// Erasing/recreating a WK store must not revive its old native sign-ins.
    static func retireAssociation(_ logical: UUID) {
        // The space's own id, and the folder its receipt names when that id was taken.
        var folders: Set<UUID> = [logical]
        let named = Store.file("ChromiumProfiles").appendingPathComponent(logical.uuidString + "-named.json")
        if let data = try? Data(contentsOf: named), let state = try? JSONDecoder().decode(Association.self, from: data) {
            folders.insert(state.physical)
        }
        let erasing = Set(Store.settings.stringArray(forKey: erasingKey) ?? []).union(folders.map(\.uuidString))
        Store.settings.set(erasing.sorted(), forKey: erasingKey)
        ChromiumDRMCookies.retireStore(logical)
        ChromiumDRMExtensionSession.retireStore(logical)
        Store.settings.set(UUID().uuidString, forKey: "chromium.profile.generation." + logical.uuidString)
        records = records.filter { $0.key.logical != logical || $0.key.shared }
        let receipt = Store.file("ChromiumProfiles").appendingPathComponent(logical.uuidString + "-named.json")
        guard FileManager.default.fileExists(atPath: receipt.path) else { return }
        do { try FileManager.default.moveItem(at: receipt, to: receipt.appendingPathExtension("retired-" + UUID().uuidString)) }
        catch { DebugLog.note("profile-association", ["error": String(describing: error)]) }
    }
}
