import AppKit
import Foundation
import Testing
@testable import Fast

/// Yab on a phone in the Mac app (PhoneBeta): the code a phone's camera reads
/// is that phone's link, the row sits under Set up Yab in the user's own
/// words, and Return copies the chosen phone's link.
struct PhoneBetaTests {
    @MainActor
    @Test func theCodeOpensTestFlight() throws {
        #expect(PhoneBeta.link.absoluteString == "https://testflight.apple.com/join/EJY6AEHB")
        #expect(YabPhone.iPhone.shown == "testflight.apple.com/join/EJY6AEHB")
        let image = try #require(QRCode.image(PhoneBeta.link.absoluteString, side: 132))
        #expect(QRCode.read(image) == PhoneBeta.link.absoluteString)
    }

    @MainActor
    @Test func theOtherCodeDownloadsTheAlpha() throws {
        #expect(YabPhone.android.shown == "yetanotherbrowser.com/android.apk")
        #expect(YabPhone.android.other == .iPhone)
        let image = try #require(QRCode.image(YabPhone.android.link.absoluteString, side: 132))
        #expect(QRCode.read(image) == YabPhone.android.link.absoluteString)
    }

    @Test func anAndroidListsAsItself() {
        #expect(SyncPhones.isAndroid("Android Google Pixel 9"))
        #expect(!SyncPhones.isAndroid("iPhone17,1"))
        #expect(!SyncPhones.isPhone("Android Google Pixel 9"), "isPhone stays Apple's: Continue and approvals go by it")
    }

    @MainActor
    @Test func theRowIsASetUpRowAndKnowsItself() {
        let hint = PhoneBeta.hint
        #expect(hint.id == PhoneBeta.hintID)
        #expect(hint.setup)
        #expect(hint.url == nil, "a Mac can't open it: Return copies the link")
        #expect(hint.title == "Put Yab on my phone")
        #expect(!hint.title.contains("\u{2014}") && !hint.detail.contains("\u{2014}"))
        #expect(PhoneBeta.offered(Suggestion(key: hint.title, title: hint.detail, url: nil, kind: .hint(hint.id))))
        #expect(!PhoneBeta.offered(Suggestion(key: "Get to know me", title: "", url: nil, kind: .hint("setup.memory"))))
    }

    @MainActor
    @Test func setUpRowsComeLastWithThePhoneFirstAmongThem() {
        let other = Hint(id: "setup.watch", icon: .symbol("eye"), title: "Keep an eye on things for me", detail: "", setup: true)
        let order = Hints.order(found: [], noticed: [], setup: [PhoneBeta.hint, other], now: Date())
        #expect(order.map(\.id) == [PhoneBeta.hintID, "setup.watch"])
    }
}
