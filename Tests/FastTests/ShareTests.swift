import AppKit
import CoreMedia
import Testing
import WebKit
@testable import Fast

// Sharing a screen (Share.swift): the picture's size, where a tab is in its
// window as ScreenCaptureKit counts it, and the codec a page is told.
struct ShareTests {
    /// macOS's own picker on Safari 18's WebKit (request 904): the flag
    /// that WebKit reads before showing it is on for every tab's page. It
    /// is there on WebKit 620 and 621 (macOS 15 with Safari 18) and gone
    /// from 622 (Safari 26, macOS 15 included), where nothing is set.
    @MainActor @Test func systemPickerFlag() {
        let preferences = WKPreferences()
        let had = WebFeature.isOn("UseSCContentSharingPicker", in: preferences)
        #expect((had != nil) == (Self.webKitBuild < 622), "WebKit \(Self.webKitBuild)")
        Web.systemSharePicker(preferences)
        let now = WebFeature.isOn("UseSCContentSharingPicker", in: preferences)
        if had == nil { #expect(now == nil) } else { #expect(now == true) }
    }

    /// The way the flag is set works on an internal flag every WebKit has
    /// (UseSCContentSharingPicker is internal too): on, read back, off.
    @MainActor @Test func internalFlagSets() {
        let preferences = WKPreferences()
        #expect(WebFeature.set("MockCaptureDevicesEnabled", true, in: preferences))
        #expect(WebFeature.isOn("MockCaptureDevicesEnabled", in: preferences) == true)
        #expect(WebFeature.set("MockCaptureDevicesEnabled", false, in: preferences))
        #expect(WebFeature.isOn("MockCaptureDevicesEnabled", in: preferences) == false)
    }

    /// WebKit's build: 624 for "21624.1.16.11.4" (the digits before it
    /// name the macOS it was made for).
    static var webKitBuild: Int {
        let version = Bundle(for: WKWebView.self).infoDictionary?["CFBundleVersion"] as? String ?? ""
        return (Int(version.split(separator: ".").first ?? "") ?? 0) % 1000
    }

    /// Whole, even pixels, a Retina tab at twice its points.
    @Test func pixelsAreEven() {
        let size = ShareFeed.pixels(CGSize(width: 884.5, height: 511.3), scale: 2)
        #expect(size.width == 1768)
        #expect(size.height == 1022)
        #expect(size.width % 2 == 0 && size.height % 2 == 0)
    }

    /// A 5K screen comes down to 1080p's worth of pixels, its shape kept.
    @Test func pixelsAreCapped() {
        let size = ShareFeed.pixels(CGSize(width: 2560, height: 1440), scale: 2)
        #expect(size.width == 1920)
        #expect(size.height == 1080)
        let small = ShareFeed.pixels(CGSize(width: 1, height: 1), scale: 1)
        #expect(small.width == 2 && small.height == 2)
    }

    /// The page's own largest size wins when it is smaller.
    @Test func pixelsTakeThePagesMost() {
        let size = ShareFeed.pixels(CGSize(width: 1440, height: 900), scale: 2, most: CGSize(width: 1280, height: 0))
        #expect(size.width == 1280)
        #expect(size.height == 800)
    }

    /// Where a shown tab goes, as its row says: the service's name for the
    /// calls Yab knows, the site otherwise.
    @MainActor @Test func callNames() {
        let names = [
            "https://meet.google.com/abc-defg-hij": "Meet",
            "https://us02web.zoom.us/j/123": "Zoom",
            "https://teams.microsoft.com/l/meetup-join/1": "Teams",
            "https://app.slack.com/huddle/T1/C1": "Slack",
            "https://acme.webex.com/meet/jane": "Webex",
            "https://www.example.com/room": "example.com",
        ]
        for (address, name) in names {
            #expect(Share.callName(at: URL(string: address)) == name)
        }
        #expect(Share.callName(at: nil) == "the call")
    }

    /// A view's place, counted from the window's top left.
    @MainActor @Test func placeFromTheTop() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless], backing: .buffered, defer: true)
        let view = NSView(frame: NSRect(x: 8, y: 8, width: 884, height: 512))
        window.contentView?.addSubview(view)
        #expect(Share.place(of: view, in: window) == CGRect(x: 8, y: 80, width: 884, height: 512))
    }

    /// The avcC box's profile, compatibility and level, as WebCodecs names them.
    @Test func codecFromAvcC() throws {
        // avcC: version 1, High (0x64), no constraints, level 3.0 (0x1e),
        // then a 640 × 480 picture's SPS and PPS, as x264 wrote them.
        let sps: [UInt8] = [0x67, 0x64, 0x00, 0x1e, 0xac, 0xd9, 0x40, 0xa0, 0x3d, 0xb0, 0x11, 0x00, 0x00, 0x03, 0x00, 0x01, 0x00, 0x00, 0x03, 0x00, 0x32, 0x0f, 0x16, 0x2d, 0x96]
        let pps: [UInt8] = [0x68, 0xeb, 0xe3, 0xcb, 0x22, 0xc0]
        var format: CMFormatDescription?
        let status = sps.withUnsafeBufferPointer { s in
            pps.withUnsafeBufferPointer { p in
                let sets = [s.baseAddress!, p.baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: sets,
                                                                          parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
        }
        #expect(status == noErr)
        let made = try #require(format)
        let described = try #require(ShareFeed.format(made))
        #expect(described.codec == "avc1.64001e")
        #expect(described.width == 640 && described.height == 480)
        #expect(described.description.first == 1)
    }
}
