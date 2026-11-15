import Foundation
import Testing
@testable import Fast

@Suite(.serialized)
@MainActor
struct ChromiumExtensionImportTests {
    private func item(_ letter: String, enabled: Bool = false, pinned: Bool = true) -> Installed {
        Installed(id: String(repeating: letter, count: 32), name: letter, version: "1",
                  enabled: enabled, fromStore: true, permissions: [], pinned: pinned)
    }

    @Test func partialFailureContinuesAndRetryRepairsWithoutReinstalling() async throws {
        let a = item("a"), b = item("b")
        var pending = Set<String>(), loaded = Set<String>(), pins: [String] = []
        var writes: [String] = []
        let first = try await ChromiumExtensionImport.run([a, b], installed: [], pending: [],
            journal: { pending = $0 }, install: { loaded.insert($0.id) },
            enable: { id, enabled in
                #expect(!enabled)
                if id == a.id { throw CocoaError(.fileWriteUnknown) }
                writes.append(id)
            }, remember: { pins = ChromiumExtensionImport.pins(pins, remembering: $0, order: [a, b]) })
        #expect(first.map(\.state) == [.failed, .imported])
        #expect(loaded == [a.id, b.id])
        #expect(pending == [a.id])
        #expect(pins == [b.id])
        let resumed = try await ChromiumExtensionImport.run([a, b], installed: loaded, pending: pending,
            journal: { pending = $0 }, install: { _ in Issue.record("Retry reinstalled native code") },
            enable: { id, _ in writes.append(id) },
            remember: { pins = ChromiumExtensionImport.pins(pins, remembering: $0, order: [a, b]) })
        #expect(resumed.map(\.state) == [.imported, .existing])
        #expect(pending.isEmpty)
        #expect(writes == [b.id, a.id])
        #expect(pins == [a.id, b.id])
    }

    @Test func existingNativeStateIsNotOverwrittenAndLocalFoldersAreExplicit() async throws {
        let a = item("a")
        var local = item("b")
        local = Installed(id: "local-original", name: "Local", version: "1", enabled: false,
                          fromStore: false, permissions: [], pinned: true, source: "/original/folder")
        let results = try await ChromiumExtensionImport.run([a, a, local], installed: [a.id], pending: [],
            journal: { _ in Issue.record("Existing/local item started a migration") },
            install: { _ in Issue.record("Unexpected package load") },
            enable: { _, _ in Issue.record("Existing native state overwritten") },
            remember: { _ in Issue.record("Existing pin overwritten") })
        #expect(results.map(\.state) == [.existing, .blocked])
        #expect(results.last?.detail?.contains("original local folder") == true)
    }

    @Test func cancelledMigrationKeepsItsJournalAndStopsLaterEntries() async throws {
        let a = item("a"), b = item("b")
        var pending = Set<String>()
        do {
            _ = try await ChromiumExtensionImport.run([a, b], installed: [], pending: [],
                journal: { pending = $0 }, install: { _ in throw CancellationError() },
                enable: { _, _ in Issue.record("Cancelled import changed enabled state") },
                remember: { _ in Issue.record("Cancelled import saved pins") })
            Issue.record("Cancellation was swallowed")
        } catch is CancellationError { #expect(pending == [a.id]) }
    }

    @Test func pinOrderRetainsNativeOnlyPinsAndRemovesUnpinnedImportedItem() {
        let a = item("a"), b = item("b", pinned: false), c = item("c")
        #expect(ChromiumExtensionImport.pins([c.id, b.id, a.id], remembering: b, order: [a, b]) == [c.id, a.id])
    }

    @Test func movingEnginesAsksOnlyForWhatChromeWarnsOfOrANewSite() {
        let saved = ChromiumExtensionGrants.normalized(["storage", "activeTab", "https://a.test/*"])
        func beyond(_ grants: [String], approved: [String] = []) -> Set<String> {
            ChromiumExtensionGrants.beyondApproval(required: ChromiumExtensionGrants.normalized(grants), saved: saved,
                                                   approvedManifest: ChromiumExtensionGrants.normalized(approved))
        }
        #expect(beyond(["storage", "https://a.test/*"]).isEmpty)
        // What WebKit never saved, and Chrome adds with no warning or only for its own app.
        #expect(beyond(["offscreen", "sidePanel", "nativeMessaging", "identity"]).isEmpty)
        // A match WebKit dropped from the list, in the manifest that was approved.
        #expect(beyond(["https://local.test:8443/*"], approved: ["https://local.test:8443/*"]).isEmpty)
        // A site the approved manifest never had: an update's.
        #expect(beyond(["https://b.test/*"]) == ["site:https://b.test/*"])
        // Chrome warns of these, whatever the manifest said under WebKit.
        #expect(beyond(["debugger"], approved: ["debugger"]) == ["permission:debugger"])
        #expect(beyond(["tabCapture", "history"]) == ["permission:tabCapture", "permission:history"])
    }

    @Test func anExtensionsRowsCrossInPartsOfValidJSON() throws {
        let rows = [(key: "a", value: "1"), (key: "b\"c", value: "{\"x\":[1,2]}"), (key: "broken", value: "{oops"), (key: "d", value: "\"é😀\"")]
        let parts = ChromiumExtensionStorage.parts(rows, size: 20)
        #expect(parts.count > 1)
        var seen: [String: Any] = [:]
        for part in parts {
            let object = try #require(try JSONSerialization.jsonObject(with: Data(part.utf8)) as? [String: Any])
            seen.merge(object) { first, _ in first }
        }
        #expect(Set(seen.keys) == ["a", "b\"c", "d"])
        #expect(seen["d"] as? String == "é😀")
        #expect(ChromiumExtensionStorage.parts([]) == [])
    }

    @Test func journalWriteFailureNeverForgetsTheUnfinishedItem() async throws {
        let a = item("a"), b = item("b")
        var persisted = Set<String>()
        var writes = 0
        let result = try await ChromiumExtensionImport.run([a, b], installed: [], pending: [],
            journal: { pending in
                writes += 1
                if writes == 2 { throw CocoaError(.fileWriteOutOfSpace) }
                persisted = pending
            }, install: { _ in }, enable: { _, _ in }, remember: { _ in })
        #expect(result.map(\.state) == [.failed, .imported])
        #expect(persisted == [a.id])
    }
}
