import WebKit
import XCTest
@testable import YabPhone

/// A store package opened on the phone (Extensions/ZipReader, ExtensionPackage).
final class ExtensionPackageTests: XCTestCase {
    /// An iPhone opens every package in its temporary folder, which is
    /// /private/var/mobile/...: a folder whose path starts with /private.
    /// The simulator's is under ~/Library, so the test makes one that does.
    private func privateFolder() throws -> URL {
        let temporary = FileManager.default.temporaryDirectory
        let base = temporary.path.hasPrefix("/private/") ? temporary : URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        let folder = base.appendingPathComponent("yab-zip-test-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// Google Translate's package (aapbdbdomjkkjkaonfhkkikfgjllcleb) as the
    /// store sends it, in small: files at the top and in folders, a manifest
    /// V3 with a service worker, every entry stored.
    private let translate: [(String, String)] = [
        ("options_compiled.js", "// options"),
        ("icons/16.png", "png"),
        ("_locales/en/messages.json", #"{"name":{"message":"Google Translate"}}"#),
        ("_locales/zh_CN/messages.json", #"{"name":{"message":"Google 翻译"}}"#),
        ("main_compiled.js", "// worker"),
        ("manifest.json", #"{"manifest_version":3,"name":"__MSG_name__","version":"2.0.16","background":{"service_worker":"main_compiled.js"}}"#),
    ]

    func testAPackageOpensInAFolderUnderPrivate() throws {
        let folder = try privateFolder()
        XCTAssertTrue(folder.path.hasPrefix("/private/"), folder.path)
        try ZipReader.unpack(Self.zip(translate), into: folder)
        for (path, text) in translate {
            XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8), text, path)
        }
    }

    func testTheStoreUnpackGivesTheManifest() throws {
        let folder = try privateFolder()
        try ExtensionPackage.unpack(Self.zip(translate), into: folder)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as? [String: Any]
        XCTAssertEqual(manifest?["manifest_version"] as? Int, 3)
    }

    /// The shim put in front of a worker and its content scripts has every
    /// switch filled in: one left as `__YAB_…__` is a name the worker can't
    /// find, its first line throws and its background never starts
    /// (request 1034: no store extension's did, from 2026-10-10 on).
    func testThePreparedShimLeavesNoSwitchUnfilled() throws {
        let folder = try privateFolder()
        let files = translate + [("content.js", "// content")]
        try ExtensionPackage.unpack(Self.zip(files), into: folder)
        try ExtensionShim.prepare(folder)
        let left = try NSRegularExpression(pattern: "__YAB_[A-Z_]+__")
        for name in ["main_compiled.js", ExtensionShim.file, ExtensionShim.content] {
            let text = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
            XCTAssertTrue(text.contains("yab"), name)
            let found = left.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
            XCTAssertEqual(Set(found), [], name)
        }
    }

    /// Google Translate 2.0.18 as the store sent it on 2026-10-24
    /// (Fixtures/, 73 deflated entries): the
    /// signature checks against its id, it opens in a /private folder as on
    /// a phone, the shim goes in, WebKit reads its manifest and it is
    /// offered as working. Each step is one Add Extension takes (request 895:
    /// "Couldn't open the package" on build 202610222008).
    func testTheStoresGoogleTranslateOpensAsOnAPhone() async throws {
        let id = "aapbdbdomjkkjkaonfhkkikfgjllcleb"
        let crx = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(id).crx"))
        let zip = try ExtensionPackage.verifiedZip(crx, id: id)
        XCTAssertThrowsError(try ExtensionPackage.verifiedZip(crx, id: "dbepggeogbaibhgnhhndojpepiihcmeb"))
        let folder = try privateFolder()
        try ZipReader.unpack(zip, into: folder)
        try ExtensionShim.prepare(folder)
        let found = try await WKWebExtension(resourceBaseURL: folder)
        XCTAssertEqual(found.displayName, "Google Translate")
        XCTAssertEqual(found.version, "2.0.18")
        XCTAssertEqual(ExtensionCompatibility.verdict(id: id, extension: found, entitled: true).kind, .works)
    }

    func testAPathOutOfTheFolderStillRefusesThePackage() throws {
        for bad in ["../evil.js", "icons/../../evil.js", "/etc/evil", "icons\\evil.js", ""] {
            let folder = try privateFolder()
            XCTAssertThrowsError(try ZipReader.unpack(Self.zip([("manifest.json", "{}"), (bad, "x")]), into: folder), bad)
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().appendingPathComponent("evil.js").path))
        }
        let fine = try privateFolder()
        try ZipReader.unpack(Self.zip([("_metadata/verified_contents.json", "[]"), ("a/..b/c.js", "x")]), into: fine)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fine.appendingPathComponent("a/..b/c.js").path))
    }

    /// A zip of stored entries, as a store package lays one out (ZipReader
    /// reads sizes from the central directory and checks no CRC).
    static func zip(_ files: [(String, String)]) -> Data {
        var body = Data(), directory = Data()
        func u16(_ v: Int, _ d: inout Data) { d.append(contentsOf: [UInt8(v & 0xff), UInt8(v >> 8 & 0xff)]) }
        func u32(_ v: Int, _ d: inout Data) { u16(v & 0xffff, &d); u16(v >> 16 & 0xffff, &d) }
        for (path, text) in files {
            let name = Data(path.utf8), bytes = Data(text.utf8), offset = body.count
            u32(0x0403_4b50, &body); u16(20, &body); u16(0x0800, &body); u16(0, &body); u32(0, &body); u32(0, &body)
            u32(bytes.count, &body); u32(bytes.count, &body); u16(name.count, &body); u16(0, &body)
            body.append(name); body.append(bytes)
            u32(0x0201_4b50, &directory); u16(20, &directory); u16(20, &directory); u16(0x0800, &directory); u16(0, &directory)
            u32(0, &directory); u32(0, &directory); u32(bytes.count, &directory); u32(bytes.count, &directory)
            u16(name.count, &directory); u16(0, &directory); u16(0, &directory); u16(0, &directory); u16(0, &directory)
            u32(0, &directory); u32(offset, &directory); directory.append(name)
        }
        var end = Data()
        u32(0x0605_4b50, &end); u16(0, &end); u16(0, &end); u16(files.count, &end); u16(files.count, &end)
        u32(directory.count, &end); u32(body.count, &end); u16(0, &end)
        return body + directory + end
    }
}
