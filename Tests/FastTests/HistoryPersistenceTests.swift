import Foundation
import Testing
@testable import Fast

@MainActor struct HistoryPersistenceTests {
    @Test func importedHistorySurvivesRestartAndForgetting() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("history.json")
        let now = Date()
        let places = (0..<3_100).map { index in
            Chromium.Place(url: URL(string: "https://import.example/page-\(index)")!, title: "Page \(index)",
                           count: index + 1, typed: index % 3 + 1, last: now.addingTimeInterval(-Double(index)))
        }
        let history = History(file: file)
        history.take(History.gather(places))
        await history.flush()
        let reopened = History(file: file)
        #expect(reopened.everything().count == 3_100)
        #expect(reopened.title(of: places.last!.url) == "Page 3099")
        let rows = try JSONDecoder().decode([Visit].self, from: Data(contentsOf: file))
        #expect(rows.first(where: { $0.url == places.last!.url.absoluteString })?.typed == 1)
        reopened.forget("import.example/page-3099")
        await reopened.flush()
        #expect(History(file: file).everything().count == 3_099)
        reopened.forget()
        await reopened.flush()
        #expect(History(file: file).everything().isEmpty)
    }

    @Test func olderFilesWithDuplicateKeysStillLoad() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("history.json")
        let old = Visit(url: "https://same.example/", key: "same.example", title: "Old", count: 1,
                        last: Date(timeIntervalSince1970: 1), typed: nil)
        var recent = old
        recent.title = "Recent"
        recent.last = Date(timeIntervalSince1970: 2)
        try JSONEncoder().encode([old, recent]).write(to: file)
        #expect(History(file: file).title(of: URL(string: old.url)!) == "Recent")
    }
}
