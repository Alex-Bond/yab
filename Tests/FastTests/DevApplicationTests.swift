import Foundation
import Testing
@testable import Fast

@Suite(.serialized) @MainActor struct DevApplicationTests {
    @Test func cookieOriginMatchingRespectsHostOnlyAndDomainBoundaries() {
        #expect(DevApplicationModel.cookie(["domain": ".example.com"], belongsTo: "https://app.example.com:8443"))
        #expect(DevApplicationModel.cookie(["domain": "app.example.com"], belongsTo: "https://app.example.com"))
        #expect(!DevApplicationModel.cookie(["domain": "example.com"], belongsTo: "https://app.example.com"))
        #expect(!DevApplicationModel.cookie(["domain": ".example.com"], belongsTo: "https://notexample.com"))
        #expect(!DevApplicationModel.cookie(["domain": ".example.com"], belongsTo: "https://example.com.attacker.test"))
    }
    @Test func crossOriginNavigationDropsDocumentAndDatabaseSelection() {
        let app = DevApplicationModel()
        app.acceptSnapshot(["origins": [["origin": "https://one.test"]]])
        app.select(ApplicationSelection(section: .indexedDB, origin: "https://one.test", database: "private", store: "records"))
        app.rows = [ApplicationGridRow(id: "secret", cells: ["secret", "old value"])]
        app.schemas["old"] = [["name": "records"]]
        app.acceptSnapshot(["origins": [["origin": "https://two.test"]]])
        #expect(app.selection.origin == "https://two.test")
        #expect(app.selection.database.isEmpty && app.selection.store.isEmpty)
        #expect(app.rows.isEmpty && app.schemas.isEmpty)
    }
    @Test func refreshedSnapshotKeepsAnExistingIframeSelection() {
        let app = DevApplicationModel()
        let snapshot: [String: Any] = ["origins": [["origin": "https://top.test"], ["origin": "https://frame.test"]]]
        app.acceptSnapshot(snapshot)
        app.select(ApplicationSelection(section: .local, origin: "https://frame.test"))
        app.acceptSnapshot(snapshot)
        #expect(app.selection.origin == "https://frame.test")
        app.acceptSnapshot(["origins": [["origin": "https://top.test"]]])
        #expect(app.selection.origin == "https://top.test")
    }
    @Test func selectionIdentityIncludesIndexFrameAndCache() {
        let base = ApplicationSelection(section: .indexedDB, origin: "https://one.test", database: "db", store: "items")
        var indexed = base; indexed.index = "by_name"
        var framed = base; framed.frame = "iframe-1"
        #expect(Set([base.id, indexed.id, framed.id]).count == 3)
        #expect(framed.params["frame"] as? String == "iframe-1")
    }
    @Test func filteringUsesFullValueAndSelectionRemainsStable() {
        let app = DevApplicationModel()
        app.rows = [ApplicationGridRow(id: "a", cells: ["a", String(repeating: "x", count: 10_000) + "needle"]), ApplicationGridRow(id: "b", cells: ["b", "other"])]
        app.selectedRow = "a"; app.filter = "NEEDLE"
        #expect(app.visibleRows.map(\.id) == ["a"])
        #expect(app.row?.id == "a")
        app.select(ApplicationSelection(section: .cookies))
        #expect(app.selectedRow.isEmpty && app.rows.isEmpty && app.preview.isEmpty)
    }
    @Test func storageJSONKeepsFalsyScalarValues() {
        #expect(DevApplicationModel.text(false) == "false")
        #expect(DevApplicationModel.text(0) == "0")
        #expect(DevApplicationModel.text(NSNull()) == "null")
    }
    @Test func indexedDBKeysKeepTheirJSONType() throws {
        #expect(DevApplicationModel.json("row-001") == "\"row-001\"")
        #expect(DevApplicationModel.json(42) == "42")
        #expect(DevApplicationModel.json(1) != DevApplicationModel.json("1"))
        let encoded = DevApplicationModel.json(["group", 3] as [Any])
        let decoded = try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [Any]
        #expect(decoded?.first as? String == "group")
        #expect(decoded?.last as? Int == 3)
    }

}
