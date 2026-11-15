import Foundation
import Testing
@testable import Fast

@MainActor
@Suite(.serialized)
struct CaptureAskTests {
    private func fixture(_ check: (Browser, Tab, PageOrigin) -> Void) {
        let browser = Browser(windowID: UUID())
        let tab = Tab(bench: true, engine: .webKit, factory: .webKitOnly)
        let host = "capture-\(UUID().uuidString.lowercased()).invalid"
        let origin = PageOrigin(scheme: "https", host: host, port: 443)
        tab.restore(url: URL(string: "https://\(host)/call")!, title: "Call")
        browser.outside.append(tab)
        let previous = ProcessInfo.processInfo.environment["YAB_MAC_SAYS_YES"]
        setenv("YAB_MAC_SAYS_YES", "1", 1)
        defer {
            browser.dropAsks(tab)
            for type: PageCapture in [.camera, .microphone, .cameraAndMicrophone] {
                Store.settings.removeObject(forKey: Browser.captureKey(Browser.origin(scheme: "https", host: host, port: 443), type))
            }
            if let previous { setenv("YAB_MAC_SAYS_YES", previous, 1) }
            else { unsetenv("YAB_MAC_SAYS_YES") }
            browser.letGo()
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
        }
        check(browser, tab, origin)
    }

    @Test func backToBackDevicesShareOneQuestionAndPersistBoth() {
        fixture { browser, tab, origin in
            var replies: [PagePermission] = []
            browser.askCapture(tab.page, origin, .microphone) { replies.append($0) }
            let id = tab.asks.first?.id
            browser.askCapture(tab.page, origin, .camera) { replies.append($0) }
            #expect(tab.asks.count == 1)
            #expect(tab.asks.first?.id == id)
            #expect(tab.asks.first?.kind == .capture(.cameraAndMicrophone))
            #expect(replies.isEmpty)
            browser.answer(tab, .yes(nil))
            #expect(replies == [.grant, .grant])
            #expect(tab.asks.isEmpty)
            let site = Browser.origin(scheme: origin.scheme, host: origin.host, port: origin.port)
            for type: PageCapture in [.camera, .microphone] {
                #expect(Store.settings.object(forKey: Browser.captureKey(site, type)) as? Bool == true)
            }
            // A different tab has no visit grant; it reads the site store.
            let other = Tab(bench: true, engine: .webKit, factory: .webKitOnly)
            other.restore(url: URL(string: "https://\(origin.host)/other")!, title: "Other")
            browser.outside.append(other)
            browser.askCapture(other.page, origin, .cameraAndMicrophone) { replies.append($0) }
            #expect(other.asks.isEmpty)
            #expect(replies == [.grant, .grant, .grant])
        }
    }

    @Test func denialAndPageDepartureKeepNothingAndPayEveryCallbackOnce() {
        for leave in [false, true] {
            fixture { browser, tab, origin in
                var replies: [PagePermission] = []
                browser.askCapture(tab.page, origin, .microphone) { replies.append($0) }
                browser.askCapture(tab.page, origin, .camera) { replies.append($0) }
                if leave { browser.dropAsks(tab) } else { browser.answer(tab, .no) }
                browser.dropAsks(tab)
                #expect(replies == [.deny, .deny])
                let site = Browser.origin(scheme: origin.scheme, host: origin.host, port: origin.port)
                for type: PageCapture in [.camera, .microphone, .cameraAndMicrophone] {
                    #expect(Store.settings.object(forKey: Browser.captureKey(site, type)) == nil)
                }
                browser.askCapture(tab.page, origin, .microphone) { replies.append($0) }
                #expect(tab.asks.count == 1)
            }
        }
    }

    @Test func nativeCancellationWithdrawsOnlyItsOwnDevice() {
        fixture { browser, _, origin in
            let factory = PageEngineFactory(kinds: [.chromium]) { tab, _ in ChromiumPage(tab: tab) }
            let tab = Tab(bench: true, engine: .chromium, factory: factory)
            tab.restore(url: URL(string: "https://\(origin.host)/native")!, title: "Native")
            browser.outside.append(tab)
            guard let page = tab.page as? ChromiumPage else { Issue.record("Chromium page missing"); return }
            let mic = PageFileRequest(), camera = PageFileRequest()
            var heard: [String] = []
            page.questionRequests.presentingPermission = mic
            browser.askCapture(page, origin, .microphone) { heard.append("mic \($0)") }
            page.questionRequests.presentingPermission = camera
            browser.askCapture(page, origin, .camera) { heard.append("camera \($0)") }
            page.questionRequests.presentingPermission = nil
            #expect(tab.asks.count == 1)
            mic.cancel()
            #expect(heard == ["mic deny"])
            #expect(tab.asks.map(\.kind) == [.capture(.camera)])
            browser.answer(tab, .yes(nil))
            camera.cancel()
            #expect(heard == ["mic deny", "camera grant"])
            #expect(tab.asks.isEmpty)
        }
    }

    @Test func differentFrameOriginsStaySeparate() {
        fixture { browser, tab, origin in
            let other = PageOrigin(scheme: origin.scheme, host: origin.host, port: 8443)
            browser.askCapture(tab.page, origin, .microphone) { _ in }
            browser.askCapture(tab.page, other, .camera) { _ in }
            #expect(tab.asks.map(\.kind) == [.capture(.microphone), .capture(.camera)])
        }
    }
}
