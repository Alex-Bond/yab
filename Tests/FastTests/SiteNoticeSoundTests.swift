import AppKit
import Testing
import UserNotifications
@testable import Fast

@MainActor @Suite(.serialized)
struct SiteNoticeSoundTests {
    // WKNotificationGetAlert maps omitted/null silent to 1, true to 2,
    // and false to 4. Nil covers a WebKit without that optional symbol.
    static let alerts: [UInt32?] = [nil, 1, 2, 4, 0, 8]

    @Test(arguments: alerts, [false, true])
    func pageOptionsReachNativeContent(_ alert: UInt32?, worker: Bool) {
        _ = NSApplication.shared
        let tab = UUID()
        let note = SiteNotices.Note(id: 1469, worker: worker, origin: "https://notification-sound.invalid:443",
                                   title: "New message", body: "Message body", tag: "conversation", icon: "", tab: tab,
                                   alert: SiteNotices.Alert(webKit: alert))
        let content = SiteNotices.content(note)
        let silent = alert == 2
        if silent {
            #expect(content.sound == nil)
        } else {
            #expect(content.sound?.isEqual(UNNotificationSound.default) == true)
        }
        #expect(content.title == note.title)
        #expect(content.subtitle == note.host)
        #expect(content.body == note.body)
        #expect(content.threadIdentifier == SiteNotices.thread(note.origin))
        #expect(content.categoryIdentifier == SiteNotices.category)
        #expect(content.userInfo["site"] as? String == note.origin)
        #expect(content.userInfo["note"] as? String == "1469")
        #expect(content.userInfo["worker"] as? Bool == worker)
        #expect(content.userInfo["tab"] as? String == tab.uuidString)
        #expect(content.userInfo["silent"] as? Bool == silent)
        let options = SiteNotices.presenting(content.userInfo)
        #expect(options.contains(.banner) && options.contains(.list))
        #expect(options.contains(.sound) == !silent)
    }

    @Test func omittedOptionsAndOlderNotificationsKeepDefaultSound() {
        _ = NSApplication.shared
        let note = SiteNotices.Note(id: 1470, worker: false, origin: "https://notification-sound.invalid:443",
                                   title: "", body: "Message body", tag: "", icon: "", tab: nil)
        let content = SiteNotices.content(note)
        #expect(content.sound?.isEqual(UNNotificationSound.default) == true)
        #expect(content.title == note.host)
        var info = content.userInfo
        info.removeValue(forKey: "silent")
        #expect(SiteNotices.presenting(info).contains(.sound))
    }
}
