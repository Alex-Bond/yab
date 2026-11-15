import Foundation
import YabCoreClient

// Store extensions in Chromium are installed from the store as Chromium does
// it: the CRX the store signed goes through Chromium's own installer (CEF
// 0021/0022, `extension.installCrx`), so Chromium records it as from the store
// with the store's update_url, and its ExtensionUpdater keeps it current (at
// start and every five hours).
//
// Before, Yab loaded the same package as an unpacked folder carrying the
// store's key. The id was the store's, but Chromium never updates an unpacked
// extension, and Yab's daily check replaced only the WebKit copy: the Chromium
// copies of Claude, ChatGPT and BrowserStack ran a version behind the list.
//
// Those move over once, in place (ChromiumExtensionSync.moveToStoreInstalls):
// the store's current CRX is installed over the unpacked one. Same id, so
// Chromium takes it as an update of that extension: its storage, IndexedDB and
// local storage stay where they are, and so do Chromium's own settings for it
// (allowed in private, site access). Pins and the rest live in the one list.
// Folders a developer loaded stay unpacked, as Chromium keeps them.

enum ChromiumStoreInstalls {
    /// developerPrivate's `location` for each.
    static let unpacked = "UNPACKED", fromStore = "FROM_STORE"

    struct Row: Equatable {
        let id: String
        let version: String
        let location: String
        let path: String?
    }

    /// Loaded unpacked from a store package Yab kept
    /// (`ChromiumPackages/<id>/<digest>`) and in the list as from the store.
    static func toMove(_ rows: [Row], list: [Installed], packages root: String) -> [String] {
        let root = folderPrefix(root)
        let store = Set(list.filter { $0.fromStore && $0.source == nil && ChromiumExtensions.validID($0.id) }.map(\.id))
        return rows.filter { row in
            guard row.location == unpacked, store.contains(row.id), let path = row.path else { return false }
            return standardized(path).hasPrefix(root + row.id + "/")
        }.map(\.id)
    }

    /// The helper's `verifiedCrxInstall` hook. Feature macros arrive as JSON
    /// 0/1 (`@(YABCORE_VERIFIED_CRX)`), not true/false: a check for `true`
    /// alone never saw the installer and loaded every package unpacked.
    static func advertised(_ hook: JSONValue?) -> Bool {
        hook == .bool(true) || hook == .number(1)
    }

    /// What Chrome would do with `next` over `installed`: an update or the
    /// same version is taken, an older one refused (CANT_DOWNGRADE_VERSION).
    static func installs(_ next: String, over installed: String) -> Bool {
        guard let order = compare(next, installed) else { return false }
        return order != .orderedAscending
    }

    /// Store installs the list is ahead of: WebKit's daily check found a
    /// newer version. Chrome is asked to look now rather than at its next
    /// check, once for each version the list names.
    static func behind(_ rows: [Row], list: [Installed]) -> [String] {
        let listed = Dictionary(list.map { ($0.id, $0.version) }, uniquingKeysWith: { first, _ in first })
        return rows.filter { row in
            guard row.location == fromStore, let wanted = listed[row.id] else { return false }
            return compare(wanted, row.version) == .orderedDescending
        }.map { $0.id + "@" + (listed[$0.id] ?? "") }
    }

    /// Store installs Chrome's updater moved past the list's version: the
    /// WebKit copy follows (Extensions.followChromium), once for each.
    static func ahead(_ rows: [Row], list: [Installed]) -> [String] {
        let listed = Dictionary(list.filter { $0.fromStore && $0.source == nil }.map { ($0.id, $0.version) }, uniquingKeysWith: { first, _ in first })
        return rows.filter { row in
            guard row.location == fromStore, let held = listed[row.id] else { return false }
            return compare(row.version, held) == .orderedDescending
        }.map { $0.id + "@" + $0.version }
    }

    /// Store installs Chrome just moved to another version: their worker
    /// file is new, and takes the action hook again.
    static func moved(from before: [Row], to after: [Row]) -> [String] {
        let was = Dictionary(before.map { ($0.id, $0.version) }, uniquingKeysWith: { first, _ in first })
        return after.filter { row in was[row.id].map { $0 != row.version } ?? false }.map(\.id)
    }

    /// Chrome's folder for a store install: `Extensions/ID/VERSION_N` in the
    /// profile, the highest N whose manifest has that version (Chrome adds
    /// one when it puts the same version in again).
    static func installedFolder(root: URL, id: String, version: String) -> URL? {
        guard ChromiumExtensions.validID(id), !version.isEmpty else { return nil }
        let parent = root.appendingPathComponent(id, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        let prefix = version + "_"
        let candidates = names.compactMap { name -> (Int, URL)? in
            guard name.hasPrefix(prefix), let n = Int(name.dropFirst(prefix.count)) else { return nil }
            let folder = parent.appendingPathComponent(name, isDirectory: true)
            guard let manifest = try? ChromiumExtensionPackages.manifest(in: folder), manifest["version"] as? String == version else { return nil }
            return (n, folder)
        }
        return candidates.max { $0.0 < $1.0 }?.1
    }

    /// Where Yab may put the action hook in a worker (ChromiumExtensionPackages.arm):
    /// its own kept packages, and what Chrome installed in the profile.
    static func armable(_ path: String, roots: [String]) -> Bool {
        let path = standardized(path)
        return roots.contains { path.hasPrefix(folderPrefix($0)) }
    }

    /// Chrome's version order (base::Version): numbers split by dots, compared
    /// one by one, missing parts are zero. Nil if either isn't a version.
    static func compare(_ a: String, _ b: String) -> ComparisonResult? {
        func parts(_ text: String) -> [Int]? {
            let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
            guard !pieces.isEmpty, pieces.count <= 4 else { return nil }
            var out: [Int] = []
            for piece in pieces {
                guard !piece.isEmpty, piece.allSatisfy(\.isASCII), piece.allSatisfy(\.isNumber),
                      let value = Int(piece), value <= Int(UInt32.max) else { return nil }
                out.append(value)
            }
            return out
        }
        guard let x = parts(a), let y = parts(b) else { return nil }
        for index in 0..<max(x.count, y.count) {
            let left = index < x.count ? x[index] : 0, right = index < y.count ? y[index] : 0
            if left != right { return left < right ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func folderPrefix(_ root: String) -> String {
        let path = standardized(root)
        return path.hasSuffix("/") ? path : path + "/"
    }
}
