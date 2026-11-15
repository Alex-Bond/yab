import AppKit
import Foundation
import Testing
@testable import Fast

/// R2600: Docs, Sheets and Slides share docs.google.com, and the icon kept
/// for the host was the one every page of it wore before it loaded: a
/// slideshow's sleeping tab, its pin and its row under the field wore the
/// Docs icon. Each page now keeps what it wore, as Chromium's history keeps a
/// favicon per page URL, and the host's is for pages never seen.
@MainActor
@Suite(.serialized)
struct PageIconsTests {
    private func square(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            color.setFill(); NSBezierPath(rect: rect).fill(); return true
        }
    }

    private func png(_ color: NSColor) throws -> Data {
        let bitmap = try #require(square(color).tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    private func tone(_ image: NSImage?) -> NSColor? {
        image?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.colorAt(x: 16, y: 16)?.usingColorSpace(.deviceRGB)
    }

    @Test func aPageIsItsSiteAndPathAlone() {
        func page(_ address: String) -> String? { Favicons.page(URL(string: address)!) }
        #expect(page("https://docs.google.com/presentation/d/abc/edit?usp=sharing#slide=id.p2")
            == "docs.google.com/presentation/d/abc/edit")
        #expect(page("http://Docs.Google.com/presentation/d/abc/edit") == "docs.google.com/presentation/d/abc/edit")
        #expect(page("https://example.com") == "example.com/")
        #expect(page("http://192.168.1.20:8080/app") == "192.168.1.20:8080/app")
        #expect(page("https://user:secret@example.com/a") == nil)
        #expect(page("file:///tmp/page.html") == nil)
        #expect(page("yab://mail") == nil)
    }

    @Test func eachPageWearsItsOwnAndAPageNeverSeenItsSites() {
        let icons = Favicons(keepsPages: false)
        let host = "docs-\(UUID().uuidString.prefix(8).lowercased()).test"
        let slides = URL(string: "https://\(host)/presentation/d/one/edit")!
        let docs = URL(string: "https://\(host)/document/d/two/edit")!
        let yellow = square(.systemYellow), blue = square(.systemBlue)
        icons.remember(yellow, page: slides, dark: false, shy: false)
        icons.remember(blue, page: docs, dark: false, shy: false)
        #expect(icons.pageIcon(slides) === yellow)
        #expect(icons.pageIcon(URL(string: "https://\(host)/presentation/d/one/edit#slide=id.p9")!) === yellow)
        #expect(icons.pageIcon(docs) === blue)
        // Another slideshow, never open here: the host's, none kept here.
        #expect(icons.pageIcon(URL(string: "https://\(host)/presentation/d/three/edit")!) == nil)
        #expect(icons.cached(page: URL(string: "https://\(host)/presentation/d/three/edit")!) == nil)
        // A private tab's page is kept nowhere.
        let secret = URL(string: "https://\(host)/presentation/d/secret/edit")!
        icons.remember(yellow, page: secret, dark: false, shy: true)
        #expect(icons.pageIcon(secret) == nil)
        // Refresh Site Icon: the site's pages forget theirs.
        icons.forgetPages(of: host)
        #expect(icons.pageIcon(slides) == nil && icons.pageIcon(docs) == nil)
    }

    /// The reported case end to end on a restored tab: the host keeps the
    /// Docs icon (the first page seen), the slideshow wore its own, and
    /// after a restart its sleeping tab comes back wearing the slideshow's
    /// while a Docs tab and a page never seen wear the host's.
    @Test func aRestoredTabWearsWhatItsPageWoreNotItsHosts() async throws {
        let host = "docs-\(UUID().uuidString.prefix(8).lowercased()).test"
        let siteFile = Store.folder.appendingPathComponent("icons").appendingPathComponent(host + ".png")
        defer { try? FileManager.default.removeItem(at: siteFile) }
        // The host's: the Docs icon, blue.
        await Favicons.shared.adopt(try png(.systemBlue), for: host)
        let slides = URL(string: "https://\(host)/presentation/d/deck/edit")!
        let docs = URL(string: "https://\(host)/document/d/memo/edit")!
        // The slideshow wore its own, yellow, and it was written.
        let writer = Favicons()
        writer.remember(square(.systemYellow), page: slides, dark: false, shy: false)
        writer.savePagesNow()
        defer { writer.forgetPages(of: host); writer.savePagesNow() }

        // A fresh start reads it from the disk.
        let reader = Favicons()
        let read = try #require(tone(reader.pageIcon(slides)))
        #expect(read.redComponent > 0.8 && read.blueComponent < 0.3)
        #expect(reader.pageIcon(docs) == nil)

        // In the shared store a restored tab asks it the same way.
        Favicons.shared.remember(square(.systemYellow), page: slides, dark: false, shy: false)
        defer { Favicons.shared.forgetPages(of: host) }
        let deck = Tab(), memo = Tab(), unseen = Tab()
        defer { [deck, memo, unseen].forEach { $0.close() } }
        deck.restore(url: slides.appending(queryItems: [URLQueryItem(name: "usp", value: "sharing")]), title: "Deck")
        memo.restore(url: docs, title: "Memo")
        unseen.restore(url: URL(string: "https://\(host)/presentation/d/other/edit")!, title: "Other")
        let one = try #require(tone(deck.icon)), two = try #require(tone(memo.icon)), three = try #require(tone(unseen.icon))
        #expect(one.redComponent > 0.8 && one.blueComponent < 0.3)
        #expect(two.blueComponent > two.redComponent)
        #expect(three.blueComponent > three.redComponent)
    }
}
