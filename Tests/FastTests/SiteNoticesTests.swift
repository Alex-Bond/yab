import AppKit
import Foundation
import Testing
import UserNotifications
@testable import Fast

// A site's notifications (SiteNotices.swift): how an origin is written for
// Yab and for WebKit, where a notification goes in Notification Center, and
// what a click carries back.
struct SiteNoticesTests {
    @Test func webKitWritesNoPortOfTheSchemesOwn() {
        #expect(SiteNotices.webKitOrigin("https://app.slack.com:443") == "https://app.slack.com")
        #expect(SiteNotices.webKitOrigin("http://murmur.localhost:80") == "http://murmur.localhost")
        #expect(SiteNotices.webKitOrigin("http://murmur.localhost:8080") == "http://murmur.localhost:8080")
        #expect(SiteNotices.webKitOrigin("https://example.com:8443") == "https://example.com:8443")
        // 443 is only https's own.
        #expect(SiteNotices.webKitOrigin("http://example.com:443") == "http://example.com:443")
    }

    @Test func andBackAsYabKeepsIt() {
        #expect(SiteNotices.origin(webKit: "https://app.slack.com") == "https://app.slack.com:443")
        #expect(SiteNotices.origin(webKit: "http://Murmur.localhost:5173") == "http://murmur.localhost:5173")
        #expect(SiteNotices.origin(webKit: "http://murmur.localhost") == "http://murmur.localhost:80")
        #expect(SiteNotices.origin(webKit: "") == nil)
        #expect(SiteNotices.origin(webKit: "null") == nil)
        for origin in ["https://mail.google.com:443", "http://localhost:3000", "http://a.test:80"] {
            #expect(SiteNotices.origin(webKit: SiteNotices.webKitOrigin(origin)) == origin)
        }
    }

    @MainActor @Test func theSameWayTheCameraIsKept() {
        let origin = Browser.origin(scheme: "HTTPS", host: "App.Slack.com", port: 0)
        #expect(origin == "https://app.slack.com:443")
        #expect(SiteNotices.key(origin) == "notifications.https://app.slack.com:443")
        #expect(SiteNotices.origin(webKit: "https://app.slack.com") == origin)
    }

    @Test func aTagTakesTheLastOnesPlace() {
        let site = "https://app.slack.com:443"
        #expect(SiteNotices.request(origin: site, tag: "design", id: 7) == SiteNotices.request(origin: site, tag: "design", id: 9))
        #expect(SiteNotices.request(origin: site, tag: "", id: 7) != SiteNotices.request(origin: site, tag: "", id: 9))
        #expect(SiteNotices.request(origin: site, tag: "design", id: 7) != SiteNotices.request(origin: "https://other.com:443", tag: "design", id: 7))
        #expect(SiteNotices.thread(site) == "site.https://app.slack.com:443")
    }

    @Test func aClickCarriesItsSiteNoteAndTab() {
        let tab = UUID()
        let note = SiteNotices.Note(id: 42, worker: true, origin: "http://murmur.localhost:8080", title: "Anna Ek in #design",
                                    body: "Pushed new frames", tag: "design", icon: "", tab: tab)
        let info = SiteNotices.info(note)
        #expect(info["site"] as? String == "http://murmur.localhost:8080")
        #expect(info["note"] as? String == "42")
        #expect(info["worker"] as? Bool == true)
        #expect(info["tab"] as? String == tab.uuidString)
        // Mail's notifications are told apart by "mail"; a site's never has it.
        #expect(info["mail"] == nil)
        #expect(note.host == "murmur.localhost")
    }

    @Test func itsButtonsAndMailsAreOneSet() {
        let site = SiteNotices.categories
        #expect(site.count == 1)
        let category = site.first
        #expect(category?.identifier == SiteNotices.category)
        #expect(category?.actions.map(\.identifier) == [SiteNotices.turnOff, SiteNotices.controls])
        // Swept away is heard, so the page's onclose fires.
        #expect(category?.options.contains(.customDismissAction) == true)
        let all = MailNotifySystem.categories.union(site)
        #expect(Set(all.map(\.identifier)) == [MailNotify.category, MailNotify.batchCategory, MailNotify.codeCategory, SiteNotices.category])
        let code = all.first { $0.identifier == MailNotify.codeCategory }
        #expect(code?.actions.map(\.identifier) == [MailNotify.Act.copyCode.rawValue, MailNotify.Act.done.rawValue])
    }

    @Test func aPictureIsMadeSmallAndPNG() throws {
        let big = NSImage(size: NSSize(width: 1024, height: 512))
        big.lockFocus()
        NSColor.systemOrange.setFill()
        NSRect(x: 0, y: 0, width: 1024, height: 512).fill()
        big.unlockFocus()
        let tiff = try #require(big.tiffRepresentation)
        let png = try #require(SiteNotices.png(tiff))
        let image = try #require(NSBitmapImageRep(data: png))
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(image.pixelsWide == 256 && image.pixelsHigh == 128)
        #expect(SiteNotices.png(Data("not a picture".utf8)) == nil)
    }

    @Test func aScriptsSelectorIsQuoted() {
        #expect(SiteNotices.quoted("#turnOn") == "\"#turnOn\"")
        #expect(SiteNotices.quoted("a[title=\"x\"]") == "\"a[title=\\\"x\\\"]\"")
    }
}
