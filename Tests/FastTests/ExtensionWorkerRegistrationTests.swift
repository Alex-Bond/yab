import Foundation
import Testing
@testable import Fast

/// An extension's service worker registration kept from the last launch is
/// dropped before extensions load (Extensions.forgetOrigins); a site's, and
/// everything else the extension's origin keeps, stay.
@Suite struct ExtensionWorkerRegistrationTests {
    let nordPass = "eiaeiblijfjekdanodkjadfinkhbfgcd"

    /// One origin's folder as WebKit lays it out: a salted top origin,
    /// a salted origin in it, and an `origin` file naming both.
    private func origin(_ root: URL, _ top: String, _ name: String, says: String, kinds: [String]) throws -> URL {
        let folder = root.appendingPathComponent(top).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(says.utf8).write(to: folder.appendingPathComponent("origin"))
        for kind in kinds {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(kind), withIntermediateDirectories: true)
        }
        return folder
    }

    @Test func dropsOnlyTheExtensionsWorkerRegistrations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("yab-workers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let mine = try origin(root, "a", "b", says: "\u{10}chrome-extension\u{20}\(nordPass)", kinds: ["ServiceWorkers", "IndexedDB"])
        let other = try origin(root, "c", "d", says: "\u{10}chrome-extension\u{20}aeblfdkhhhdcdjpifhhbdiojplfjncoa", kinds: ["ServiceWorkers"])
        let site = try origin(root, "e", "f", says: "\u{05}https\u{0b}example.com", kinds: ["ServiceWorkers"])
        try Data("salt".utf8).write(to: root.appendingPathComponent("salt"))

        Extensions.forgetOrigins(of: [nordPass], only: "ServiceWorkers", in: root)

        let files = FileManager.default
        #expect(!files.fileExists(atPath: mine.appendingPathComponent("ServiceWorkers").path))
        #expect(files.fileExists(atPath: mine.appendingPathComponent("IndexedDB").path))
        #expect(files.fileExists(atPath: other.appendingPathComponent("ServiceWorkers").path))
        #expect(files.fileExists(atPath: site.appendingPathComponent("ServiceWorkers").path))
    }

    @Test func removedExtensionLeavesNothingUnderItsOrigin() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("yab-workers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let mine = try origin(root, "a", "b", says: "\u{10}chrome-extension\u{20}\(nordPass)", kinds: ["ServiceWorkers", "IndexedDB"])
        let site = try origin(root, "e", "f", says: "\u{05}https\u{0b}example.com", kinds: ["IndexedDB"])

        Extensions.forgetOrigins(of: [nordPass], only: nil, in: root)

        #expect(!FileManager.default.fileExists(atPath: mine.path))
        #expect(FileManager.default.fileExists(atPath: site.path))
    }
}
