import Foundation
import CryptoKit
import Testing
import YabCoreClient
@testable import Fast

struct ChromiumStoreInstallsTests {
    private func id(_ letter: Character) -> String { String(repeating: letter, count: 32) }
    private let root = "/Users/x/Library/Application Support/Yab/ChromiumPackages"
    private let digest = String(repeating: "0", count: 64)

    private func item(_ letter: Character, version: String = "1.0", store: Bool = true, source: String? = nil) -> Installed {
        Installed(id: id(letter), name: String(letter), version: version, enabled: true, fromStore: store, permissions: [], source: source)
    }

    private func row(_ letter: Character, version: String = "1.0", location: String = ChromiumStoreInstalls.unpacked, path: String? = nil) -> ChromiumStoreInstalls.Row {
        .init(id: id(letter), version: version, location: location, path: path ?? "\(root)/\(id(letter))/\(digest)")
    }

    /// A real, long-used profile on 2026-11-06: store extensions loaded unpacked from
    /// Yab's kept packages move; a developer's folder, one already from the
    /// store and one the list doesn't call a store install stay.
    @Test func onlyStorePackagesLoadedUnpackedMove() {
        let rows = [
            row("a"),                                                                  // Claude, a kept package
            row("b", path: "\(root)/Unpacked/\(id("b"))"),                             // a developer's folder
            row("c", location: ChromiumStoreInstalls.fromStore, path: "/p/Extensions/\(id("c"))/1.0_0"),
            row("d"),                                                                  // listed as a folder install
            row("e", path: "\(root)/\(id("f"))/\(digest)"),                            // another id's package
            ChromiumStoreInstalls.Row(id: id("g"), version: "1", location: ChromiumStoreInstalls.unpacked, path: nil),
            row("h"),                                                                  // not in the list yet
        ]
        let list = [item("a"), item("b", store: false, source: "/src/b"), item("c"), item("d", source: "/src/d"), item("e"), item("g")]
        #expect(ChromiumStoreInstalls.toMove(rows, list: list, packages: root) == [id("a")])
        #expect(ChromiumStoreInstalls.toMove(rows, list: list, packages: root + "/") == [id("a")])
    }

    /// Chrome takes an update or the same version over an unpacked copy and
    /// refuses an older one (CANT_DOWNGRADE_VERSION): those stay as they are.
    @Test func versionsCompareAsChromeDoes() {
        #expect(ChromiumStoreInstalls.installs("1.0.105", over: "1.0.104"))
        #expect(ChromiumStoreInstalls.installs("1.26.1102", over: "1.26.1020"))
        #expect(ChromiumStoreInstalls.installs("1.111.9", over: "1.111.8"))
        #expect(ChromiumStoreInstalls.installs("2.0.0.16", over: "2.0.0.12"))
        #expect(ChromiumStoreInstalls.installs("1.2", over: "1.2.0"))
        #expect(!ChromiumStoreInstalls.installs("1.9", over: "1.10"))
        #expect(!ChromiumStoreInstalls.installs("1.0.104", over: "1.0.105"))
        #expect(!ChromiumStoreInstalls.installs("1.0-beta", over: "1.0"))
        #expect(!ChromiumStoreInstalls.installs("", over: "1.0"))
        #expect(!ChromiumStoreInstalls.installs("1.2.3.4.5", over: "1.0"))
        #expect(ChromiumStoreInstalls.compare("10.0", "9.99") == .orderedDescending)
        #expect(ChromiumStoreInstalls.compare("1.0.0.0", "1") == .orderedSame)
    }

    /// WebKit's daily check moved the list ahead: Chrome is asked once for
    /// that version, and only about its own store installs.
    @Test func chromeIsAskedWhenTheListIsAhead() {
        let rows = [row("a", version: "1.0.104", location: ChromiumStoreInstalls.fromStore),
                    row("b", version: "2.0", location: ChromiumStoreInstalls.fromStore),
                    row("c", version: "1.0", location: ChromiumStoreInstalls.unpacked),
                    row("d", version: "3.1", location: ChromiumStoreInstalls.fromStore)]
        let list = [item("a", version: "1.0.105"), item("b", version: "2.0"), item("c", version: "1.1"), item("d", version: "3.0")]
        #expect(ChromiumStoreInstalls.behind(rows, list: list) == [id("a") + "@1.0.105"])
    }

    /// Chrome's updater moved past the list: WebKit's copy follows, for
    /// store entries only, once per version.
    @Test func webKitFollowsWhenChromeIsAhead() {
        let rows = [row("a", version: "1.0.105", location: ChromiumStoreInstalls.fromStore),
                    row("b", version: "2.0", location: ChromiumStoreInstalls.fromStore),
                    row("c", version: "1.2", location: ChromiumStoreInstalls.unpacked),
                    row("d", version: "3.1", location: ChromiumStoreInstalls.fromStore),
                    row("e", version: "9", location: ChromiumStoreInstalls.fromStore)]
        let list = [item("a", version: "1.0.104"), item("b", version: "2.0"), item("c", version: "1.1"),
                    item("d", version: "3.0", source: "/src/d")]
        #expect(ChromiumStoreInstalls.ahead(rows, list: list) == [id("a") + "@1.0.105"])
    }

    /// developerPrivate gives no path for a store install: Chrome's own
    /// folder is found by version, the last one Chrome put in.
    @Test func chromesFolderIsFoundByVersion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("store-folders-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func put(_ name: String, _ version: String) throws {
            let folder = root.appendingPathComponent(id("a")).appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(#"{"version":"\#(version)"}"#.utf8).write(to: folder.appendingPathComponent("manifest.json"))
        }
        try put("2.0.0.12_0", "2.0.0.12")
        try put("2.0.0.16_0", "2.0.0.16")
        try put("2.0.0.16_1", "2.0.0.16")
        try put("2.0.0.1_0", "2.0.0.1")
        try put("2.0.0.16_2", "9")   // a manifest that says otherwise
        #expect(ChromiumStoreInstalls.installedFolder(root: root, id: id("a"), version: "2.0.0.16")?.lastPathComponent == "2.0.0.16_1")
        #expect(ChromiumStoreInstalls.installedFolder(root: root, id: id("a"), version: "2.0.0.1")?.lastPathComponent == "2.0.0.1_0")
        #expect(ChromiumStoreInstalls.installedFolder(root: root, id: id("a"), version: "3") == nil)
        #expect(ChromiumStoreInstalls.installedFolder(root: root, id: id("b"), version: "2.0.0.16") == nil)
    }

    /// The prior eval's cause: the helper says `verifiedCrxInstall: 1`, and
    /// a check for `true` alone took every store package unpacked.
    @Test func theInstallerIsSeenAsTheHelperSaysIt() {
        #expect(ChromiumStoreInstalls.advertised(.number(1)))
        #expect(ChromiumStoreInstalls.advertised(.bool(true)))
        #expect(!ChromiumStoreInstalls.advertised(.number(0)))
        #expect(!ChromiumStoreInstalls.advertised(.bool(false)))
        #expect(!ChromiumStoreInstalls.advertised(nil))
    }

    /// Chrome's updater put a new version in: that one, and only that one,
    /// takes the hook again. The first read has nothing to compare with.
    @Test func aVersionChromeMovedIsNoticed() {
        let before = [row("a", version: "2.0.0.12"), row("b", version: "1")]
        let after = [row("a", version: "2.0.0.16"), row("b", version: "1"), row("c", version: "5")]
        #expect(ChromiumStoreInstalls.moved(from: before, to: after) == [id("a")])
        #expect(ChromiumStoreInstalls.moved(from: [], to: after).isEmpty)
    }

    @Test func theHookGoesOnlyWhereYabOrChromeInstalled() {
        let profile = "/Users/x/Library/Application Support/Yab/Chromium/space-p/Extensions"
        #expect(ChromiumStoreInstalls.armable("\(profile)/\(id("a"))/2.0.0.16_0", roots: [root, profile]))
        #expect(ChromiumStoreInstalls.armable("\(root)/\(id("a"))/\(digest)", roots: [root, profile]))
        #expect(!ChromiumStoreInstalls.armable("/Users/x/dev/my-extension", roots: [root, profile]))
        #expect(!ChromiumStoreInstalls.armable("\(profile)/../../space-q/Extensions/\(id("a"))/1_0", roots: [root, profile]))
        #expect(!ChromiumStoreInstalls.armable(profile + "-other/x", roots: [root, profile]))
    }

    /// The signed file is kept beside the folder made from it, and found
    /// again only while it is the same bytes.
    @Test func theStoreFileIsKeptBesideItsPackage() throws {
        let vimium = "dbepggeogbaibhgnhhndojpepiihcmeb"
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("evals/extensions/frozen-vimium/dbepggeogbaibhgnhhndojpepiihcmeb-3198c26aa719be462dea585050fbed9b8b80628d57ea88a113babf5334c5517c.crx")
        let crx = try Data(contentsOf: fixture)
        let packages = FileManager.default.temporaryDirectory.appendingPathComponent("store-installs-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: packages) }
        let folder = try ChromiumExtensionPackages.prepare(crx, id: vimium, root: packages)
        let original = try #require(ChromiumExtensionPackages.original(of: folder, id: vimium))
        #expect(try Data(contentsOf: original) == crx)
        #expect(original.lastPathComponent == folder.lastPathComponent + ".crx")
        #expect(ChromiumExtensionPackages.original(of: folder, id: id("a")) == nil)
        // The newest kept package is still the folder, never the file.
        #expect(ChromiumExtensionPackages.existing(vimium, root: packages)?.standardizedFileURL == folder.standardizedFileURL)
        // A package kept before the file was: prepared again, it gets one.
        try FileManager.default.removeItem(at: original)
        #expect(ChromiumExtensionPackages.original(of: folder, id: vimium) == nil)
        #expect(try ChromiumExtensionPackages.prepare(crx, id: vimium, root: packages) == folder)
        #expect(ChromiumExtensionPackages.original(of: folder, id: vimium) != nil)
        // Changed bytes are not the store's.
        var changed = crx
        changed[changed.count - 1] ^= 1
        try changed.write(to: original)
        #expect(ChromiumExtensionPackages.original(of: folder, id: vimium) == nil)
    }
}
