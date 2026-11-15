import AppKit
import Testing
@testable import SyncKit
@testable import Fast

/// Actual application delegate, with only its final tab destination injected.
/// No windows, Apple ID, default-browser setting or network are touched.
@MainActor
struct HandoffReceiverTests {
    @Test func browserTemplateDeclaresSafariWebHandoff() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = ProcessInfo.processInfo.environment["YAB_HANDOFF_BUILD_SOURCE"].map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent("build.sh")
        let template = try String(contentsOf: source, encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #"<key>NSUserActivityTypes</key>\s*(<array>[\s\S]*?</array>)"#)
        let match = try #require(pattern.firstMatch(in: template, range: NSRange(template.startIndex..., in: template)))
        let range = try #require(Range(match.range(at: 1), in: template))
        let xml = Data(("<plist version=\"1.0\">" + String(template[range]) + "</plist>").utf8)
        let decoded = try PropertyListSerialization.propertyList(from: xml, format: nil)
        let types = try #require(decoded as? [String])
        #expect(types.contains(NSUserActivityTypeBrowsingWeb),
                "default-browser Handoff requires the packaged BrowsingWeb activity declaration")
        #expect(types.contains(ContinuePage.type))
        #expect(types.contains("INSendMessageIntent"))
    }

    @Test func aSafariActivityDispatchesItsExactWebAddress() {
        let url = URL(string: "https://example.invalid/a?b=1#position")!
        let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        activity.webpageURL = url
        var deliveries: [ContinuePage.Arrival] = []
        let receiver = Links(continueWebPage: { deliveries.append(.init(url: $0, space: $1)) })
        #expect(receiver.application(NSApplication.shared, continue: activity, restorationHandler: { _ in }))
        #expect(deliveries == [.init(url: url, space: nil)])
    }

    @Test func aYabActivityPreservesItsSpaceAndAddress() {
        let url = URL(string: "https://example.invalid/page")!
        let activity = NSUserActivity(activityType: ContinuePage.type)
        activity.webpageURL = url
        activity.userInfo = [ContinuePage.spaceKey: "  SPACE-1  "]
        var deliveries: [ContinuePage.Arrival] = []
        let receiver = Links(continueWebPage: { deliveries.append(.init(url: $0, space: $1)) })
        #expect(receiver.application(NSApplication.shared, continue: activity, restorationHandler: { _ in }))
        #expect(deliveries == [.init(url: url, space: "SPACE-1")])
    }

    @Test func unknownActivityAndUnsafeAddressesAreNotDispatched() {
        var delivered = 0
        let receiver = Links(continueWebPage: { _, _ in delivered += 1 })
        let cases: [(String, String?)] = [("unrelated.activity", "https://example.invalid"),
                                          (ContinuePage.webType, nil),
                                          (ContinuePage.webType, "https://name:secret@example.invalid")]
        for (type, address) in cases {
            let activity = NSUserActivity(activityType: type)
            activity.webpageURL = address.flatMap(URL.init(string:))
            #expect(!receiver.application(NSApplication.shared, continue: activity, restorationHandler: { _ in }))
        }
        #expect(delivered == 0)
    }
}
