import Foundation
import Testing
@testable import Fast
@testable import MailCore

// Files (FileShelf): what you gave sites, mail's files, the words inside
// them, what an agent is told, and a page's file field putting what that
// site was given first.
@MainActor
struct FileShelfTests {
    static func folder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func shelf(_ folder: URL) -> FileShelf {
        FileShelf(file: folder.appendingPathComponent("sent.json"), words: folder.appendingPathComponent("words.json"))
    }

    static func write(_ text: String, _ name: String, in folder: URL) -> URL {
        let url = folder.appendingPathComponent(name)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func mailFile(_ name: String, from: String, sent: Bool = false, path: String?, ago days: Double = 1) -> ShelfFile {
        ShelfFile(id: "mail.me@x.test|m\(name)|1", name: name, date: Date().addingTimeInterval(-days * 86_400), size: 2_048,
                  origin: .mail(account: "me@x.test", message: "m1", thread: "thread1", from: MailPerson(name: from, address: "ivan@landlord.test"),
                                to: [MailPerson(name: "Anna Lee", address: "anna@brightkeys.test")], subject: "Re: Lease, signed copy", sent: sent),
                  file: MailFile(part: "1", name: name, mime: "application/pdf", size: 2_048, attachmentID: "a", contentID: "", inline: false),
                  path: path)
    }

    @Test func aSnippetIsTheWordsAroundWhatWasFound() {
        let text = String(repeating: "word ", count: 40) + "the security deposit of $3,200 is due on move-in" + String(repeating: " more", count: 40)
        let offset = text.lowercased().distance(from: text.startIndex, to: text.lowercased().range(of: "security")!.lowerBound)
        let line = FileShelf.snippet(text, at: offset, length: 8)
        #expect(line.hasPrefix("…"))
        #expect(line.hasSuffix("…"))
        #expect(line.contains("security deposit of $3,200"))
        #expect(!line.contains("  "))
    }

    @Test func whatASiteWasGivenIsKeptAndComesBackForThatSiteOnly() {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let shelf = Self.shelf(folder)
        let scan = Self.write("passport", "passport-scan.jpg", in: folder)
        shelf.gave([scan], to: "www.united.com")
        #expect(shelf.given(to: "united.com").map(\.name) == ["passport-scan.jpg"])
        #expect(shelf.given(to: "delta.com").isEmpty)
        #expect(shelf.sentFiles.first?.said == "Sent to www.united.com")
        // Kept across launches.
        let again = Self.shelf(folder)
        #expect(again.uploads.map(\.path) == [scan.path])
        // Given again: once, newest first.
        shelf.gave([scan], to: "www.united.com")
        #expect(shelf.uploads.count == 1)
        shelf.forget(shelf.sentFiles[0])
        #expect(shelf.uploads.isEmpty)
    }

    @Test func aFileGoneFromTheDiskIsNotOffered() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let shelf = Self.shelf(folder)
        let scan = Self.write("x", "gone.pdf", in: folder)
        shelf.gave([scan], to: "united.com")
        try FileManager.default.removeItem(at: scan)
        #expect(shelf.given(to: "united.com").isEmpty)
        #expect(shelf.sentFiles.isEmpty)
    }

    @Test func theWordsInsideAFileFindIt() async {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let shelf = Self.shelf(folder)
        let lease = Self.write("RESIDENTIAL LEASE\nThe Security Deposit of $3,200 is due before move-in.", "lease.txt", in: folder)
        shelf.learn([lease.path])
        for _ in 0..<100 where shelf.text(lease.path) == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
        #expect(shelf.text(lease.path)?.contains("Security Deposit") == true)
        #expect(shelf.found(lease.path, terms: ["security", "deposit"])?.contains("Security Deposit of $3,200") == true)
        #expect(shelf.found(lease.path, terms: ["security", "parking"]) == nil)
        // Kept: a new shelf reads them from the file, not the disk again.
        for _ in 0..<40 where !FileManager.default.fileExists(atPath: folder.appendingPathComponent("words.json").path) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(Self.shelf(folder).text(lease.path)?.contains("move-in") == true)
    }

    @Test func anAgentFindsDownloadsAndWhatWasSentByWordsAndWhere() async {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let shelf = Self.shelf(folder)
        let invoice = Self.write("Invoice 1042, total $48", "Invoice-1042.pdf.txt", in: folder)
        let scan = Self.write("scan", "passport-scan.jpg", in: folder)
        let kept = [Keep(name: "Invoice-1042.pdf.txt", from: "stripe.com", path: invoice.path, date: Date())]
        shelf.gave([scan], to: "united.com")
        #expect(shelf.search("", from: nil, loot: kept, mail: false, limit: 20).map(\.name).sorted() == ["Invoice-1042.pdf.txt", "passport-scan.jpg"])
        #expect(shelf.search("", from: "downloaded", loot: kept, mail: false, limit: 20).map(\.name) == ["Invoice-1042.pdf.txt"])
        #expect(shelf.search("", from: "sent", loot: kept, mail: false, limit: 20).map(\.name) == ["passport-scan.jpg"])
        #expect(shelf.search("united", from: nil, loot: kept, mail: false, limit: 20).map(\.name) == ["passport-scan.jpg"])
        shelf.learn([invoice.path])
        for _ in 0..<100 where shelf.text(invoice.path) == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
        let found = shelf.search("total $48", from: nil, loot: kept, mail: false, limit: 20)
        #expect(found.map(\.name) == ["Invoice-1042.pdf.txt"])
        #expect(found.first?.line?.contains("total $48") == true)
        let said = FileShelf.describe(found)
        #expect(said.contains("id: \(invoice.path)"))
        #expect(said.contains("inside: "))
        #expect(FileShelf.describe([]) == "No files found.")
    }

    @Test func filesReadGivesAPictureOrAVideoItsPath() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let shelf = Self.shelf(folder)
        let shot = folder.appendingPathComponent("shot.png")
        try MailAttachmentTests.png(width: 8, height: 8).write(to: shot)
        let clip = folder.appendingPathComponent("clip.mov")
        try Data((0..<4_000).map { UInt8($0 % 13) }).write(to: clip)
        let notes = Self.write("Gate B12 at 9:40", "notes.txt", in: folder)
        let kept = [Keep(name: "shot.png", from: "x.test", path: shot.path, date: Date()),
                    Keep(name: "clip.mov", from: "x.test", path: clip.path, date: Date()),
                    Keep(name: "notes.txt", from: "x.test", path: notes.path, date: Date())]
        for (url, name) in [(shot, "shot.png"), (clip, "clip.mov")] {
            let got = await shelf.give(url.path, loot: kept)
            #expect(got["error"] == nil, "\(name)")
            #expect(got["path"] as? String == url.path)
            let text = try #require(got["text"] as? String)
            #expect(text.hasPrefix("File \(name).\npath: \(url.path)\n"))
            #expect(text.contains("No words to read"))
        }
        // A file with words: its path, then its words.
        let read = await shelf.give(notes.path, loot: kept)
        #expect((read["text"] as? String)?.contains("path: \(notes.path)") == true)
        #expect((read["text"] as? String)?.contains("Gate B12 at 9:40") == true)
        let nowhere = await shelf.give(folder.appendingPathComponent("gone.mov").path, loot: kept)
        #expect((nowhere["error"] as? String)?.contains("isn't in Files") == true)
    }

    @Test func aMailFileSaysWhoSentItOrWhoItWentTo() {
        let got = Self.mailFile("Lease agreement, signed.pdf", from: "Ivan Petrov", path: nil)
        #expect(got.said == "Ivan Petrov")
        #expect(got.subject == "Re: Lease, signed copy")
        #expect(Hints.mailThread(got.thread)?.thread == "thread1")
        #expect(!got.sent)
        let sent = Self.mailFile("W-9 2026.pdf", from: "Me", sent: true, path: nil)
        #expect(sent.said == "Sent to Anna Lee")
        #expect(sent.sent)
    }

    @Test func aPageFieldOffersWhatThatSiteWasGivenThenMailsFiles() {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let scan = Self.write("scan", "passport-scan.jpg", in: folder)
        let pass = Self.write("pdf", "Boarding pass.pdf", in: folder)
        let given = [FileShelf.Upload(path: scan.path, name: "passport-scan.jpg", host: "united.com", date: Date().addingTimeInterval(-86_400))]
        let mail = [Self.mailFile("Boarding pass.pdf", from: "United", path: pass.path),
                    Self.mailFile("Old.pdf", from: "United", path: pass.path, ago: 90),
                    Self.mailFile("Not here.pdf", from: "United", path: nil)]
        let rows = FileRows.shelfRows(given: given, mail: mail, host: "www.united.com", accept: [], now: Date())
        #expect(rows.map(\.section) == ["Sent to united.com Before", "From Mail"])
        #expect(rows.map(\.title) == ["passport-scan.jpg", "Boarding pass.pdf"])
        #expect(rows[0].source == "Sent 1d ago" || rows[0].source.hasPrefix("Sent "))
        // Kept to what the field takes.
        let images = FileRows.shelfRows(given: given, mail: mail, host: "united.com", accept: ["image/*"], now: Date())
        #expect(images.map(\.title) == ["passport-scan.jpg"])
    }
}
