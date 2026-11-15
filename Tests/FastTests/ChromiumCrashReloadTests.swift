import AppKit
import Testing
import YabCoreClient
@testable import Fast

@MainActor @Suite(.serialized)
struct ChromiumCrashReloadTests {
    @Test func rendererCrashPreservesTheNativeViewportForReload() throws {
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab)
        let remote = "crash-reload-" + UUID().uuidString
        page.adoptRemote(remote)
        defer { page.retire(call: false, pictureInPicture: false); ChromiumProcess.shared.detach(remote); tab.close() }
        let surface: [String: JSONValue] = ["tab": .string(remote), "source": .string("cefCallback"),
                                           "contextId": .number(7), "width": .number(1000), "height": .number(700)]
        page.receive(YabCoreEvent(name: "layer.changed", params: surface))
        #expect(page.surfaceState["resizeNative"] as? Bool == true)
        #expect(page.surfaceState["resizeCommitted"] as? [CGFloat] == [1000, 700])
        page.receive(YabCoreEvent(name: "page.crash", params: ["tab": .string(remote), "status": .number(1)]))
        #expect(page.contextID == 7, "Chrome's native sad tab uses the surviving window compositor")
        #expect(page.surfaceState["resizeNative"] as? Bool == true, "The native window survives its renderer")
        #expect(page.surfaceState["resizeCommitted"] as? [CGFloat] == [1000, 700])
        // OnLoadStart republishes this same compositor context after reload.
        page.receive(YabCoreEvent(name: "layer.changed", params: surface))
        #expect(page.contextID == 7)
        #expect(page.surfaceState["resizeCommitted"] as? [CGFloat] == [1000, 700])
        // Losing the helper really does destroy the native viewport.
        page.helperExited()
        #expect(page.surfaceState["resizeNative"] as? Bool == false)
        #expect(page.surfaceState["resizeCommitted"] as? [CGFloat] == [])
    }

    @Test func chromiumLossDoesNotEnterWebKitAutomaticRecovery() throws {
        let browser = Browser(windowID: UUID())
        let factory = PageEngineFactory(kinds: [.chromium]) { tab, _ in ChromiumPage(tab: tab) }
        let tab = Tab(shy: true, engine: .chromium, factory: factory)
        tab.restore(url: URL(string: "https://example.com/")!, title: "Crash")
        browser.prepare(tab)
        browser.lay([tab])
        browser.activeID = tab.id
        let page = try #require(tab.page as? ChromiumPage)
        defer {
            page.retire(call: false, pictureInPicture: false)
            tab.close()
            try? FileManager.default.removeItem(at: Store.file("session-window-\(browser.windowID!.uuidString).json"))
        }
        for reason in [PageEnd.crash, .memory, .crash, .memory] {
            browser.page(page, ended: reason)
            #expect(!browser.stuck.ends.gathering, "Chrome owns its crash screen; do not enqueue a WebKit reload")
            #expect(!tab.stale, "Selecting a crashed Chrome tab must not reload it")
            #expect(tab.failure == nil, "Do not cover the native sad tab with Yab's crash card")
        }
    }
}
