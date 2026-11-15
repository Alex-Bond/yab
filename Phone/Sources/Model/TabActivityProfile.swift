import Foundation

/// Public activity only, namespaced by the durable profile identity. Private
/// entries never pass this disk boundary; imported/legacy tabs remain unknown.
@MainActor
final class TabActivityProfile {
    private struct File: Codable, Sendable { let version: Int; let profile: UUID; let entries: [Tab.ID: TabClearPolicy.Activity] }
    private var pending: Task<Void, Never>?
    private var revision = 0
    private let writer: Writer?
    private let profile: UUID?
    private let url: URL?
    private(set) var entries: [Tab.ID: TabClearPolicy.Activity] = [:]
    private(set) var writeFailed = false
    init(profile: BrowserProfile?) {
        self.profile = profile?.dataStoreID
        url = profile?.folder.appendingPathComponent("tab-activity.json")
        writer = url.map { Writer(url: $0) }
        if let id = self.profile, let url, let data = try? Data(contentsOf: url),
           let file = try? JSONDecoder().decode(File.self, from: data), file.version == 1, file.profile == id {
            // Age can survive a launch, local authority cannot. A restored or
            // backed-up ID may already exist on another device. Keep only exact
            // public records in the durable browser snapshot, then revoke.
            let spaces = profile?.snapshot.spaces.filter { !$0.isPrivate } ?? []
            entries = file.entries.filter { id, entry in
                spaces.contains { space in
                    space.id == entry.space && space.tab(id).map { !$0.isPrivate && $0.url == entry.address } == true
                }
            }.mapValues { old in
                var entry = old; entry.localOnly = false; return entry
            }
        }
    }
    func put(_ activity: TabClearPolicy.Activity, for tab: Tab, space: Space) {
        guard !tab.isPrivate && !space.isPrivate else { return }
        entries[tab.id] = activity
    }
    func markShared(_ ids: Set<Tab.ID>) {
        for id in ids where entries[id] != nil { entries[id]?.localOnly = false }
    }
    func save(browser: BrowserStore) {
        guard let profile, let writer else { return }
        let publicIDs = Set(browser.spaces.filter { !$0.isPrivate }.flatMap(\.allTabs).filter { !$0.isPrivate }.map(\.id))
        entries = entries.filter { publicIDs.contains($0.key) }
        let file = File(version: 1, profile: profile, entries: entries)
        revision += 1
        let revision = revision
        pending?.cancel()
        // Activity changes while scrolling. Coalesce them without making a
        // scene transition encode JSON or wait for an atomic disk write.
        pending = Task { [weak self, writer] in
            do { try await Task.sleep(for: .milliseconds(200)) }
            catch { return }
            do {
                try await writer.write(file, revision: revision)
                if self?.revision == revision { self?.writeFailed = false }
            } catch {
                if self?.revision == revision { self?.writeFailed = true }
            }
        }
    }

    /// Included in the scene's existing background-save assertion.
    func flush() async {
        guard let profile, let writer else { return }
        pending?.cancel()
        pending = nil
        revision += 1
        let revision = revision
        let file = File(version: 1, profile: profile, entries: entries)
        do {
            try await writer.write(file, revision: revision)
            if self.revision == revision { writeFailed = false }
        } catch {
            if self.revision == revision { writeFailed = true }
        }
    }

    private actor Writer {
        let url: URL
        var writtenRevision = -1
        init(url: URL) { self.url = url }

        func write(_ file: File, revision: Int) throws {
            guard revision > writtenRevision else { return }
            try JSONEncoder().encode(file).write(to: url, options: .atomic)
            writtenRevision = revision
        }
    }
}
