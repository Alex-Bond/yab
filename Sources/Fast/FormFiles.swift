import AppKit
import SwiftUI
import UniformTypeIdentifiers

// A page's file box opens the field in Files. Its pending WebKit open-panel
// answer belongs only to the tab and origin that asked. Recent folders are
// read away from the main thread; Spotlight runs after typing, and once an
// opening for screenshots saved outside them (Captures).

struct RecentFile: Equatable, Identifiable {
    let url: URL
    /// When it came into its folder, or was last changed.
    let added: Date
    let size: Int
    /// "Downloads", "Desktop".
    let place: String
    /// A screenshot or screen recording: marked by the Mac's screenshot
    /// tool, or named by a screenshot app, and not downloaded.
    var capture = false

    var id: String { url.path }
    var name: String { url.lastPathComponent }

    var glyph: String {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .pdf) || type.conforms(to: .text) || type.conforms(to: .presentation) || type.conforms(to: .spreadsheet) { return "doc.text" }
        return "doc"
    }

    /// "Downloads · 240 KB", the line under its name.
    var detail: String {
        [place, ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)].joined(separator: " · ")
    }
}

enum RecentFiles {
    /// Half-downloaded, or a system's own.
    static let partial: Set<String> = ["download", "crdownload", "part", "partial", "tmp", "opdownload"]

    /// A pasted local path is looked up directly, even outside Spotlight's index.
    static func path(in words: String) -> URL? {
        var text = words.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count >= 2, let first = text.first, first == text.last, first == "\"" || first == "'" {
            text = String(text.dropFirst().dropLast())
        }
        if text.lowercased().hasPrefix("file://") {
            guard let url = URL(string: text), url.isFileURL,
                  url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
            return url.standardizedFileURL
        }
        if text.hasPrefix("~/") { text = home.appendingPathComponent(String(text.dropFirst(2))).path }
        guard text.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: text).standardizedFileURL
    }

    /// Whether a box that takes `accept` takes this file: ".pdf" by its
    /// extension, "image/*" by its kind, "application/pdf" by its type.
    /// A box that says nothing takes anything.
    static func accepts(_ url: URL, _ accept: [String]) -> Bool {
        let wanted = accept.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        guard !wanted.isEmpty else { return true }
        let ext = url.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        for want in wanted {
            if want.hasPrefix(".") {
                if ext == want.dropFirst() { return true }
                continue
            }
            if want.hasSuffix("/*") {
                guard let type else { continue }
                switch want.dropLast(2) {
                case "image": if type.conforms(to: .image) { return true }
                case "video": if type.conforms(to: .movie) || type.conforms(to: .video) { return true }
                case "audio": if type.conforms(to: .audio) { return true }
                case "text": if type.conforms(to: .text) { return true }
                default: break
                }
                continue
            }
            if let type, let asked = UTType(mimeType: want), type.conforms(to: asked) { return true }
        }
        return false
    }

    /// Files at the top of these folders, and those kept from downloads,
    /// each with when it came. Not hidden ones, folders, apps or downloads
    /// still on their way.
    static func look(in folders: [(URL, String)], kept: [URL], spotted: [URL] = []) -> [RecentFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey, .addedToDirectoryDateKey, .contentModificationDateKey, .fileSizeKey]
        func file(_ url: URL, _ place: String) -> RecentFile? {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true, v.isHidden != true,
                  !url.lastPathComponent.hasPrefix("."), !partial.contains(url.pathExtension.lowercased()) else { return nil }
            let added = v.addedToDirectoryDate ?? v.contentModificationDate ?? .distantPast
            return RecentFile(url: url, added: added, size: v.fileSize ?? 0, place: place, capture: captured(url))
        }
        var out: [RecentFile] = []
        for (folder, place) in folders {
            let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            out += urls.compactMap { file($0, place) }
        }
        out += kept.compactMap { file($0, "Downloaded") }
        // Screenshots Spotlight found outside these folders, each under
        // its own folder's name.
        let read = Set(out.map { $0.url.standardizedFileURL.path })
        out += spotted.filter { !read.contains($0.standardizedFileURL.path) }
            .compactMap { file($0, $0.deletingLastPathComponent().lastPathComponent) }
        return out
    }

    /// How screenshot apps name their files: the Mac's own in the languages
    /// it speaks, then CleanShot, Shottr and Xnapper.
    static let shotNames = ["screenshot", "screen shot", "screen recording",
                            "bildschirmfoto", "capture d’écran", "capture d'écran", "captura de pantalla",
                            "schermata", "スクリーンショット", "截屏", "屏幕快照", "스크린샷",
                            "cleanshot", "shottr", "xnapper"]

    /// Whether a file is a screenshot or a screen recording: the mark the
    /// Mac's screenshot tool leaves on it, in any folder and by any name;
    /// else a screenshot app's name, unless it came from the web, where it
    /// is someone else's screenshot, a download.
    static func captured(_ url: URL) -> Bool {
        func has(_ name: String) -> Bool { getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW) >= 0 }
        if has("com.apple.metadata:kMDItemIsScreenCapture") { return true }
        let name = url.lastPathComponent.lowercased()
        guard shotNames.contains(where: { name.hasPrefix($0) }) else { return false }
        return !has("com.apple.metadata:kMDItemWhereFroms") && !has("com.apple.quarantine")
    }

    /// Where the Mac's screenshot tool saves, when that is not Downloads or
    /// the Desktop: the screenshot setting (macOS 27 reads
    /// location-screenshot; older ones location) and the recording one.
    /// None in a test world, which never shows the Mac's own captures.
    /// Read again at most every few seconds: the empty list asks each draw.
    static var shotFolders: [(URL, String)] {
        guard standIn == nil else { return [] }
        let now = Date()
        if let kept = shotLock.withLock({ shotKept }), now.timeIntervalSince(kept.at) < 5 { return kept.folders }
        let folders = readShotFolders()
        shotLock.withLock { shotKept = (now, folders) }
        return folders
    }

    private static let shotLock = NSLock()
    private static var shotKept: (at: Date, folders: [(URL, String)])?

    private static func readShotFolders() -> [(URL, String)] {
        let domain = "com.apple.screencapture" as CFString
        CFPreferencesAppSynchronize(domain)
        func setting(_ key: String) -> String? { CFPreferencesCopyAppValue(key as CFString, domain) as? String }
        let read = [place(.downloadsDirectory), place(.desktopDirectory)].compactMap { $0?.standardizedFileURL.path }
        var out: [URL] = []
        for raw in [setting("location-screenshot") ?? setting("location"), setting("location-screenrecording")].compactMap({ $0 }) {
            let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
            var folder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &folder), folder.boolValue,
                  !read.contains(url.path), url.path != home.standardizedFileURL.path,
                  !out.contains(where: { $0.path == url.path }) else { continue }
            out.append(url)
        }
        return out.map { ($0, $0.lastPathComponent) }
    }

    /// The home Files looks in: the person's own, or a test world's when it
    /// has a Home folder of its own (demos/world.py fills one), so a world
    /// filmed for a demo never shows the Mac's real files. Its Downloads is
    /// the world's own, where a test world's downloads land (Preferences).
    static var standIn: URL? {
        guard Store.testing else { return nil }
        let home = Store.file("Home")
        return FileManager.default.fileExists(atPath: home.path) ? home : nil
    }

    static var home: URL { standIn ?? FileManager.default.homeDirectoryForCurrentUser }

    /// Downloads, Desktop or Documents, in the home Files looks in.
    static func place(_ directory: FileManager.SearchPathDirectory) -> URL? {
        guard let home = standIn else { return FileManager.default.urls(for: directory, in: .userDomainMask).first }
        switch directory {
        case .downloadsDirectory: return Store.folder.appendingPathComponent("Downloads", isDirectory: true)
        case .desktopDirectory: return home.appendingPathComponent("Desktop", isDirectory: true)
        case .documentDirectory: return home.appendingPathComponent("Documents", isDirectory: true)
        default: return nil
        }
    }

    /// A folder as the field's end names it: "Downloads", or its last two
    /// folders under home, "Documents › Invoices".
    static func title(of folder: URL) -> String {
        let home = Self.home.standardizedFileURL.pathComponents
        let parts = folder.standardizedFileURL.pathComponents
        guard parts.count > home.count, Array(parts.prefix(home.count)) == home else { return folder.lastPathComponent }
        return parts.dropFirst(home.count).suffix(2).joined(separator: " › ")
    }

    /// Where a list says its files are: "In Documents", "On the Desktop".
    static func phrase(_ title: String) -> String {
        title == "Desktop" ? "On the Desktop" : "In " + title
    }

    /// Where recent files are looked for.
    static var folders: [(URL, String)] {
        [(place(.downloadsDirectory), "Downloads"), (place(.desktopDirectory), "Desktop")]
            .compactMap { url, place in url.map { ($0, place) } } + shotFolders
    }

    /// The folders as the list says where it looked: "in Downloads, on the
    /// Desktop and in Screenshots", "and" or "or" before the last.
    static func phrase(of folders: [(URL, String)], joined last: String) -> String {
        let places = folders.map { _, title in title == "Desktop" ? "on the Desktop" : "in " + title }
        guard places.count > 1 else { return places.first ?? "" }
        return places.dropLast().joined(separator: ", ") + " \(last) " + places[places.count - 1]
    }
}

/// Screenshots saved somewhere Recent doesn't read: another app's folder,
/// or one the person moved. Spotlight is asked for those of the last two
/// days away from the main thread (it takes about 0.4 s), and what it found
/// is kept for the next opening. A project's folder (in a git checkout),
/// the Library and hidden folders are skipped: captures there are a
/// build's or an app's, not the person's.
enum Captures {
    private static let lock = NSLock()
    private static var found: [URL] = []
    private static var asked = Date.distantPast

    static var last: [URL] { lock.withLock { found } }

    /// Asks Spotlight again, at most every few seconds; whether what it
    /// found changed.
    static func refresh() -> Bool {
        guard RecentFiles.standIn == nil else { return false }
        let now = Date()
        guard lock.withLock({ () -> Bool in
            guard now.timeIntervalSince(asked) > 3 else { return false }
            asked = now
            return true
        }) else { return false }
        let names = RecentFiles.shotNames.map { "kMDItemFSName == \"\($0)*\"cd" }.joined(separator: " || ")
        let text = "(kMDItemIsScreenCapture == 1 || \(names)) && kMDItemDateAdded >= $time.now(-172800)"
        guard let query = MDQueryCreate(kCFAllocatorDefault, text as CFString, nil, nil) else { return false }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        MDQuerySetSearchScope(query, [home.path] as CFArray, 0)
        MDQuerySetMaxCount(query, 60)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return false }
        var urls: [URL] = []
        for index in 0..<MDQueryGetResultCount(query) {
            guard let raw = MDQueryGetResultAtIndex(query, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { continue }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            if mine(url, home: home) { urls.append(url) }
        }
        return lock.withLock {
            let changed = urls != found
            found = urls
            return changed
        }
    }

    private static func mine(_ url: URL, home: URL) -> Bool {
        let parts = url.pathComponents.dropFirst(home.pathComponents.count)
        guard url.path.hasPrefix(home.path + "/"), parts.first != "Library",
              !parts.contains(where: { $0.hasPrefix(".") }) else { return false }
        var folder = url.deletingLastPathComponent()
        while folder.path.count > home.path.count {
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) { return false }
            folder = folder.deletingLastPathComponent()
        }
        return RecentFiles.captured(url)
    }
}

/// The page's unanswered file request, kept only while its tab and origin match.
struct FileQuestion {
    /// The page's frame that asked; none when yab asks for itself (the chat's +).
    let frame: PageFrame?
    let accept: [String]
    let multiple: Bool
    let label: String
}

/// A single Spotlight query per edit. Gathering is asynchronous and is stopped
/// after its first result set; it never runs while the file place is closed.
@MainActor
final class FileSearch {
    private let query = NSMetadataQuery()
    private var observer: NSObjectProtocol?

    func start(_ words: String, accept: [String], in folder: URL? = nil, done: @escaping ([URL]) -> Void) {
        if let url = RecentFiles.path(in: words) {
            DispatchQueue.global(qos: .userInitiated).async {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
                let files = values?.isRegularFile == true && RecentFiles.accepts(url, accept) ? [url] : []
                DispatchQueue.main.async { done(files) }
            }
            return
        }
        if let home = RecentFiles.standIn {
            // A test world's own home isn't where Spotlight looks: its files
            // are walked instead, newest first, as Spotlight would list them.
            let roots = folder.map { [$0] } ?? [home, RecentFiles.place(.downloadsDirectory)].compactMap { $0 }
            DispatchQueue.global(qos: .userInitiated).async {
                let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
                var found: [(URL, Date)] = []
                for root in roots {
                    let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants])
                    while let url = walk?.nextObject() as? URL {
                        guard url.lastPathComponent.range(of: words, options: [.caseInsensitive, .diacriticInsensitive]) != nil,
                              RecentFiles.accepts(url, accept),
                              let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                        found.append((url, values.contentModificationDate ?? .distantPast))
                    }
                }
                let files = found.sorted { $0.1 > $1.1 }.prefix(30).map(\.0)
                DispatchQueue.main.async { done(Array(files)) }
            }
            return
        }
        // Spotlight misses what it hasn't indexed yet (a folder made a
        // minute ago) and what it was told to skip, so the folders people
        // keep files in are also walked by name while it gathers.
        let roots = folder.map { [$0] } ?? Self.walkRoots
        let walked = Walk()
        walked.group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            walked.found = Self.walk(roots, words: words, accept: accept)
            walked.group.leave()
        }
        query.searchScopes = [folder ?? NSMetadataQueryLocalComputerScope]
        query.predicate = Self.predicate(words: words, accept: accept)
        observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let urls = self.query.results.prefix(300).compactMap { ($0 as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey) as? String }
                    .map { URL(fileURLWithPath: $0) }
                self.cancel()
                DispatchQueue.global(qos: .userInitiated).async {
                    let spotted = urls.filter { url in
                        guard RecentFiles.accepts(url, accept), Self.personal(url),
                              let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) else { return false }
                        return values.isRegularFile == true
                    }
                    let files = Self.merge(spotted, walked.wait())
                    DispatchQueue.main.async { done(files) }
                }
            }
        }
        if !query.start() {
            cancel()
            DispatchQueue.global(qos: .userInitiated).async {
                let files = Self.merge([], walked.wait())
                DispatchQueue.main.async { done(files) }
            }
        }
    }

    /// What the walk found, read once it is done.
    private final class Walk: @unchecked Sendable {
        let group = DispatchGroup()
        var found: [URL] = []
        func wait() -> [URL] { group.wait(); return found }
    }

    /// Spotlight's files first, then the walk's it missed; at most 30.
    nonisolated static func merge(_ spotted: [URL], _ walked: [URL]) -> [URL] {
        var seen = Set<String>()
        return Array((spotted + walked).filter { seen.insert($0.standardizedFileURL.path).inserted }.prefix(30))
    }

    /// Where people keep files: Desktop, Downloads, Documents and the
    /// home's own top folders, then mounted drives.
    nonisolated static var walkRoots: [URL] {
        let home = RecentFiles.home
        let places = [RecentFiles.place(.desktopDirectory), RecentFiles.place(.downloadsDirectory),
                      RecentFiles.place(.documentDirectory)].compactMap { $0 }
        let volumes = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "/Volumes"),
                                                                     includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []
        return places + [home] + volumes.filter { (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true }
    }

    /// Not an app's or a build's insides: Library, hidden folders, packages
    /// and dependency folders.
    nonisolated static func personal(_ url: URL) -> Bool {
        let parts = url.standardizedFileURL.pathComponents
        if parts.starts(with: ["/", "System"]) || parts.starts(with: ["/", "Library"]) || parts.starts(with: ["/", "private"])
            || parts.starts(with: ["/", "usr"]) || parts.starts(with: ["/", "Applications"]) || parts.starts(with: ["/", "opt"]) { return false }
        return !parts.dropLast().contains { $0.hasPrefix(".") || skipped.contains($0) || $0.hasSuffix(".app") }
    }

    private nonisolated static let skipped: Set<String> = ["Library", "node_modules", "DerivedData", ".build", "Pods", "build", "dist"]

    /// Files whose names hold every typed word, breadth first so nearer
    /// ones come first; stops after a quarter second or 40,000 entries.
    nonisolated static func walk(_ roots: [URL], words: String, accept: [String]) -> [URL] {
        let parts = words.lowercased().split(separator: " ").map(String.init)
        guard !parts.isEmpty else { return [] }
        let start = Date()
        var seen = Set<String>(), found: [URL] = [], looked = 0
        var level = roots
        for _ in 0..<7 where !level.isEmpty {
            var next: [URL] = []
            for dir in level {
                guard seen.insert(dir.standardizedFileURL.path).inserted,
                      let items = try? FileManager.default.contentsOfDirectory(
                        at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey],
                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                for url in items {
                    looked += 1
                    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey])
                    if values?.isSymbolicLink == true { continue }
                    if values?.isDirectory == true && values?.isPackage != true {
                        if !skipped.contains(url.lastPathComponent) { next.append(url) }
                        continue
                    }
                    let name = url.lastPathComponent.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                    if parts.allSatisfy({ name.contains($0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)) }),
                       values?.isPackage != true, RecentFiles.accepts(url, accept) {
                        found.append(url)
                        if found.count >= 30 { return found }
                    }
                }
                if looked > 40_000 || Date().timeIntervalSince(start) > 0.25 { return found }
            }
            level = next
        }
        return found
    }

    static func predicate(words: String, accept: [String]) -> NSPredicate {
        let parts = words.split(separator: " ").map { NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, String($0)) }
        let name = parts.count == 1 ? parts[0] : NSCompoundPredicate(andPredicateWithSubpredicates: parts)
        let types = accept.compactMap { raw -> NSPredicate? in
            let token = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if token.hasPrefix(".") { return NSPredicate(format: "%K ENDSWITH[cd] %@", NSMetadataItemFSNameKey, token) }
            let type: UTType?
            if token.hasSuffix("/*") {
                switch token.dropLast(2) {
                case "image": type = .image
                case "video": type = .video
                case "audio": type = .audio
                case "text": type = .text
                default: type = nil
                }
            } else { type = UTType(mimeType: token) }
            return type.map { NSPredicate(format: "%K == %@", "kMDItemContentTypeTree", $0.identifier) }
        }
        guard !types.isEmpty else { return name }
        let kind = types.count == 1 ? types[0] : NSCompoundPredicate(orPredicateWithSubpredicates: types)
        return NSCompoundPredicate(andPredicateWithSubpredicates: [name, kind])
    }

    func cancel() {
        query.stop()
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
    }
}

enum FileRows {
    static func matches(_ item: PlaceItem, words: String) -> Bool {
        if let path = RecentFiles.path(in: words) {
            let url: URL
            switch item.what {
            case .file(let file): url = file
            case .kept(let keep): url = keep.url
            default: return false
            }
            return url.standardizedFileURL.path == path.path
        }
        let text = (item.title + " " + item.source + " " + item.search).lowercased()
        return words.lowercased().split(separator: " ").allSatisfy { text.contains($0) }
    }

    /// A screenshot taken in the last five minutes, wherever it was saved.
    static func screenshot(_ file: RecentFile, now: Date) -> Bool {
        file.capture && now.timeIntervalSince(file.added) <= 300
    }

    /// How many of Recent's rows may be screenshots, so a run of them
    /// doesn't push out what was just downloaded.
    static let shotRows = 3

    /// The fast, bounded first list. One path appears once, and a download
    /// from Loot keeps its site and date even when also found in Downloads.
    static func rows(kept: [Keep], recent: [RecentFile], host: String, accept: [String], now: Date) -> [PlaceItem] {
        let known = Dictionary(kept.map { ($0.url.standardizedFileURL.path, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<String> = []
        var out: [PlaceItem] = []
        func add(_ url: URL, section: String, source: String, what: PlaceThing) {
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { return }
            let there = FileManager.default.fileExists(atPath: path)
            out.append(PlaceItem(id: "file." + path, section: section, title: url.lastPathComponent,
                                 source: there ? source : source + " · Moved or deleted", tile: .file(path),
                                 faded: !there, what: what))
        }
        let site = Vault.registrable(host)
        for keep in kept.sorted(by: { $0.date > $1.date }) where now.timeIntervalSince(keep.date) <= 3600 &&
            !site.isEmpty && Vault.registrable(keep.page?.host() ?? keep.from) == site && RecentFiles.accepts(keep.url, accept) {
            add(keep.url, section: "Now", source: "Downloaded from this site " + ago(keep.date, now), what: .kept(keep))
        }
        for file in recent.filter({ screenshot($0, now: now) && RecentFiles.accepts($0.url, accept) }).sorted(by: { $0.added > $1.added }).prefix(1) {
            add(file.url, section: "Now", source: "Taken " + ago(file.added, now), what: known[file.url.standardizedFileURL.path].map(PlaceThing.kept) ?? .file(file.url))
        }
        var shots = 0
        for file in recent.filter({ RecentFiles.accepts($0.url, accept) }).sorted(by: { $0.added > $1.added }) {
            if out.filter({ $0.section == "Recent" }).count >= 8 { break }
            let path = file.url.standardizedFileURL.path
            let keep = known[path]
            if file.capture, keep == nil, !seen.contains(path) {
                guard shots < shotRows else { continue }
                shots += 1
            }
            let source = keep.map { "Downloaded from " + Vault.registrable($0.page?.host() ?? $0.from) + " " + ago($0.date, now) }
                ?? file.place + " · " + ago(file.added, now)
            add(file.url, section: "Recent", source: source, what: keep.map(PlaceThing.kept) ?? .file(file.url))
        }
        return out
    }

    /// Before Recent: what this site was given before, then the files mail
    /// brought in the last two months that are on this Mac (FileShelf).
    static func shelfRows(given: [FileShelf.Upload], mail: [ShelfFile], host: String, accept: [String], now: Date) -> [PlaceItem] {
        var seen: Set<String> = []
        var out: [PlaceItem] = []
        let site = Vault.registrable(host)
        for one in given where RecentFiles.accepts(URL(fileURLWithPath: one.path), accept) && seen.insert(one.path).inserted {
            out.append(PlaceItem(id: "file." + one.path, section: "Sent to \(site) Before", title: one.name,
                                 source: "Sent " + ago(one.date, now), tile: .file(one.path), what: .file(URL(fileURLWithPath: one.path))))
            if out.count >= 3 { break }
        }
        var mailed = 0
        for one in mail where !one.sent && now.timeIntervalSince(one.date) <= 60 * 86_400 {
            guard mailed < 5, let path = one.path, FileManager.default.fileExists(atPath: path),
                  RecentFiles.accepts(URL(fileURLWithPath: path), accept), seen.insert(path).inserted else { continue }
            mailed += 1
            out.append(PlaceItem(id: "file." + path, section: "From Mail", title: one.name,
                                 source: one.said + (one.subject.map { " · " + $0 } ?? ""), tile: .file(path), what: .file(URL(fileURLWithPath: path))))
        }
        return out
    }

    /// Recent's rows, read away from the main thread and handed to `done`
    /// on it; handed to `again` when Spotlight then finds a screenshot
    /// saved somewhere the folders don't cover.
    static func recent(kept: [Keep], host: String, accept: [String],
                       again: @escaping ([PlaceItem]) -> Void, done: @escaping ([PlaceItem]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let folders = RecentFiles.folders
            func read() -> [PlaceItem] {
                rows(kept: kept, recent: RecentFiles.look(in: folders, kept: [], spotted: Captures.last),
                     host: host, accept: accept, now: Date())
            }
            let first = read()
            DispatchQueue.main.async { done(first) }
            guard Captures.refresh() else { return }
            let later = read()
            guard later.map(\.id) != first.map(\.id) else { return }
            DispatchQueue.main.async { again(later) }
        }
    }

    /// A folder's own files, newest first, as many as a list is worth; one
    /// kept from a download keeps its site.
    static func folder(_ found: [RecentFile], kept: [Keep], title: String, accept: [String], now: Date) -> [PlaceItem] {
        let known = Dictionary(kept.map { ($0.url.standardizedFileURL.path, $0) }, uniquingKeysWith: { first, _ in first })
        return found.filter { RecentFiles.accepts($0.url, accept) }.sorted { $0.added > $1.added }.prefix(200).map { file in
            let path = file.url.standardizedFileURL.path
            let keep = known[path]
            let source = keep.map { "Downloaded from " + Vault.registrable($0.page?.host() ?? $0.from) + " " + ago($0.date, now) }
                ?? ago(file.added, now) + " · " + ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)
            return PlaceItem(id: "file." + path, section: RecentFiles.phrase(title), title: file.name, source: source,
                             tile: .file(path), what: keep.map(PlaceThing.kept) ?? .file(file.url))
        }
    }

    static func ago(_ date: Date, _ now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }
}

extension Browser {
    func fileWaiting(for tab: Tab) -> Bool { fileAnswer != nil && fileRequest?.tab == tab.id }

    /// Only ordinary file requests in a non-private tab use the field.
    func offerFiles(_ tab: Tab, _ parameters: PageFilePicker,
                    panel: @escaping (URL?) -> Void, answer: @escaping ([URL]?) -> Void) -> Bool {
        // A second click can arrive while the first folder scan is still in
        // flight. Keep the original request rather than replacing its WebKit
        // completion or opening a second picker over the pending field.
        if fileAnswer != nil && !fieldShowing { answer(nil); return true }
        guard FormFill.on, !Store.settings.bool(forKey: "uploads.finder"), !tab.shy, tab.id == activeID, !fieldShowing,
              !parameters.allowsDirectories, let frame = parameters.frame, let web = tab.builtPage else { return false }
        var settled = false
        if let lifetime = parameters.lifetime {
            guard lifetime.isActive else { return true }
            fileNativeRequest = lifetime
            // Publish ownership before fileSpot's asynchronous callback. A
            // tab switch or another Files flow can cancel this scan now.
            fileRequest = (tab.id, frame)
            fileAnswer = answer
            filePanel = panel
            lifetime.whenCancelled { [weak self, weak lifetime] in
                settled = true
                guard let self, let lifetime, self.fileNativeRequest === lifetime else { return }
                // The native callback is already closed. Its answer wrapper
                // refuses a reply, while Files discards only this request.
                if self.query.place == .files, self.fileRequest?.tab == tab.id { self.dropFiles() }
                else { self.answerFiles(nil) }
            }
        }
        let fallback = { [weak self, weak tab, weak web] in
            guard !settled, parameters.lifetime?.isActive != false else { return }
            settled = true
            if let lifetime = parameters.lifetime, self?.fileNativeRequest === lifetime {
                _ = self?.clearFileAnswer()
            }
            web?.call("window.__yabForm?.fileDone()", in: .yab, frame: frame) { _ in }
            guard let self, let tab, !tab.gone, tab.id == self.activeID,
                  self.tabs.contains(where: { $0.id == tab.id }), let web, web.window != nil,
                  !self.fieldShowing else { answer(nil); return }
            panel(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { fallback() }
        web.call("return window.__yabForm ? window.__yabForm.fileSpot() : null",
                 in: .yab, frame: frame) { [weak self, weak tab] result in
            MainActor.assumeIsolated {
                guard !settled, parameters.lifetime?.isActive != false, let self, let tab, !tab.gone, tab.id == self.activeID,
                      case .success(let value) = result, let info = value as? [String: Any] else { fallback(); return }
                let accept = (info["accept"] as? String ?? "").split(separator: ",").map(String.init)
                let label = (info["label"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let file = FileQuestion(frame: frame, accept: accept, multiple: parameters.allowsMultiple,
                                        label: label.isEmpty ? "File" : label)
                let form = PageForm(tab: tab.id, file: file,
                                    host: self.curtain.host(of: tab.address) ?? "", origin: Tab.originOf(tab.address))
                settled = true
                self.walletLowering?.cancel()
                self.walletList = nil
                self.fileRequest = (tab.id, frame)
                self.fileAnswer = answer
                self.filePanel = panel
                let scanID = UUID()
                self.fileScanID = scanID
                self.fileRowsLoading = true
                self.query.stock.fileRecent = []
                self.query.stock.files = []
                FileRows.recent(kept: self.loot.kept, host: form.host, accept: file.accept, again: { [weak self] rows in
                    guard let self, self.fileScanID == scanID, parameters.lifetime?.isActive != false else { return }
                    self.takeRecentFiles(rows, host: form.host)
                }) { [weak self] rows in
                    guard let self, self.fileScanID == scanID, self.fileAnswer != nil else { return }
                    guard self.activeID == tab.id, !self.fieldShowing || self.query.place == .files else {
                        self.cancelFileAnswer()
                        return
                    }
                    self.fileRowsLoading = false
                    self.query.stock.fileLooks[""] = rows
                    if self.query.stock.fileFolder == nil {
                        self.query.stock.fileRecent = rows
                        self.query.stock.files = rows
                    }
                    self.fileVersion += 1
                    if !self.fieldShowing { self.openFilesPlace(form) }
                }
                // The ring is already on the page. Show a loading state only
                // when reading the folders takes longer than an ordinary open.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
                    guard let self, self.fileScanID == scanID, self.fileRowsLoading,
                          self.fileAnswer != nil else { return }
                    guard self.activeID == tab.id, !self.fieldShowing else {
                        self.cancelFileAnswer()
                        return
                    }
                    self.openFilesPlace(form)
                }
            }
        }
        return true
    }

    /// Yab's own file picker, the field's Files place, for the chat
    /// column: the files picked go with its next message. Browse… there
    /// is the Mac's own panel.
    func pickFiles(label: String = "Add to the chat", _ done: @escaping ([URL]) -> Void) {
        guard let tab = active else { return }
        cancelFileAnswer()
        let file = FileQuestion(frame: nil, accept: [], multiple: true, label: label)
        let form = PageForm(tab: tab.id, file: file, host: curtain.host(of: tab.address) ?? "", origin: Tab.originOf(tab.address))
        fileAnswer = { urls in if let urls, !urls.isEmpty { done(urls) } }
        fileRequest = (tab.id, nil)
        filePanel = { folder in
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            if let folder { panel.directoryURL = folder }
            panel.begin { answer in if answer == .OK { done(panel.urls) } }
        }
        let scanID = UUID()
        fileScanID = scanID
        fileRowsLoading = true
        query.stock.fileRecent = []
        query.stock.files = []
        FileRows.recent(kept: loot.kept, host: form.host, accept: [], again: { [weak self] rows in
            self?.takeRecentFiles(rows, host: form.host)
        }) { [weak self] rows in
            guard let self, self.fileScanID == scanID, self.fileAnswer != nil else { return }
            self.fileRowsLoading = false
            self.query.stock.fileLooks[""] = rows
            if self.query.stock.fileFolder == nil {
                self.query.stock.fileRecent = rows
                self.query.stock.files = rows
            }
            self.fileVersion += 1
        }
        openFilesPlace(form)
    }

    private func openFilesPlace(_ form: PageForm) {
        fileOpening = true
        defer { fileOpening = false }
        openPlace(.files, form: form)
    }

    func askRecentFiles() {
        guard query.place == .files, let file = query.form?.file else { return }
        if let folder = query.stock.fileFolder {
            query.stock.fileLooks[folder.path] = nil
            lookIn(folder)
            return
        }
        let host = query.form?.host ?? ""
        FileShelf.shared.refresh()
        let take: ([PlaceItem]) -> Void = { [weak self] rows in self?.takeRecentFiles(rows, host: host) }
        FileRows.recent(kept: loot.kept, host: host, accept: file.accept, again: take, done: take)
    }

    /// Recent's rows read again, kept under what was typed and found.
    private func takeRecentFiles(_ found: [PlaceItem], host: String) {
        guard query.place == .files, query.form?.host == host else { return }
        let shelf = FileShelf.shared
        let first = FileRows.shelfRows(given: shelf.given(to: host), mail: shelf.mail, host: host, accept: query.form?.file?.accept ?? [], now: Date())
        let firstIDs = Set(first.map(\.id))
        let rows = first + found.filter { !firstIDs.contains($0.id) }
        query.stock.fileLooks[""] = rows
        guard query.stock.fileFolder == nil else { return }
        let searched = query.stock.files.filter { $0.section == "On This Mac" }
        let recentPaths = Set(rows.map(\.id))
        query.stock.fileRecent = rows
        query.stock.files = rows + searched.filter { !recentPaths.contains($0.id) }
        fileVersion += 1
    }

    func askFileSearch() {
        fileSearchWork?.cancel()
        fileSearch?.cancel()
        fileSearch = nil
        guard query.place == .files, let file = query.form?.file else { return }
        query.stock.asked += 1
        query.stock.files = query.stock.fileRecent
        fileVersion += 1
        let words = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard words.count >= 2 else { return }
        let asked = query.stock.asked
        let folder = query.stock.fileFolder
        let section = RecentFiles.path(in: words) == nil
            ? folder.map { RecentFiles.phrase(RecentFiles.title(of: $0)) } ?? "On This Mac"
            : "On This Mac"
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.query.place == .files, self.query.stock.asked == asked else { return }
            let search = FileSearch()
            self.fileSearch = search
            search.start(words, accept: file.accept, in: folder) { [weak self] urls in
                guard let self, self.query.place == .files, self.query.stock.asked == asked else { return }
                let existing = Set(self.query.stock.files.map(\.id))
                let matches = urls.filter { !existing.contains("file." + $0.standardizedFileURL.path) }
                    .prefix(30)
                self.query.stock.files += matches.map { url in
                    PlaceItem(id: "file." + url.standardizedFileURL.path, section: section, title: url.lastPathComponent,
                              source: url.deletingLastPathComponent().lastPathComponent, tile: .file(url.path), what: .file(url))
                }
                self.fileVersion += 1
                self.fileSearch = nil
            }
        }
        fileSearchWork?.cancel()
        fileSearchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    func attachFile(_ url: URL) {
        guard query.place == .files, formTab() != nil, fileAnswer != nil else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { markMissingFiles(); return }
        let selected = fileSelected
        if query.form?.file?.multiple == true, !selected.isEmpty {
            let urls = selected.sorted().map { URL(fileURLWithPath: $0) }
            guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { markMissingFiles(); return }
            finishFiles(urls)
        } else { finishFiles([url]) }
    }

    /// The file picker's existing checked set, through the list's modifier clicks.
    /// It stays separate from PlacePicks' destructive History/Downloads actions.
    func pickFileClick(_ index: Int, flags: NSEvent.ModifierFlags) -> Bool {
        guard query.place == .files, query.form?.file?.multiple == true else { return false }
        let paths = placeItems.map { item -> String? in
            switch item.what {
            case .file(let url): return url.standardizedFileURL.path
            case .kept(let keep): return keep.url.standardizedFileURL.path
            default: return nil
            }
        }
        guard paths.indices.contains(index), paths[index] != nil else { return false }
        let ranged = flags.contains(.shift)
        fileSelected = FilePicks.click(fileSelected, paths: paths, at: index,
                                     anchor: query.pickAnchor ?? query.spot, ranged: ranged)
        if !ranged || query.pickAnchor == nil { query.pickAnchor = ranged ? query.spot : index }
        query.spot = index
        fileVersion += 1
        query.stock.version += 1
        return true
    }

    func toggleFileSelection() -> Bool {
        guard query.place == .files, query.form?.file?.multiple == true, let item = placeItem else { return false }
        let url: URL
        switch item.what {
        case .file(let file): url = file
        case .kept(let keep): url = keep.url
        default: return false
        }
        guard FileManager.default.fileExists(atPath: url.path) else { markMissingFiles(); return true }
        let path = url.standardizedFileURL.path
        if !fileSelected.insert(path).inserted { fileSelected.remove(path) }
        fileVersion += 1
        query.stock.version += 1
        return true
    }

    func finishFiles(_ urls: [URL]) {
        guard formTab() != nil, fileAnswer != nil else { dropFiles(); return }
        guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { markMissingFiles(); return }
        for url in urls { rememberFileFolder(url) }
        FileShelf.shared.gave(urls, to: query.form?.host ?? "")
        answerFiles(urls)
        close()
        if active?.isBlank == false { dismiss() }
    }

    func browseFiles() {
        guard query.place == .files, formTab() != nil, let panel = filePanel else { dropFiles(); return }
        let folder = query.stock.fileFolder
        fileAnswer = nil
        filePanel = nil
        close()
        if active?.isBlank == false { dismiss() }
        panel(folder)
    }

    func cancelFileAnswer() { if query.place == .files || fileRequest != nil || fileAnswer != nil { answerFiles(nil) } }

    private func markMissingFiles() {
        for index in query.stock.files.indices {
            let path: String
            switch query.stock.files[index].what {
            case .file(let url): path = url.path
            case .kept(let keep): path = keep.path
            default: continue
            }
            guard !FileManager.default.fileExists(atPath: path) else { continue }
            query.stock.files[index].faded = true
            if !query.stock.files[index].source.contains("Moved or deleted") {
                query.stock.files[index].source += " · Moved or deleted"
            }
        }
        fileSelected = fileSelected.filter { FileManager.default.fileExists(atPath: $0) }
        fileVersion += 1
        query.stock.version += 1
    }

    func dropFiles() {
        cancelFileAnswer()
        if query.place == .files {
            close()
            if active?.isBlank == false { dismiss() }
        }
    }

    private func answerFiles(_ urls: [URL]?) {
        if let request = fileRequest, let frame = request.frame, let tab = tabs.first(where: { $0.id == request.tab }), let web = tab.builtPage {
            web.call("window.__yabForm?.fileDone()", in: .yab, frame: frame) { _ in }
        }
        let answer = clearFileAnswer()
        answer?(urls)
    }

    /// Detach UI state without answering when handing this exact native
    /// request to its fallback panel. The panel retains its original reply.
    private func clearFileAnswer() -> (([URL]?) -> Void)? {
        let answer = fileAnswer
        fileAnswer = nil
        filePanel = nil
        fileRequest = nil
        fileScanID = nil
        fileNativeRequest = nil
        fileRowsLoading = false
        fileSearchWork?.cancel()
        fileSearch?.cancel()
        fileSearch = nil
        return answer
    }

    static func lastFileFolder(_ host: String) -> URL? {
        let site = Vault.registrable(host)
        guard let path = (Store.settings.dictionary(forKey: "files.folders") as? [String: String])?[site],
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    func rememberFileFolder(_ url: URL) {
        guard let host = query.form?.host, !host.isEmpty else { return }
        Self.rememberFileFolder(url, host: host)
    }

    static func rememberFileFolder(_ url: URL, host: String) {
        guard !host.isEmpty else { return }
        var folders = Store.settings.dictionary(forKey: "files.folders") as? [String: String] ?? [:]
        folders[Vault.registrable(host)] = url.deletingLastPathComponent().path
        Store.settings.set(folders, forKey: "files.folders")
    }

    // MARK: where Files looks

    /// Where Files can be kept to after Recent, in the order ⌘P steps:
    /// Downloads, Desktop, Documents, where screenshots are saved, and the
    /// folder this site's file last came from when it is none of those
    /// (group 2, apart from the rest).
    var fileFolders: [(url: URL, title: String, group: Int)] {
        let fm = FileManager.default
        var out: [(url: URL, title: String, group: Int)] = [(FileManager.SearchPathDirectory.downloadsDirectory, "Downloads"),
                                                            (.desktopDirectory, "Desktop"), (.documentDirectory, "Documents")]
            .compactMap { place, title in RecentFiles.place(place).map { ($0.standardizedFileURL, title, 1) } }
        for (url, title) in RecentFiles.shotFolders where !out.contains(where: { $0.url.path == url.path }) {
            out.append((url, title, 1))
        }
        if let host = query.form?.host, let last = Self.lastFileFolder(host)?.standardizedFileURL,
           !out.contains(where: { $0.url.path == last.path }), last.path != RecentFiles.home.standardizedFileURL.path,
           last.path != fm.homeDirectoryForCurrentUser.standardizedFileURL.path {
            out.append((last, RecentFiles.title(of: last), 2))
        }
        return out
    }

    /// Files kept to a folder, or to Recent again (nil): its own rows, read
    /// away from the main thread once an opening, and what is typed looked
    /// for only there.
    func lookIn(_ folder: URL?) {
        guard query.place == .files, let file = query.form?.file else { return }
        let key = folder?.path ?? ""
        query.stock.fileFolder = folder
        query.spot = 0
        if let rows = query.stock.fileLooks[key] {
            query.stock.fileRecent = rows
            askFileSearch()
            return
        }
        guard let folder else { askRecentFiles(); return }
        let title = RecentFiles.title(of: folder)
        let kept = loot.kept
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = RecentFiles.look(in: [(folder, title)], kept: [])
            let rows = FileRows.folder(found, kept: kept, title: title, accept: file.accept, now: Date())
            DispatchQueue.main.async {
                guard let self, self.query.place == .files else { return }
                self.query.stock.fileLooks[key] = rows
                guard self.query.stock.fileFolder?.path == folder.path else { return }
                self.query.stock.fileRecent = rows
                self.askFileSearch()
            }
        }
    }

    /// ⌘P in Files: the next folder, Recent after the last.
    func cycleFileFolder() -> Bool {
        guard query.place == .files, query.form?.file != nil else { return false }
        let all: [URL?] = [nil] + fileFolders.map(\.url)
        let at = all.firstIndex { $0?.path == query.stock.fileFolder?.path } ?? 0
        lookIn(all[(at + 1) % all.count])
        return true
    }

    /// Where Files can look, as the list's rows: Recent, then each folder
    /// as the Finder draws it, a tick on the one looked in now.
    var fileFolderActions: [FieldAction] {
        let here = query.stock.fileFolder?.path
        var out = [FieldAction(id: "look", title: "Recent", symbol: "yab.clock", checked: here == nil) { self.lookIn(nil) }]
        for folder in fileFolders {
            out.append(FieldAction(id: "look." + folder.url.path, title: folder.title, symbol: "folder", group: folder.group,
                                   image: ActionIcons.file(folder.url), checked: here == folder.url.path) { self.lookIn(folder.url) })
        }
        return out
    }

    func fileActions(_ url: URL) -> [FieldAction] {
        guard query.place == .files else { return [] }
        guard formTab() != nil, fileAnswer != nil else { return [] }
        let there = FileManager.default.fileExists(atPath: url.path)
        var out = [FieldAction(id: "attach", title: "Attach", symbol: "paperclip") { self.attachFile(url) }]
        if there {
            out.append(FieldAction(id: "second", title: "Copy Path", keys: Keymap.shared.text(.fieldSecond), symbol: "yab.copyframe.folder", group: 1) { self.copyPlain(url.path) })
        }
        // In the foot too: the Mac's own panel is one key away from any row.
        out.append(FieldAction(id: "page", title: "Browse this Mac", keys: Keymap.shared.text(.fieldPage), symbol: "yab.folder.search", featured: true, group: 1) { self.browseFiles() })
        return out
    }

    func fileEmpty(words: String) -> PlaceEmpty {
        let browse = FieldAction(id: "page", title: "Browse this Mac", keys: Keymap.shared.text(.fieldPage), symbol: "yab.folder.search") { self.browseFiles() }
        if fileRowsLoading {
            return PlaceEmpty(place: .files, searching: false,
                              title: "Looking " + RecentFiles.phrase(of: RecentFiles.folders, joined: "and") + "…",
                              detail: "The page is ready for a file.", actions: [browse])
        }
        let folder = query.form.flatMap { Self.lastFileFolder($0.host) }
        var actions = [browse]
        if !fileSelected.isEmpty {
            actions.insert(FieldAction(id: "attach", title: "Attach \(fileSelected.count) Files", symbol: "yab.clip") {
                self.finishFiles(self.fileSelected.sorted().map { URL(fileURLWithPath: $0) })
            }, at: 0)
        }
        if let folder {
            actions.append(FieldAction(id: "folder", title: "Open \(folder.lastPathComponent)", symbol: "folder", group: 1) {
                self.close()
                if self.active?.isBlank == false { self.dismiss() }
                NSWorkspace.shared.open(folder)
            })
        }
        if let looked = query.stock.fileFolder {
            let title = RecentFiles.title(of: looked)
            let place = title == "Desktop" ? "on the Desktop" : "in " + title
            return PlaceEmpty(place: .files, searching: !words.isEmpty,
                              title: words.isEmpty ? "Nothing \(place)" : "Nothing for “\(words)” \(place)",
                              detail: "Choose a file from this Mac to attach to the page.", actions: actions)
        }
        return PlaceEmpty(place: .files, searching: !words.isEmpty,
                          title: words.isEmpty ? "Nothing new " + RecentFiles.phrase(of: RecentFiles.folders, joined: "or") : "Nothing for “\(words)”",
                          detail: "Choose a file from this Mac to attach to the page.", actions: actions)
    }
}

/// Only selection values; paths here name rows, never read or grant a file.
enum FilePicks {
    static func click(_ selected: Set<String>, paths: [String?], at index: Int,
                      anchor: Int, ranged: Bool) -> Set<String> {
        guard paths.indices.contains(index), let path = paths[index] else { return selected }
        if ranged {
            let start = max(0, min(anchor, paths.count - 1))
            let range = Set(paths[min(start, index)...max(start, index)].compactMap { $0 })
            // Files checked in another folder remain checked, as with Space.
            return selected.subtracting(paths.compactMap { $0 }).union(range)
        }
        var result = selected
        if !result.insert(path).inserted { result.remove(path) }
        return result
    }
}
