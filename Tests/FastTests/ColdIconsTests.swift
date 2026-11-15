import AppKit
import Foundation
import Testing
@testable import Fast

/// Imported and restored tabs stay asleep, but must still ask for their
/// public site's icon when the other browser had no bitmap to bring.
@MainActor
@Suite(.serialized)
struct ColdIconsTests {
    @Test func sleepingTabsFindAnAvailableSiteIconWithoutOpeningTheirPages() async throws {
        let fixture = try LocalNetworkFixture()
        defer { fixture.stop() }
        let icon = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3)).fill()
            return true
        }
        let bitmap = try #require(icon.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        var reply = LocalNetworkFixture.Reply("")
        reply.type = "image/png"
        reply.body = try #require(bitmap.representation(using: .png, properties: [:]))
        fixture.route("/site.png", reply)
        fixture.route("/", .init("<link rel='icon' href='/site.png' sizes='32x32'>"))

        // Store.testing isolates these fixture files from production data.
        // Farm callers can set YAB_PROBE for a separate test world; otherwise
        // this is the shared Yab (test) folder. Remove only loopback icons.
        let files = ["127.0.0.1.png", "127.0.0.1@dark.png"].map {
            Store.folder.appendingPathComponent("icons").appendingPathComponent($0)
        }
        files.forEach { try? FileManager.default.removeItem(at: $0) }
        defer { files.forEach { try? FileManager.default.removeItem(at: $0) } }

        let tabs = (0..<129).map { index in
            let tab = Tab()
            tab.restore(url: URL(string: "\(fixture.root)/bookmarks/\(index)?privateQuery=staysHere#part")!, title: "Bookmark \(index)")
            tab.kept = true
            return tab
        }
        // The mark and privacy are restored after the address. These must
        // never disclose their address to the public icon lookup.
        let custom = Tab(), privateTab = Tab(shy: true), moved = Tab(), own = Tab()
        let excluded = URL(string: "http://localhost:\(fixture.port)/private")!
        custom.restore(url: excluded, title: "My letter")
        custom.customMark = "A"
        privateTab.restore(url: excluded, title: "Private")
        moved.restore(url: excluded, title: "Old address")
        moved.restore(url: URL(fileURLWithPath: "/tmp/local-page.html"), title: "Now local")
        own.restore(url: KnowPage.url(), title: "About you")
        defer { (tabs + [custom, privateTab, moved, own]).forEach { $0.close() } }
        let until = Date().addingTimeInterval(4)
        while Favicons.shared.cached("127.0.0.1") == nil, Date() < until {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(Favicons.shared.cached("127.0.0.1") != nil)
        #expect(fixture.requests.map(\.path) == ["/", "/site.png"])
        #expect(tabs.allSatisfy { $0.builtPage == nil && $0.asleep })
        #expect(tabs.allSatisfy { $0.customMark == nil })
        #expect(custom.customMark == "A" && custom.displayIcon != nil)
        #expect(own.icon != nil)
        #expect([custom, privateTab, moved, own].allSatisfy { $0.builtPage == nil })

        // Arc's cache is read asynchronously after its sleeping tabs are
        // laid out. Even if a front-page lookup won that race, the actual
        // imported bitmap must win, then remain the cached one.
        let guessed = try #require(Favicons.shared.cached("127.0.0.1"))
        let imported = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.systemRed.setFill(); NSBezierPath(rect: rect).fill(); return true
        }
        let importedBitmap = try #require(imported.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let importedData = try #require(importedBitmap.representation(using: .png, properties: [:]))
        await Favicons.shared.adopt(importedData, for: "127.0.0.1")
        let adopted = try #require(Favicons.shared.cached("127.0.0.1"))
        #expect(adopted !== guessed)
        await Favicons.shared.adopt(reply.body, for: "127.0.0.1")
        #expect(Favicons.shared.cached("127.0.0.1") === adopted)
    }

    @Test func rootIconsKeepTheOriginAndExcludeCredentials() {
        func roots(_ address: String) -> [String] {
            Favicons.rank([], page: URL(string: address)!, dark: false).map(\.absoluteString)
        }
        #expect(roots("http://EXAMPLE.com:8080/private?q=secret#part") == ["http://example.com:8080/favicon.ico"])
        #expect(roots("https://user:password@example.com/a").isEmpty)
        #expect(roots("file:///tmp/page.html").isEmpty)
        #expect(roots(KnowPage.url().absoluteString).isEmpty)
    }
}
