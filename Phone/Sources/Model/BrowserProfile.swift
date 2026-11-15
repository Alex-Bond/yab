import CryptoKit
import Foundation
import Observation
import os

/// A tab's navigation survives its web view and, for ordinary tabs, a launch.
struct BrowserNavigation: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var url: String
        var title: String
        var scrollY: Double = 0
    }

    var entries: [Entry]
    var index: Int
    var interactionData: Data? = nil
    /// Native state belongs to this website namespace, never another space.
    var websiteStoreID: UUID? = nil
}

/// Visits used by Recent and Frequent. Private pages never enter this list.
struct BrowserVisit: Codable, Equatable, Identifiable, Sendable {
    var url: String
    var title: String
    var site: String
    var icon: String
    var host: String
    var visitedAt: Date
    var count: Int
    /// Visits by part of the day (Suggestions.dayPart), counted from when this came in.
    var parts: [Int]? = nil
    /// It opened from another app.
    var outside: Bool? = nil

    var id: String { url }
}

/// The person's browser, separate from test worlds and sync's journal.
/// The snapshot contains no private tabs, their selection, history or scroll.
@MainActor
@Observable
final class BrowserProfile {
    struct Snapshot: Codable, Equatable, Sendable {
        var version = 1
        var spaces: [Space]
        var spaceID: Space.ID
        var navigation: [Tab.ID: BrowserNavigation] = [:]
        var visits: [BrowserVisit] = []
        /// The Mac's synced places taken out of History here (History/).
        var historyForgetting: HistoryForgetting? = nil

        static func empty() -> Snapshot {
            // No tabs at all: the first launch ends on New Tab's field, and
            // an empty tab would be a page in no one's history.
            let personal = Space(id: BrowserProfile.startSpace, name: "Personal", emoji: "🏠", tint: RGB(238, 233, 226))
            return Snapshot(spaces: [personal], spaceID: personal.id)
        }

        /// Filter at the disk boundary, regardless of which caller changed a tab.
        func excludingPrivate() -> Snapshot {
            var next = self
            next.spaces = spaces.filter { !$0.isPrivate }.map { space in
                var space = space
                space.pins.removeAll(where: \.isPrivate)
                space.today.removeAll(where: \.isPrivate)
                space.kept = KeptTree.excludingPrivate(space.kept)
                if let current = space.current, space.tab(current) == nil {
                    space.current = space.today.first?.id
                }
                return space
            }
            if next.spaces.isEmpty {
                let empty = Self.empty()
                next.spaces = empty.spaces
                next.spaceID = empty.spaceID
            } else if !next.spaces.contains(where: { $0.id == next.spaceID }) {
                next.spaceID = next.spaces[0].id
            }
            let publicTabs = Set(next.spaces.flatMap(\.allTabs).map(\.id))
            next.navigation = navigation.filter { publicTabs.contains($0.key) }
            return next
        }

        var isValid: Bool {
            guard version == 1, !spaces.isEmpty, spaces.contains(where: { $0.id == spaceID }) else { return false }
            var seen = Set<String>()
            for space in spaces {
                guard seen.insert("space:" + space.id).inserted else { return false }
                for tab in space.allTabs where !seen.insert("tab:" + tab.id).inserted { return false }
                if let current = space.current, space.tab(current) == nil { return false }
            }
            return navigation.values.allSatisfy { state in
                state.entries.isEmpty ? state.index == 0 : state.entries.indices.contains(state.index)
            }
        }
    }

    /// The space a new profile starts with (SyncBridge.untouchedStart).
    nonisolated static let startSpace = "local.personal"

    let folder: URL
    /// The saved namespace moves with the profile, even when iOS moves its container.
    /// No persistent store opens until this identity is safely recorded.
    let dataStoreID: UUID?
    private(set) var snapshot: Snapshot
    private(set) var lastWriteError: String?
    @ObservationIgnored private let writer: Writer
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var privateTabIDs = Set<Tab.ID>()
    /// Tabs a link from another app opened: their visits are that app's errand.
    @ObservationIgnored var outsideTabIDs = Set<Tab.ID>()
    @ObservationIgnored private let identityError: String?
    private static let log = Logger(subsystem: "dev.serafim.fast.iphone", category: "profile")

    init(folder: URL) {
        self.folder = folder
        let file = folder.appendingPathComponent("profile.json")
        var preserveExisting = false
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let saved = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file))
                guard saved.isValid else { throw CocoaError(.fileReadCorruptFile) }
                snapshot = saved.excludingPrivate()
            } catch {
                snapshot = .empty()
                preserveExisting = true
                Self.log.error("browser profile could not be read: \(String(describing: error), privacy: .public)")
            }
        } else {
            snapshot = .empty()
        }
        do {
            dataStoreID = try Self.websiteIdentity(in: folder, legacy: FileManager.default.fileExists(atPath: file.path))
            identityError = nil
        } catch {
            dataStoreID = nil
            let message = "Website data identity unavailable: \(String(describing: error))"
            identityError = message
            lastWriteError = message
            Self.log.error("\(message, privacy: .public)")
        }
        writer = Writer(folder: folder, preserveExisting: preserveExisting)
    }

    static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Browser", isDirectory: true)
    }

    /// Test launches never open the person's profile or website data.
    static func launch(_ options: LaunchOptions) -> BrowserProfile {
        let folder: URL
        if let path = options.profileDirectory, !path.isEmpty {
            folder = URL(fileURLWithPath: path, isDirectory: true)
        } else if options.isTestRun {
            folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("YabBrowserTests/\(UUID().uuidString)", isDirectory: true)
        } else {
            folder = defaultFolder
        }
        return BrowserProfile(folder: folder)
    }

    private struct WebsiteIdentity: Codable, Equatable {
        var version = 1
        let dataStoreID: UUID

        var isValid: Bool {
            version == 1 && dataStoreID != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        }
    }

    private static func websiteIdentity(in folder: URL, legacy: Bool) throws -> UUID {
        let file = folder.appendingPathComponent("website-data-store.json")
        if FileManager.default.fileExists(atPath: file.path) {
            let saved = try JSONDecoder().decode(WebsiteIdentity.self, from: Data(contentsOf: file))
            guard saved.isValid else { throw CocoaError(.fileReadCorruptFile) }
            return saved.dataStoreID
        }
        // An existing profile owns the old store derived from this exact path.
        // Already relocated legacy profiles need an independently proven old ID.
        let identity = WebsiteIdentity(dataStoreID: legacy ? legacyDataStoreID(for: folder) : UUID())
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(identity).write(to: file, options: .atomic)
        let saved = try JSONDecoder().decode(WebsiteIdentity.self, from: Data(contentsOf: file))
        guard saved == identity else { throw CocoaError(.fileReadCorruptFile) }
        return saved.dataStoreID
    }

    /// Only used once when migrating an existing profile at its original path.
    private static func legacyDataStoreID(for folder: URL) -> UUID {
        let digest = SHA256.hash(data: Data(("yab-profile:" + folder.standardizedFileURL.path).utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Own sign-ins stay stable across renaming, sync order and container moves.
    /// Shared returns the existing identity exactly; Private has none on disk.
    func websiteStoreID(for space: Space) -> UUID? {
        guard !space.isPrivate, let base = dataStoreID else { return nil }
        guard space.ownSignIns else { return base }
        var input = Data("yab-space-website-store:v1\0".utf8)
        input.append(Data(base.uuidString.lowercased().utf8))
        input.append(0)
        input.append(Data(space.id.utf8))
        let digest = SHA256.hash(data: input)
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// World remains the fixture-compatible bootstrap shape, with no demo data.
    var world: World {
        World(name: "profile", space: snapshot.spaceID, spaces: snapshot.spaces, mac: World.Mac(joined: false))
    }

    var navigation: [Tab.ID: BrowserNavigation] { snapshot.navigation }
    var recent: [BrowserVisit] { snapshot.visits.sorted { $0.visitedAt > $1.visitedAt } }

    var frequent: [BrowserVisit] {
        let sites = Dictionary(grouping: snapshot.visits, by: \.host)
        return sites.values.compactMap { visits in
            guard var latest = visits.max(by: { $0.visitedAt < $1.visitedAt }) else { return nil }
            latest.count = visits.reduce(0) { $0 + $1.count }
            return latest
        }.sorted { $0.count == $1.count ? $0.visitedAt > $1.visitedAt : $0.count > $1.count }
    }

    func capture(_ browser: BrowserStore) {
        privateTabIDs = Set(browser.spaces.flatMap { space in
            space.allTabs.filter { space.isPrivate || $0.isPrivate }.map(\.id)
        })
        var next = snapshot
        next.spaces = browser.spaces
        next.spaceID = browser.spaceID
        next = next.excludingPrivate()
        guard next != snapshot else { return }
        snapshot = next
        save()
    }

    func navigationChanged(_ id: Tab.ID, _ state: BrowserNavigation) {
        guard snapshot.spaces.contains(where: { $0.tab(id) != nil }), state != snapshot.navigation[id] else { return }
        let old = snapshot.navigation[id]
        snapshot.navigation[id] = state
        // Scroll stays current in memory. A page change or background checkpoint
        // saves it without writing the whole profile during every scrolling pause.
        if old?.index != state.index || old?.entries.map({ $0.url + "\n" + $0.title }) != state.entries.map({ $0.url + "\n" + $0.title }) ||
            old?.interactionData != state.interactionData || old?.websiteStoreID != state.websiteStoreID { save() }
    }

    func recordVisit(_ tab: Tab, countsVisit: Bool = true, now: Date = Date()) {
        guard !tab.isPrivate, !privateTabIDs.contains(tab.id), let url = tab.navigationURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        let address = url.absoluteString
        let old = snapshot.visits.first { $0.url == address }
        guard countsVisit || old != nil else { return }
        var parts = old?.parts ?? [0, 0, 0, 0]
        if countsVisit { parts[Suggestions.dayPart(Calendar.current.component(.hour, from: now))] += 1 }
        let visit = BrowserVisit(url: address, title: tab.title, site: tab.site, icon: tab.icon,
                                 host: url.host()?.lowercased() ?? tab.addressHost,
                                 visitedAt: countsVisit ? now : old!.visitedAt,
                                 count: (old?.count ?? 0) + (countsVisit ? 1 : 0), parts: parts,
                                 outside: old?.outside ?? (outsideTabIDs.contains(tab.id) ? true : nil))
        guard visit != old else { return }
        snapshot.visits.removeAll { $0.url == address }
        snapshot.visits.insert(visit, at: 0)
        // A bounded history keeps profile loading and Recent fast.
        if snapshot.visits.count > 2_000 { snapshot.visits.removeLast(snapshot.visits.count - 2_000) }
        save()
    }

    /// Clear History and Website Data (Settings/ClearBrowsingData): the
    /// visits Recent and Frequent come from, and each tab's Back and Forward
    /// down to the page it shows. The tabs themselves stay.
    func clearHistory() {
        snapshot.visits = []
        for (id, var state) in snapshot.navigation {
            guard state.entries.indices.contains(state.index) else { snapshot.navigation[id] = nil; continue }
            state.entries = [state.entries[state.index]]
            state.index = 0
            state.interactionData = nil
            snapshot.navigation[id] = state
        }
        save()
    }

    /// History's Delete and Clear (History/HistoryModel): these visits go.
    func forgetVisits(_ urls: Set<String>) {
        let before = snapshot.visits.count
        snapshot.visits.removeAll { urls.contains($0.url) }
        if snapshot.visits.count != before { save() }
    }

    func setHistoryForgetting(_ value: HistoryForgetting) {
        guard snapshot.historyForgetting != value else { return }
        snapshot.historyForgetting = value
        save()
    }

    private func save() {
        revision += 1
        let revision = revision
        let saved = snapshot.excludingPrivate()
        Task { [weak self, writer] in
            do {
                try await writer.write(saved, revision: revision)
                self?.lastWriteError = self?.identityError
            } catch {
                self?.lastWriteError = String(describing: error)
                Self.log.error("browser profile write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Backgrounding and tests await the final checkpoint rather than a timer.
    func flush() async {
        revision += 1
        do {
            try await writer.write(snapshot.excludingPrivate(), revision: revision)
            lastWriteError = identityError
        } catch {
            lastWriteError = String(describing: error)
            Self.log.error("browser profile flush failed: \(String(describing: error), privacy: .public)")
        }
    }

    private actor Writer {
        let folder: URL
        var writtenRevision = -1
        var preserveExisting: Bool

        init(folder: URL, preserveExisting: Bool) {
            self.folder = folder
            self.preserveExisting = preserveExisting
        }

        func write(_ snapshot: Snapshot, revision: Int) throws {
            guard revision > writtenRevision else { return }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("profile.json")
            if preserveExisting, FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.copyItem(at: file, to: folder.appendingPathComponent("unreadable-\(UUID().uuidString).json"))
                preserveExisting = false
            }
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: file, options: .atomic)
            writtenRevision = revision
        }
    }
}
