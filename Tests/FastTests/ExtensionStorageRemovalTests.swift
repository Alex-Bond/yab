import AppKit
import Testing
import WebKit
@testable import Fast

@MainActor
@Suite(.serialized)
struct ExtensionStorageRemovalTests {
    @Test func failedRemovalAllowsLaterInstallAndLoad() async throws {
        try #require(Store.testing)
        _ = NSApplication.shared
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("storage-removal-\(UUID())", isDirectory: true)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        try files.createDirectory(at: Extensions.folder, withIntermediateDirectories: true)
        let id = "removal" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var removals = 0
        let owner = Extensions(signIn: nil, removeStorageData: { _, types, _ in
            #expect(types == [.local, .synchronized])
            removals += 1
            return [CocoaError(.fileWriteUnknown)]
        })
        defer {
            owner.setEnabled(id, false)
            owner.remove(id)
            owner.shutDown()
            try? files.removeItem(at: root)
        }

        func staged() throws -> URL {
            let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            try #"{"manifest_version":3,"name":"Storage removal","version":"1.0"}"#
                .write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
            return folder
        }

        func install(_ staged: URL) async throws -> Bool {
            try await owner.admit(staged, as: id, fromStore: false,
                                  finalFolder: Extensions.folder(for: id), confirm: false, quiet: true,
                                  synced: .init(enabled: true, pinned: false, allowed: []))
        }

        let initial = try await install(staged())
        try #require(initial)
        let oldContext = try #require(owner.contexts[id])
        let storage = try #require(owner.storage(of: id))
        let retained = storage.appendingPathComponent("failed-removal.txt")
        try "Retained by WebKit".write(to: retained, atomically: true, encoding: .utf8)

        owner.remove(id)
        #expect(!oldContext.isLoaded)
        let waiting = try staged()
        var refusal: NSError?
        do { _ = try await install(waiting) }
        catch { refusal = error as NSError }
        try #require(refusal?.domain == NSCocoaErrorDomain)
        #expect(refusal?.code == CocoaError.fileWriteUnknown.rawValue)
        #expect(!files.fileExists(atPath: waiting.path))
        #expect(removals == 1)
        #expect(try String(contentsOf: retained, encoding: .utf8) == "Retained by WebKit")

        // Retry on the same manager, without relaunching or resetting its
        // state. This traverses both admit's barrier and production load.
        let retried = try await install(staged())
        #expect(retried)
        #expect(owner.contexts[id]?.isLoaded == true)
        #expect(owner.contexts[id] !== oldContext)
        #expect(removals == 1)
    }
}
