import AppKit
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct FaviconRefreshTests {
    private func png(_ color: NSColor) throws -> Data {
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            color.setFill(); NSBezierPath(rect: rect).fill(); return true
        }
        let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @Test func explicitRefreshRetriesAMissAndReplacesOnlyTheRequestedHost() async throws {
        let fixture = try LocalNetworkFixture()
        defer { fixture.stop() }
        fixture.route("/", .init("<link rel='icon' href='/old.png' sizes='32x32'>"))
        var initial = LocalNetworkFixture.Reply("")
        initial.type = "image/png"; initial.body = try png(.systemRed)
        fixture.route("/old.png", initial)
        let icons = Favicons()
        // The fixture's port is its own site, kept under host and port.
        let site = try #require(Favicons.site(URL(string: fixture.root)!))
        // An explicit successful seed also makes this test independent of
        // other methods' on-disk icon for this site in the same probe world.
        icons.fetch(page: URL(string: fixture.root + "/")!, again: true)
        try await settled(icons, host: site)
        fixture.route("/", .init("No icon"))
        fixture.route("/favicon.ico", .init("Unavailable", status: "503 Unavailable"))
        await icons.adopt(try png(.systemGreen), for: "sibling.example.test")
        let old = try #require(icons.cached(site))
        let oldBitmap = try #require(old.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let oldColor = try #require(oldBitmap.colorAt(x: 16, y: 16)?.usingColorSpace(.deviceRGB))
        #expect(oldColor.redComponent > oldColor.blueComponent)
        let sibling = try #require(icons.cached("sibling.example.test"))
        let page = URL(string: fixture.root + "/private/path?privateQuery=staysHere#part")!
        let tab = Tab()
        tab.customMark = "A"
        tab.restore(url: page, title: "Sleeping")
        defer { tab.close() }
        // Let the unrelated automatic cold-tab callback see the custom mark.
        try await Task.sleep(for: .milliseconds(40))
        tab.customMark = nil
        tab.icon = old
        #expect(Favicons.canRefresh(tab))
        icons.refresh(tab)
        let failedUntil = Date().addingTimeInterval(4)
        while icons.busy.contains(site), Date() < failedUntil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!icons.busy.contains(site))
        #expect(fixture.requests.contains { $0.path == "/favicon.ico" })
        #expect(icons.cached(site) === old)
        var response = LocalNetworkFixture.Reply("")
        response.type = "image/png"
        response.body = try png(.systemBlue)
        fixture.route("/", .init("<link rel='icon' href='/new.png' sizes='32x32'>"))
        fixture.route("/new.png", response)
        icons.refresh(tab)
        let refreshedUntil = Date().addingTimeInterval(4)
        while icons.cached(site) === old, Date() < refreshedUntil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let refreshed = try #require(icons.cached(site))
        #expect(refreshed !== old)
        let bitmap = try #require(refreshed.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let color = try #require(bitmap.colorAt(x: 16, y: 16)?.usingColorSpace(.deviceRGB))
        #expect(color.blueComponent > color.redComponent)
        #expect(icons.cached("sibling.example.test") === sibling)
        #expect(fixture.requests.contains { $0.path == "/new.png" })
        #expect(fixture.requests.allSatisfy { ["/", "/old.png", "/favicon.ico", "/new.png"].contains($0.path) })
        #expect(tab.address == page && tab.builtPage == nil && tab.asleep)
        // A stopped transport also leaves the last good bitmap intact.
        fixture.stop()
        icons.refresh(tab)
        let stoppedUntil = Date().addingTimeInterval(4)
        while icons.busy.contains(site), Date() < stoppedUntil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!icons.busy.contains(site))
        #expect(icons.cached(site) === refreshed)
        #expect(icons.cached("sibling.example.test") === sibling)
    }

    @Test func privateCustomAndNonWebTabsCannotStartARefresh() async throws {
        let fixture = try LocalNetworkFixture()
        defer { fixture.stop() }
        let privateTab = Tab(shy: true), custom = Tab(), local = Tab()
        privateTab.restore(url: URL(string: fixture.root + "/private")!, title: "Private")
        custom.customMark = "A"
        custom.restore(url: URL(string: fixture.root + "/custom")!, title: "Custom")
        local.restore(url: URL(fileURLWithPath: "/tmp/local-page.html"), title: "Local")
        defer { [privateTab, custom, local].forEach { $0.close() } }
        let icons = Favicons()
        for tab in [privateTab, custom, local] {
            #expect(!Favicons.canRefresh(tab))
            icons.refresh(tab)
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.requests.isEmpty)
        #expect([privateTab, custom, local].allSatisfy { $0.builtPage == nil })
        #expect(custom.customMark == "A")
    }

    private func settled(_ icons: Favicons, host: String) async throws {
        let until = Date().addingTimeInterval(4)
        while icons.busy.contains(host), Date() < until {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!icons.busy.contains(host))
    }

    private func color(_ icons: Favicons, key: String) throws -> NSColor {
        let image = try #require(icons.cached(key))
        let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        return try #require(bitmap.colorAt(x: 16, y: 16)?.usingColorSpace(.deviceRGB))
    }

    private func cacheable(_ text: String, body: Data? = nil) -> LocalNetworkFixture.Reply {
        var reply = LocalNetworkFixture.Reply(text)
        reply.cacheControl = "public, max-age=3600"
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.timeZone = TimeZone(secondsFromGMT: 0)
        date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        reply.headers = "Date: \(date.string(from: Date()))\r\n"
        if let body { reply.type = "image/png"; reply.body = body }
        return reply
    }

    @Test func manualRefreshBypassesCachedMarkupAndIconBytes() async throws {
        let fixture = try LocalNetworkFixture()
        defer { fixture.stop() }
        let page = URL(string: fixture.root + "/")!
        let icon = URL(string: fixture.root + "/site.png")!
        fixture.route("/", cacheable("<link rel='icon' href='/site.png' sizes='32x32'>"))
        fixture.route("/site.png", cacheable("", body: try png(.systemRed)))
        let icons = Favicons()
        let site = try #require(Favicons.site(page))
        icons.fetch(page: page, again: true)
        try await settled(icons, host: site)
        let red = try color(icons, key: site)
        #expect(red.redComponent > red.blueComponent)

        fixture.route("/site.png", cacheable("", body: try png(.systemBlue)))
        // A normal icon lookup must still reuse the fresh HTTP response.
        // It uses a different bitmap key, so Favicons' own cache cannot hide it.
        let automatic = "automatic-832-" + UUID().uuidString
        icons.fetch(icon, as: automatic)
        try await settled(icons, host: automatic)
        let stillRed = try color(icons, key: automatic)
        #expect(stillRed.redComponent > stillRed.blueComponent)
        #expect(fixture.requests.filter { $0.path == "/site.png" }.count == 1)

        // Explicit refresh must go back to the same cacheable icon URL.
        icons.fetch(page: page, again: true)
        try await settled(icons, host: site)
        let blue = try color(icons, key: site)
        #expect(blue.blueComponent > blue.redComponent)
        #expect(fixture.requests.filter { $0.path == "/site.png" }.count == 2)

        // A changed cacheable root document must also be re-read.
        fixture.route("/", cacheable("<link rel='icon' href='/changed.png' sizes='32x32'>"))
        fixture.route("/changed.png", cacheable("", body: try png(.systemGreen)))
        icons.fetch(page: page, again: true)
        try await settled(icons, host: site)
        let green = try color(icons, key: site)
        #expect(green.greenComponent > green.redComponent && green.greenComponent > green.blueComponent)
        #expect(fixture.requests.filter { $0.path == "/" }.count == 3)
        #expect(fixture.requests.contains { $0.path == "/changed.png" })
    }

    @Test func publicIconRequestsDoNotCarryCookiesBetweenCandidates() async throws {
        let fixture = try LocalNetworkFixture()
        defer { fixture.stop() }
        fixture.route("/", .init("<link rel='icon' href='/invalid.png' sizes='64x64'><link rel='icon' href='/valid.png' sizes='32x32'>",
                                headers: "Set-Cookie: root832=synthetic; Path=/\r\n"))
        fixture.route("/invalid.png", .init(String(repeating: "not an image ", count: 12),
                                           headers: "Set-Cookie: icon832=synthetic; Path=/\r\n"))
        var valid = LocalNetworkFixture.Reply("")
        valid.type = "image/png"; valid.body = try png(.systemBlue)
        fixture.route("/valid.png", valid)
        let icons = Favicons()
        let site = try #require(Favicons.site(URL(string: fixture.root)!))
        icons.fetch(page: URL(string: fixture.root + "/")!, again: true)
        try await settled(icons, host: site)
        let blue = try color(icons, key: site)
        #expect(blue.blueComponent > blue.redComponent)
        let publicRequests = fixture.requests.filter { ["/", "/invalid.png", "/valid.png"].contains($0.path) }
        #expect(publicRequests.count == 3)
        #expect(publicRequests.allSatisfy { !$0.headers.lowercased().contains("\r\ncookie:") })

        // A separate ordinary transport still handles its own synthetic
        // cookies. Nothing changes the shared artwork session or its jar.
        fixture.route("/seed", .init("seed", headers: "Set-Cookie: ordinary832=synthetic; Path=/\r\n"))
        fixture.route("/ordinary", .init("ordinary"))
        let ordinary = URLSession(configuration: .ephemeral)
        defer { ordinary.invalidateAndCancel() }
        _ = try await ordinary.data(from: URL(string: fixture.root + "/seed")!)
        _ = try await ordinary.data(from: URL(string: fixture.root + "/ordinary")!)
        let other = try #require(fixture.requests.last { $0.path == "/ordinary" })
        #expect(other.headers.contains("ordinary832=synthetic"))
    }

}
