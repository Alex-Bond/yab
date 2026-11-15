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
        // Other suites deliberately cache misses and imported icons for IPv4
        // loopback in Favicons.shared. Use a separate real loopback host:
        // deleting disk files alone cannot clear that session's memory.
        let fixture = try LocalNetworkFixture(ipv6: true)
        // Kept under host and port: the fixture's port is a site of its own.
        let host = try #require(URL(string: fixture.root).flatMap(Favicons.site))
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
        let files = [host + ".png", host + "@dark.png"].map {
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
        while Favicons.shared.cached(host) == nil, Date() < until {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(Favicons.shared.cached(host) != nil)
        #expect(fixture.requests.map(\.path) == ["/", "/site.png"])
        #expect(tabs.allSatisfy { $0.builtPage == nil && $0.asleep })
        #expect(tabs.allSatisfy { $0.customMark == nil })
        #expect(custom.customMark == "A" && custom.displayIcon != nil)
        #expect(own.icon != nil)
        #expect([custom, privateTab, moved, own].allSatisfy { $0.builtPage == nil })

        // Arc's cache is read asynchronously after its sleeping tabs are
        // laid out. Even if a front-page lookup won that race, the actual
        // imported bitmap must win, then remain the cached one.
        let guessed = try #require(Favicons.shared.cached(host))
        let imported = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.systemRed.setFill(); NSBezierPath(rect: rect).fill(); return true
        }
        let importedBitmap = try #require(imported.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let importedData = try #require(importedBitmap.representation(using: .png, properties: [:]))
        await Favicons.shared.adopt(importedData, for: host)
        let adopted = try #require(Favicons.shared.cached(host))
        #expect(adopted !== guessed)
        await Favicons.shared.adopt(reply.body, for: host)
        #expect(Favicons.shared.cached(host) === adopted)
    }

    /// #1459: a NAS's services on one address and different ports are
    /// sites of their own. Their icons were kept under the host alone, the
    /// first one seen for all of them and the others' never, so after a
    /// restart each sleeping tab came back with another's icon or none.
    @Test func eachPortOfAHostKeepsItsOwnIcon() async throws {
        #expect(Favicons.site(URL(string: "http://192.168.1.20:8080/app")!) == "192.168.1.20:8080")
        #expect(Favicons.site(URL(string: "http://192.168.1.20:9000/")!) == "192.168.1.20:9000")
        #expect(Favicons.site(URL(string: "http://192.168.1.20/")!) == "192.168.1.20")
        #expect(Favicons.site(URL(string: "http://Example.com:80/")!) == "example.com")
        #expect(Favicons.site(URL(string: "https://example.com:443/a")!) == "example.com")
        #expect(Favicons.site(URL(string: "https://example.com:8443/a")!) == "example.com:8443")
        #expect(Favicons.site(URL(fileURLWithPath: "/tmp/page.html")) == nil)

        func png(_ color: NSColor) throws -> Data {
            let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
                color.setFill(); NSBezierPath(rect: rect).fill(); return true
            }
            let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            return try #require(bitmap.representation(using: .png, properties: [:]))
        }
        // A host nobody else uses, so no other suite's icon stands in.
        let host = "nas-\(UUID().uuidString.prefix(8).lowercased()).test"
        let red = "\(host):8080", blue = "\(host):9000"
        let files = [red, blue].map { Store.folder.appendingPathComponent("icons").appendingPathComponent($0 + ".png") }
        defer { files.forEach { try? FileManager.default.removeItem(at: $0) } }
        await Favicons.shared.adopt(try png(.systemRed), for: red)
        await Favicons.shared.adopt(try png(.systemBlue), for: blue)
        // Written off the main thread, each under its own name.
        let written = Date().addingTimeInterval(4)
        while !files.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }), Date() < written {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        // Restored after a restart, asleep: each wears its own port's icon.
        let first = Tab(), second = Tab()
        defer { [first, second].forEach { $0.close() } }
        first.restore(url: URL(string: "http://\(host):8080/dashboard")!, title: "Red")
        second.restore(url: URL(string: "http://\(host):9000/")!, title: "Blue")
        func tone(_ image: NSImage?) -> NSColor? {
            image?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.colorAt(x: 16, y: 16)?.usingColorSpace(.deviceRGB)
        }
        let one = try #require(tone(first.icon)), two = try #require(tone(second.icon))
        #expect(one.redComponent > one.blueComponent)
        #expect(two.blueComponent > two.redComponent)
        // Nor is either one the host's, for its other ports.
        #expect(Favicons.shared.cached(host) == nil)
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
