import AppKit
import Testing
@testable import Fast

@Suite(.serialized)
@MainActor
struct TidyNamesTests {
    private func folder(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tidy-names-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    @Test func identifiersNeedNamesButDescriptiveFilesKeepTheirs() {
        for name in ["8f3a2c91-7d4e.pdf", "document (3).pdf", "export_20261020_101533.csv", "IMG_4821.png"] {
            #expect(DownloadNames.unreadable(name), "\(name)")
        }
        for name in ["Acme Invoice October 2026.pdf", "feedback 2026.pdf", "Research Notes.txt", "Lease Agreement Maple Street.pdf"] {
            #expect(!DownloadNames.unreadable(name), "\(name)")
        }
    }

    /// The names apps and sites give by themselves say nothing of the file
    /// either: with Tidy Downloads on they kept them (#444).
    @Test func namesAppsGiveByThemselvesAreRenamed() {
        for name in ["unnamed.jpg", "unnamed (2).png", "images.jpeg", "Screenshot 2026-10-22 at 10.15.32.png",
                     "Screen Shot 2026-10-22 at 10.15.32 AM.png", "CleanShot 2026-10-22 at 10.15.32@2x.png",
                     "WhatsApp Image 2026-10-22 at 10.15.32.jpeg", "ChatGPT Image Oct 22, 2026, 10_15_32 AM.png",
                     "file-sample_150kB.pdf", "sample.pdf", "output.pdf", "Untitled design.png"] {
            #expect(DownloadNames.unreadable(name), "\(name)")
        }
        for name in ["Resume.pdf", "Quarterly Plan.key", "Northwind Board Minutes.docx", "Boarding Pass UA 1532.png"] {
            #expect(!DownloadNames.unreadable(name), "\(name)")
        }
    }

    /// A site's random identifier is still unhelpful when it is short,
    /// contains letters beyond hex, or gained a download collision number.
    @Test func randomDownloadIdentifiersNeedContentNames() {
        for name in ["018za2ky.webp", "018za2ky 2.webp", "a8Kd93.png", "IMG-x7q2.jpg", "f_3kq9z.pdf",
                     "bxzptq.webp", "jvqx.txt", "aZq.png", "zx.gif", "r7.zip", "Qk9.csv"] {
            #expect(DownloadNames.unreadable(name), "\(name)")
        }
    }

    /// A useful name does not become random because it includes a model,
    /// project number, acronym, or a long numeric reference.
    @Test func meaningfulProjectNamesKeepTheirNumbersAndAcronyms() {
        for name in ["Q3 budget.xlsx", "aaron-sprite.webp", "Apollo13.pdf", "project20261020.csv",
                     "Acme Invoice 20261020.pdf", "API.json", "RFC9110.pdf", "H264.mp4",
                     "B2B sales.csv", "3D engine.blend", "v2 API guide.md"] {
            #expect(!DownloadNames.unreadable(name), "\(name)")
        }
    }

    /// English spelling is not the definition of a useful filename, and
    /// equivalent composed/decomposed accents must give the same result.
    @Test func meaningfulNamesInOtherLanguagesKeepTheirSpelling() {
        for name in ["Отчёт2026.pdf", "план.xlsx", "预算2026.xlsx", "会議録.docx", "Résumé.pdf",
                     "café.jpg", "cafe\u{301}.jpg", "Δοκιμή42.txt"] {
            #expect(!DownloadNames.unreadable(name), "\(name)")
        }
    }

    /// #1073, the reporter's case on 0.38.3: a Pokemon sprite with no words
    /// in it, served as "01w4v3…o 2.webp" from a page titled "Adaman", was
    /// named "POKEMON GAME GUIDE April 2025". Arc names it Adaman.webp.
    @Test func wordlessPictureIsNamedForItsPage() async {
        #expect(DownloadNames.wordless(""))
        #expect(DownloadNames.wordless("A |\n7"))
        #expect(!DownloadNames.wordless("Boarding Pass UA 1532"))
        let said = await DownloadNames.model(served: "01w4v3xo 2.webp", page: "Adaman", site: "bulbapedia.bulbagarden.net", lines: "")
        #expect(said == "Adaman")
        #expect(DownloadNames.fileName(said ?? "", like: "01w4v3xo 2.webp") == "Adaman.webp")
    }

    /// The part of a title that is the page's subject, not the site's name,
    /// and nothing from a title that only names the site or the file.
    @Test func pageTitlesGiveTheirSubject() {
        let cases: [(String, String, String?)] = [
            ("Adaman", "bulbapedia.bulbagarden.net", "Adaman"),
            ("Adaman - Bulbapedia, the community-driven Pokémon encyclopedia", "bulbapedia.bulbagarden.net", "Adaman"),
            ("Art of the Day - DeviantArt", "www.deviantart.com", "Art of the Day"),
            ("Boarding Pass UA 1532 | United Airlines", "www.united.com", "Boarding Pass UA 1532"),
            ("Wikipedia", "en.wikipedia.org", nil),
            ("Google Images", "images.google.com", nil),
            ("01w4v3xo.webp (120×120)", "cdn.example.com", nil),
            ("Downloads", "example.com", nil),
            ("java - Why is conditional processing of a sorted array faster than of an unsorted array? - Stack Overflow",
             "stackoverflow.com", nil),
        ]
        for (title, site, name) in cases {
            #expect(DownloadNames.pageName(title, site: site) == name, "\(title)")
        }
        #expect(DownloadNames.pageName(nil, site: "example.com") == nil)
    }

    /// A month and year the model made up is dropped; one the file or page
    /// says stays.
    @Test func inventedDatesAreDropped() {
        let read = "01w4v3xo 2.webp\nbulbapedia.bulbagarden.net\nAdaman\n"
        #expect(DownloadNames.withoutInventedDate("POKEMON GAME GUIDE April 2025", source: read) == "POKEMON GAME GUIDE")
        #expect(DownloadNames.withoutInventedDate("Adaman Sprite 2025", source: read) == "Adaman Sprite")
        #expect(DownloadNames.withoutInventedDate("Fabrikam Invoice 1180 Mar 2026", source: "INVOICE 1180\nMarch 2026")
            == "Fabrikam Invoice 1180 Mar 2026")
        #expect(DownloadNames.withoutInventedDate("Lease Agreement 12 Elm Road", source: "") == "Lease Agreement 12 Elm Road")
    }

    @Test func modelAnswersStaySingleFileNames() {
        #expect(DownloadNames.fits("Acme Invoice Oct 2026"))
        for said in ["", "../other", "Acme/Invoice", "Acme\\Invoice", "Acme:Invoice", "Acme\nInvoice", "Acme\u{0}Invoice", "   ", ".", "\"\"", "''"] {
            #expect(!DownloadNames.fits(said), "\(said)")
        }
        #expect(DownloadNames.fileName("Acme Invoice.pdf", like: "document.PDF") == "Acme Invoice.PDF")
        #expect(DownloadNames.fileName("Acme Invoice", like: "document.pdf") == "Acme Invoice.pdf")
        #expect(DownloadNames.fileName("Research Notes", like: "download") == "Research Notes")
    }

    @Test func chatAnswersAreCleanedToOneName() {
        #expect(DownloadNames.clean("\"Acme Invoice INV-4821 Oct 2026.\"") == "Acme Invoice INV-4821 Oct 2026")
        #expect(DownloadNames.clean("Name: Boarding Pass UA 1532\n\nThis names the file.") == "Boarding Pass UA 1532")
        #expect(DownloadNames.clean("\n**Lease Agreement Maple Street**\n") == "Lease Agreement Maple Street")
        #expect(DownloadNames.fits(DownloadNames.clean("File name: Q3 Board Notes Oct 2026")))
        #expect(DownloadNames.clean("") == "")
    }

    @Test func documentsAndPicturesHaveFirstLines() throws {
        try folder { dir in
            let words = NSAttributedString(string: "Quarterly Board Meeting Minutes\nNorthwind Traders, October 2026")
            let docx = dir.appendingPathComponent("document.docx")
            try words.data(from: NSRange(location: 0, length: words.length),
                           documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]).write(to: docx)
            #expect(DownloadNames.firstLines(docx).contains("Board Meeting Minutes"))
            let rtf = dir.appendingPathComponent("file.rtf")
            try words.data(from: NSRange(location: 0, length: words.length),
                           documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: rtf)
            #expect(DownloadNames.firstLines(rtf).contains("Northwind Traders"))

            // A screenshot-like picture: its words come back from Vision.
            let size = NSSize(width: 900, height: 260)
            let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.white.setFill()
            NSRect(origin: .zero, size: size).fill()
            ("Boarding Pass" as NSString).draw(at: NSPoint(x: 40, y: 150), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 64), .foregroundColor: NSColor.black])
            ("Flight UA 1532 SFO to JFK" as NSString).draw(at: NSPoint(x: 40, y: 50), withAttributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black])
            NSGraphicsContext.restoreGraphicsState()
            let png = dir.appendingPathComponent("IMG_4821.png")
            try #require(rep.representation(using: .png, properties: [:])).write(to: png)
            let read = DownloadNames.firstLines(png)
            #expect(read.contains("Boarding Pass"), "\(read)")
            #expect(read.contains("1532"), "\(read)")
        }
    }

    @Test func renameAndUndoPreserveBytesAndOtherFiles() throws {
        try folder { dir in
            let raw = dir.appendingPathComponent("document.pdf")
            let other = dir.appendingPathComponent("Acme Invoice.pdf")
            try Data("mine".utf8).write(to: raw)
            try Data("existing".utf8).write(to: other)
            let loot = Loot(persist: false)
            let keep = Keep(name: raw.lastPathComponent, from: "example.test", path: raw.path, date: Date())
            loot.add(keep)
            let moved = try #require(loot.rename(keep, to: "Acme Invoice.pdf", animate: true))
            #expect(moved.name == "Acme Invoice 2.pdf")
            #expect(try Data(contentsOf: moved.url) == Data("mine".utf8))
            #expect(try Data(contentsOf: other) == Data("existing".utf8))
            #expect(!raw.isFileURL || !FileManager.default.fileExists(atPath: raw.path))
            #expect(moved.was == "document.pdf")
            #expect(moved.revealing != nil)
            let restored = try JSONDecoder().decode(Keep.self, from: JSONEncoder().encode(moved))
            #expect(restored.was == "document.pdf")
            #expect(restored.revealing == nil)
            loot.undoRename(moved)
            #expect(try Data(contentsOf: raw) == Data("mine".utf8))
            #expect(loot.kept.first?.was == nil)
            loot.undoRename(moved)
            #expect(loot.kept.count == 1)
            #expect(try Data(contentsOf: other) == Data("existing".utf8))
        }
    }

    @Test func undoDoesNotOverwriteAFileCreatedSinceTheDownload() throws {
        try folder { dir in
            let raw = dir.appendingPathComponent("document.pdf")
            try Data("mine".utf8).write(to: raw)
            let loot = Loot(persist: false)
            let keep = Keep(name: raw.lastPathComponent, from: "example.test", path: raw.path, date: Date())
            loot.add(keep)
            let moved = try #require(loot.rename(keep, to: "Acme Invoice.pdf"))
            try Data("new occupant".utf8).write(to: raw)
            loot.undoRename(moved)
            #expect(try Data(contentsOf: raw) == Data("new occupant".utf8))
            #expect(loot.kept.first?.name == "document 2.pdf")
            #expect(try Data(contentsOf: loot.kept[0].url) == Data("mine".utf8))
        }
    }

    @Test func extensionsKeepTheSameDownloadThroughRenameAndUndo() throws {
        try folder { dir in
            let raw = dir.appendingPathComponent("document.pdf")
            try Data("mine".utf8).write(to: raw)
            let loot = Loot(persist: false)
            loot.add(Keep(name: raw.lastPathComponent, from: "example.test", path: raw.path, date: Date()))
            let original = try #require(ExtensionDownloads.search(["filename": raw.path], loot: loot).first)
            let id = try #require(original["id"] as? Int)
            let moved = try #require(loot.rename(loot.kept[0], to: "Acme Invoice.pdf"))
            let renamed = try #require(ExtensionDownloads.search(["id": id], loot: loot).first)
            #expect(renamed["filename"] as? String == moved.path)
            #expect(ExtensionDownloads.search(["filename": moved.path], loot: loot).count == 1)
            loot.undoRename(moved)
            let restored = try #require(ExtensionDownloads.search(["id": id], loot: loot).first)
            #expect(restored["filename"] as? String == raw.path)
        }
    }

    @Test func forgottenFilesAndPathComponentsAreNotRenamed() throws {
        try folder { dir in
            let raw = dir.appendingPathComponent("document.pdf")
            try Data("mine".utf8).write(to: raw)
            let loot = Loot(persist: false)
            let keep = Keep(name: raw.lastPathComponent, from: "example.test", path: raw.path, date: Date())
            #expect(loot.rename(keep, to: "Acme Invoice.pdf") == nil)
            loot.add(keep)
            for name in ["../elsewhere.pdf", "folder/file.pdf", "a:b.pdf", "a\\b.pdf", "\u{0}", "..", "."] {
                #expect(loot.rename(keep, to: name) == nil)
            }
            #expect(loot.rename(keep, to: keep.name) == nil)
            #expect(try Data(contentsOf: raw) == Data("mine".utf8))
        }
    }

    @Test func fileChangedWhileTheModelWorkedIsDetectable() throws {
        try folder { dir in
            let raw = dir.appendingPathComponent("download.txt")
            try Data("one".utf8).write(to: raw)
            let before = try #require(DownloadNames.signature(raw))
            try Data("a replacement with different length".utf8).write(to: raw, options: .atomic)
            #expect(DownloadNames.signature(raw) != before)
        }
    }

    @Test func switchOffAndHandWrittenTitlesWin() {
        let enabled = ShortNames.enabled
        defer { ShortNames.enabled = enabled }
        let tab = Tab()
        tab.restore(url: URL(string: "https://example.test/notes")!, title: "A long title about Swift animations - Example")
        tab.kept = true
        ShortNames.enabled = false
        #expect(ShortNames.shared.name(for: tab) == nil)
        ShortNames.enabled = true
        tab.name = "My own title"
        #expect(ShortNames.shared.name(for: tab) == nil)
        tab.close()
    }

    @Test func allThreeSwitchesAreSearchableOnTheirOwnPage() {
        for id in ["tidy-titles", "folder-names", "tidy-downloads"] {
            #expect(SettingsItem.all.contains { $0.id == id && $0.page == .whileYouBrowse })
        }
        #expect(SettingsPage.whileYouBrowse.parent == .ai)
        #expect(Rename.cross == 0.62)
    }
}
