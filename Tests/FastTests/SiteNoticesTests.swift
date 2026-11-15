import AppKit
import Foundation
import Testing
import UserNotifications
import YabCoreClient
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
        #expect(site.count == 2)
        let category = site.first { $0.identifier == SiteNotices.category }
        #expect(category?.actions.map(\.identifier) == [SiteNotices.turnOff, SiteNotices.controls])
        // Swept away is heard, so the page's onclose fires.
        #expect(category?.options.contains(.customDismissAction) == true)
        // An extension's has no site to turn off, and its onClosed hears a sweep.
        let own = site.first { $0.identifier == SiteNotices.extensionCategory }
        #expect(own?.actions.isEmpty == true)
        #expect(own?.options.contains(.customDismissAction) == true)
        let all = MailNotifySystem.categories.union(site)
        #expect(Set(all.map(\.identifier)) == [MailNotify.category, MailNotify.batchCategory, MailNotify.codeCategory,
                                                SiteNotices.category, SiteNotices.extensionCategory])
        let code = all.first { $0.identifier == MailNotify.codeCategory }
        #expect(code?.actions.map(\.identifier) == [MailNotify.Act.copyCode.rawValue, MailNotify.Act.done.rawValue])
    }

    // chrome.notifications, as Chromium's macOS service hands it over: its
    // origin the extension's, its id the extension's own (which may start
    // with "p", as a worker's does), its subtitle the contextMessage.
    static let fromExtension: [String: JSONValue] = [
        "op": .string("show"), "key": .string("k1"), "id": .string("pkehgijcmpdhfbdbbnkijodmdjhbjlgp-timer"),
        "origin": .string("chrome-extension://pkehgijcmpdhfbdbbnkijodmdjhbjlgp/"), "profile": .string("space-default"),
        "incognito": .bool(false), "type": .number(2), "directory": .string("/tmp/Chromium"),
        "title": .string("40% - Focus"), "subtitle": .string("Work block"), "body": .string("20 minutes left"),
        "buttons": .array([.string("Pause"), .string("Stop")]),
    ]

    @Test func anExtensionsIsToldApartByItsOrigin() throws {
        let chromium = try #require(SiteNotices.Chromium(event: Self.fromExtension))
        #expect(chromium.extensionID == "pkehgijcmpdhfbdbbnkijodmdjhbjlgp")
        #expect(chromium.worker == false)
        #expect(chromium.tag == "")
        #expect(chromium.subtitle == "Work block")
        #expect(chromium.buttons == ["Pause", "Stop"])
        var site = Self.fromExtension
        site["origin"] = .string("https://app.slack.com/")
        site["id"] = .string("p#https://app.slack.com/#1design")
        site["type"] = .number(0)
        let page = try #require(SiteNotices.Chromium(event: site))
        #expect(page.extensionID == nil)
        #expect(page.worker && page.tag == "design")
        site["origin"] = .string("chrome-extension://not-an-id/")
        #expect(SiteNotices.Chromium(event: site)?.extensionID == nil)
    }

    @MainActor @Test func anExtensionsSaysItsNameNotItsID() throws {
        _ = NSApplication.shared
        let chromium = try #require(SiteNotices.Chromium(event: Self.fromExtension))
        let origin = try #require(SiteNotices.origin(webKit: chromium.origin))
        var note = SiteNotices.Note(id: 7, worker: false, origin: origin, title: "40% - Focus", body: "20 minutes left",
                                    tag: "", icon: "", tab: nil, chromium: chromium)
        note.from = "Focus Timer"
        var content = SiteNotices.content(note)
        #expect(content.title == "40% - Focus")
        #expect(content.subtitle == "Focus Timer · Work block")
        #expect(content.categoryIdentifier == SiteNotices.extensionCategory)
        #expect(content.threadIdentifier == SiteNotices.thread(origin))
        // Shown over its own page too.
        #expect(SiteNotices.presenting(content.userInfo).contains(.banner))
        note.title = ""
        note.chromium?.subtitle = ""
        content = SiteNotices.content(note)
        #expect(content.title == "Focus Timer")
        #expect(content.subtitle == "Focus Timer")
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
