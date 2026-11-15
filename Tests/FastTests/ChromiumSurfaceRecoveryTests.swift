import AppKit
import Testing
import YabCoreClient
@testable import Fast

@Suite(.serialized)
@MainActor
struct ChromiumSurfaceRecoveryTests {
    @Test(arguments: ["unhide", "sight", "surface", "focus"])
    func sameSizeBackingReplacementRecoversWithoutAResize(_ trigger: String) {
        _ = NSApplication.shared
        let tab = Tab(shy: true), page = ChromiumPage(tab: tab)
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        page.frame = NSRect(x: 0, y: 0, width: 1084, height: 796)
        #expect(page.surfaceState["parentAttached"] as? Bool == true)
        let frame = page.frame
        // AppKit can replace the backing while a popup takes the stage. Keep
        // the same view and size: layout/DevTools must not be the repair.
        page.layer = CALayer()
        // Hosted on the new backing as it arrives (ChromiumPage.layer); the
        // events below must keep it so and change nothing else.
        #expect(page.surfaceState["parentAttached"] as? Bool == true)
        switch trigger {
        case "unhide": page.viewDidUnhide()
        case "sight": page.sightChanged()
        case "focus": page.focusChanged()
        default:
            page.receive(YabCoreEvent(name: "layer.changed", params: [
                "contextId": .number(0), "width": .number(1084), "height": .number(796),
                "source": .string("cefCallback")]))
        }
        #expect(page.frame == frame)
        #expect(page.remoteID == nil, "Attachment repair must not create a helper")
        #expect(page.surfaceState["parentAttached"] as? Bool == true)
    }

    /// Alpha 11-05 (blank until a resize): nothing but AppKit replacing the
    /// backing, with no key window, unhide, occlusion or helper event after
    /// it. The page must stay hosted; a resize is not the repair.
    @Test func backingReplacementAloneKeepsThePageHosted() {
        _ = NSApplication.shared
        let tab = Tab(shy: true), page = ChromiumPage(tab: tab)
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        page.frame = NSRect(x: 0, y: 0, width: 1084, height: 796)
        page.layer = CALayer()
        #expect(page.surfaceState["parentAttached"] as? Bool == true, "Blank until resize: the remote page hangs from the old backing")
        #expect(page.surfaceState["parentBounds"] as? [CGFloat] == [0, 0, 1084, 796])
    }

    /// A cross-process navigation or renderer swap keeps the window
    /// compositor's context. The helper names the new owner (generation,
    /// renderer); the client re-checks its host on that word, so a host
    /// lost meanwhile comes back with no resize.
    @Test func aNewSurfaceOwnerOnTheSameContextIsHostedWithoutAResize() throws {
        _ = NSApplication.shared
        let tab = Tab(shy: true), page = ChromiumPage(tab: tab)
        let remote = "surface-owner-" + UUID().uuidString
        page.adoptRemote(remote)
        defer { page.retire(call: false, pictureInPicture: false); ChromiumProcess.shared.detach(remote); tab.close() }
        page.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        func surface(generation: Double, renderer: Double) -> [String: JSONValue] {
            ["tab": .string(remote), "source": .string("cefCallback"), "contextId": .number(7),
             "width": .number(1000), "height": .number(700), "visible": .bool(true),
             "generation": .number(generation), "renderer": .number(renderer)]
        }
        page.receive(YabCoreEvent(name: "layer.changed", params: surface(generation: 1, renderer: 100)))
        #expect(page.contextID == 7)
        let parent = try #require(page.layer?.sublayers?.first { $0.isGeometryFlipped })
        let host = try #require(parent.sublayers?.first)
        #expect(host.value(forKey: "contextId") as? NSNumber == 7)
        // The old document's host goes while its renderer is replaced.
        host.removeFromSuperlayer()
        page.receive(YabCoreEvent(name: "layer.changed", params: surface(generation: 2, renderer: 200)))
        let rebound = parent.sublayers?.first
        #expect(rebound?.value(forKey: "contextId") as? NSNumber == 7, "Blank until resize: same context, no host")
        #expect(page.surfaceState["ownerGeneration"] as? Double == 2)
        #expect(page.surfaceState["ownerRenderer"] as? Double == 200)
    }
}
