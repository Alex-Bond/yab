import Foundation
import Testing
@testable import Fast

@Suite @MainActor struct SitePermissionsTests {
    @Test func everyRememberedAnswerReachesChromiumUnderItsOwnName() {
        let table = ChromiumPermissions.wanted([
            "notifications.https://chat.example:443": true,
            "notifications.http://localhost:3000": false,
            "capture.https://call.example:443|0": true,
            "capture.https://call.example:443|1": false,
            "capture.https://both.example:8443|2": true,
            "capture.old.example|0": true,
            "location.maps.example": true,
            "location.https://maps.test:8443": false,
            "permission.clipboard.https://docs.example:443": true,
            "permission.fonts.https://design.example:443": true,
            "permission.fonts.https://blocked.example:443": false,
            "permission.top-storage.https://embed.example:443": false,
            "permission.protocol.https://mail.example:443": true,
            "localNetwork.allowed": ["https://nas.example:443|loopback", "https://nas.example:443|local"],
            "windows.allowed": ["app.example"],
            "unrelated": true, "notifications.nonsense": true,
        ])
        #expect(table == [
            "https://chat.example|notifications": "allow",
            "http://localhost:3000|notifications": "block",
            "https://call.example|camera": "allow",
            "https://call.example|microphone": "block",
            "https://both.example:8443|camera": "allow",
            "https://both.example:8443|microphone": "allow",
            "https://old.example|camera": "allow",
            "https://maps.example|location": "allow",
            "https://maps.test:8443|location": "block",
            "https://docs.example|clipboard": "allow",
            "https://design.example|fonts": "allow",
            "https://blocked.example|fonts": "block",
            "https://embed.example|top-storage": "block",
            "https://nas.example|loopback-network": "allow",
            "https://nas.example|local-network": "allow",
            "https://app.example|popups": "allow",
            "https://www.app.example|popups": "allow",
        ])
    }

    /// A site's automatic downloads are said for the site and kept by
    /// Chromium per origin: told on each origin the answer was given on, and
    /// a site said for with no origin known is told nothing (YabCore lets
    /// its files on to Yab's own card there).
    @Test func automaticDownloadsReachChromiumOnTheOriginsTheyWereSaidOn() {
        let table = ChromiumPermissions.wanted([
            "downloads.many.google.com": true,
            "downloads.askedOn.google.com": ["https://drive.google.com:443", "https://docs.google.com:443"],
            "downloads.many.localhost": false,
            "downloads.askedOn.localhost": ["http://localhost:8080"],
            "downloads.many.example.org": false,
        ])
        #expect(table == [
            "https://drive.google.com|automatic-downloads": "allow",
            "https://docs.google.com|automatic-downloads": "allow",
            "http://localhost:8080|automatic-downloads": "block",
        ])
    }

    @Test func aForgottenAutomaticDownloadsAnswerIsTakenBackInChromium() {
        let host = "drive.automatic-downloads-test.example"
        defer { SiteDownloads.forgetMany(host) }
        SiteDownloads.rememberMany(host, false, origin: "https://\(host):443")
        SiteDownloads.rememberMany(host, true, origin: "https://\(host):443")
        let said = ChromiumPermissions.wanted()
        #expect(said["https://\(host)|automatic-downloads"] == "allow")
        SiteDownloads.forgetMany(host)
        let rows = ChromiumPermissions.changes(from: said, to: ChromiumPermissions.wanted())
        #expect(rows.contains { $0.origin == "https://\(host)" && $0.kind == "automatic-downloads" && $0.value == "default" })
    }

    @Test func aTakenBackAnswerIsTakenBackInChromium() {
        let applied = ["https://a.example|camera": "allow", "https://b.example|notifications": "allow", "https://c.example|location": "block"]
        let wanted = ["https://a.example|camera": "block", "https://c.example|location": "block", "https://d.example|fonts": "allow"]
        let rows = ChromiumPermissions.changes(from: applied, to: wanted)
        #expect(rows.map(\.origin) == ["https://a.example", "https://b.example", "https://d.example"])
        #expect(rows.map(\.kind) == ["camera", "notifications", "fonts"])
        #expect(rows.map(\.value) == ["block", "default", "allow"])
        #expect(ChromiumPermissions.changes(from: wanted, to: wanted).isEmpty)
    }

    @Test func aCardNeverSaysAQuestionOnlyInChromiumsOwnWords() {
        for kind in SitePermission.allCases {
            #expect(!kind.title.isEmpty && !kind.words.isEmpty && !kind.symbol.isEmpty)
            #expect(!kind.words.contains("Chrome") && !kind.words.contains("\u{2014}"))
        }
    }

    @Test func anExtensionAsksByItsNameAndASiteByItsHost() throws {
        let id = String(repeating: "b", count: 32)
        let item = try ChromiumExtensions.Item(.object(["id": .string(id), "name": .string("Folder Notes"), "state": .string("ENABLED")]))
        let blank = try ChromiumExtensions.Item(.object(["id": .string(String(repeating: "c", count: 32)), "name": .string(" "), "state": .string("ENABLED")]))
        #expect(SitePermission.asker(PageOrigin(scheme: "chrome-extension", host: id, port: 0), extensions: [item]) == "Folder Notes")
        // Not installed here, or nameless: its id, never nothing.
        #expect(SitePermission.asker(PageOrigin(scheme: "chrome-extension", host: id, port: 0), extensions: []) == id)
        #expect(SitePermission.asker(PageOrigin(scheme: "chrome-extension", host: blank.id, port: 0), extensions: [blank]) == blank.id)
        // A site whose host happens to be an id is still a site.
        #expect(SitePermission.asker(PageOrigin(scheme: "https", host: id, port: 0), extensions: [item]) == id)
        #expect(SitePermission.asker(PageOrigin(scheme: "https", host: "photos.example", port: 0), extensions: [item]) == "photos.example")
        #expect(SitePermission.asker(PageOrigin(scheme: "file", host: "", port: 0), extensions: [item]) == nil)
    }

    @Test func aChromiumIdGivesBackTheSiteTag() {
        let chromium = { (id: String) in SiteNotices.Chromium(fields: ["id": id])! }
        #expect(chromium("p#https://a.example/#1room-7").tag == "room-7")
        #expect(chromium("p#https://a.example/#1a#b").tag == "a#b")
        #expect(chromium("p#https://a.example/#0123").tag == "")
        #expect(chromium("pb#https://a.example/#1room").tag == "room")
        #expect(chromium("n#https://a.example/#token").tag == "")
        #expect(chromium("p#https://a.example/#1x").worker)
        #expect(!chromium("n#https://a.example/#token").worker)
    }
}
