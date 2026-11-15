import Foundation
import Testing
@testable import Fast

// Safari's export as Apple documents it ("Importing data exported from
// Safari"), made here and read back: every kind of file known by what it
// holds, whatever it is called.
struct SafariImportTests {
    static func export(named names: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("safari-test-\(UUID().uuidString)")
        let inside = root.appendingPathComponent("Safari Export")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        for (name, text) in names { try text.write(to: inside.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let zip = root.appendingPathComponent("Safari Export.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", inside.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        return zip
    }

    static let cards = """
    {"metadata": {"browser_name": "Safari", "browser_version": "18.2", "data_type": "payment_cards", "export_time_usec": 1734000000000000, "schema_version": 1},
     "payment_cards": [
      {"card_number": "4242424242424242", "card_name": "Travel", "cardholder_name": "Mei Chen", "card_expiration_month": 11, "card_expiration_year": 2027, "card_last_used_time_usec": 1722730594744987},
      {"card_number": "1234", "cardholder_name": "Not a card"}]}
    """

    @Test func everyKindIsKnownByWhatItHolds() throws {
        // Localized names, as a German Safari writes them.
        let zip = try Self.export(named: [
            "Zahlungskarten.json": Self.cards,
            "Passwörter.csv": "Title,URL,Username,Password,Notes,OTPAuth\nexample.com,https://example.com/,mei,hunter22,,\n",
            "Lesezeichen.html": "<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<DL><p><DT><A HREF=\"https://apple.com/\">Apple</A></DL><p>",
            "Verlauf.json": "{\"metadata\": {\"data_type\": \"history\"}, \"history\": [{\"url\": \"https://apple.com/\", \"time_usec\": 1722367302951213, \"visits_count\": 1}]}",
            "Erweiterungen.json": "{\"metadata\": {\"data_type\": \"extensions\"}, \"extensions\": []}",
        ])
        let export = try #require(SafariImport.read(zip))
        #expect(export.cards.count == 1)
        let card = try #require(export.cards.first)
        #expect(card.number == "4242424242424242" && card.nickname == "Travel" && card.name == "Mei Chen")
        #expect(card.month == 11 && card.year == 2027 && card.source == "Safari")
        #expect(abs((card.used?.timeIntervalSince1970 ?? 0) - 1722730594.744987) < 0.01)
        #expect(export.passwords?.contains("hunter22") == true)
        #expect(export.bookmarks?.lastPathComponent == "Lesezeichen.html")
        #expect(export.history.map(\.lastPathComponent) == ["Verlauf.json"])
        #expect(SafariImport.looksLikeExport(zip))
        try? FileManager.default.removeItem(at: export.folder)
    }

    @Test func anyOtherZipIsNotSafaris() throws {
        let zip = try Self.export(named: ["notes.txt": "hello", "photo.json": "{}"])
        #expect(SafariImport.read(zip) == nil)
        #expect(!SafariImport.looksLikeExport(zip))
    }

    @Test func whatCameIsOneLine() {
        var brought = SafariImport.Brought()
        #expect(brought.line == "Nothing new")
        brought.cards = 1
        #expect(brought.line == "1 card")
        brought.passwords = 212
        brought.bookmarks = 1204
        brought.places = 8300
        // Counts follow the Mac's locale, including its grouping separator.
        #expect(brought.line == "1 card, 212 passwords, \(1204.formatted()) bookmarks and \(8300.formatted()) places")
    }
}
