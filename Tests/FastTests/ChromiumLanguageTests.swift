import AppKit
import Testing
@testable import Fast

@MainActor
struct ChromiumLanguageTests {
    @Test func peekScriptsAreInTheRealChromiumPlan() {
        _ = NSApplication.shared
        let tab = Tab(shy: true)
        defer { tab.close() }
        tab.forcePeeks = { true }
        let scripts = PageScripts.chromium(for: tab, .init(host: "example.com", css: ""))
        let peek = scripts.first { $0.source == PeekOrigin.script(force: true) }
        #expect(peek?.world == .yab)
        #expect(peek?.atEnd == false)
        #expect(peek?.mainOnly == true)
        #expect(scripts.contains { $0.source == LinkCardRules.script && $0.world == .yab && !$0.atEnd })
    }

    @Test func pressureFiresOncePerStageEdge() {
        _ = NSApplication.shared
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab)
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        #expect(page.pressureConfiguration?.pressureBehavior == .primaryDeepClick)
        var forces = 0
        tab.onForceClick = { _, _ in forces += 1 }
        let point = CGPoint(x: 100, y: 100)
        for stage in [1, 2, 2, 0, 1, 2, 0] {
            page.receivePressure(stage: stage, amount: 1, point: point)
        }
        #expect(forces == 2)
    }

    @Test func draggingRestoresTheOriginalModifiedDownInEitherLookupState() throws {
        _ = NSApplication.shared
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab)
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
            modifierFlags: .shift, timestamp: 1, windowNumber: 0, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        for resolved in [false, true] {
            if resolved {
                page.modifiedLinkDown = down
                page.modifiedLink = URL(string: "https://example.com")
            } else { page.modifiedDown = down }
            #expect(page.takeModifiedDown() === down)
            #expect(page.modifiedLink == nil)
            #expect(page.modifiedUp == nil)
            #expect(page.takeModifiedDown() == nil)
        }
    }

    @Test func forceReleaseWaitsForLookupAndIsDeliveredOnce() throws {
        _ = NSApplication.shared
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero,
            modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 0))
        var input = ChromiumForceClickInput()
        let first = input.begin()
        let firstHeld = input.interceptUp(up)
        #expect(firstHeld)
        let current = input.begin()
        let stale = input.finish(first, handled: true)
        #expect(stale == nil)
        let currentHeld = input.interceptUp(up)
        #expect(currentHeld)
        let extraDown = input.interceptDown()
        #expect(extraDown) // An extra press cannot pass the held release.
        let delivered = input.finish(current, handled: true)
        #expect(delivered === up)
        let extraUp = input.interceptUp(up)
        #expect(extraUp) // Release of that ignored extra press.
        #expect(!input.holdsInput)
        let repeated = input.finish(current, handled: true)
        #expect(repeated == nil)
        let early = input.begin()
        let earlyResult = input.finish(early, handled: true)
        #expect(earlyResult == nil)
        #expect(input.holdsInput)
        let ordinaryRelease = input.interceptUp(up)
        #expect(!ordinaryRelease)
        #expect(!input.holdsInput)
        let missed = input.begin()
        let missedResult = input.finish(missed, handled: false)
        #expect(missedResult == nil)
        #expect(!input.holdsInput)
    }

    @Test func preferredLanguagesReachChromiumsCatalogNamesInOrder() {
        #expect(ChromiumProcess.languageTags(["zh-Hans-CN", "en_US"]) == ["zh-CN", "en-US"])
        #expect(ChromiumProcess.languageTags(["zh-Hant-HK", "zh_TW", "fr-FR"]) == ["zh-TW", "fr-FR"])
        #expect(ChromiumProcess.languageTags(["", "en,fr", "en\nUS"]) == ["en-US"])
        #expect(ChromiumProcess.languageTags([]) == ["en-US"])
    }
}
