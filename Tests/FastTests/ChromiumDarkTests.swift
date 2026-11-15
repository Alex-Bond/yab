import AppKit
import Testing
import YabCoreClient
@testable import Fast

@Suite(.serialized)
@MainActor
struct ChromiumDarkTests {
    @Test func darkScriptsKeepTheirWorldsAndOrderOnChromium() {
        _ = NSApplication.shared
        let tab = Tab(shy: true)
        defer { tab.close() }
        let plan = PageScripts.Arming(host: "example.test", css: "")
        tab.darkState.armed = .none
        let plain = PageScripts.chromium(for: tab, plan)
        #expect(!plain.contains { $0.source == DarkPages.proxy.source })
        #expect(!plain.contains { $0.world == DarkPages.pageWorld })
        tab.darkState.armed = .engine
        let dark = PageScripts.chromium(for: tab, plan)
        let wanted = DarkPages.scripts(for: .engine).map(\.source)
        let found = dark.filter { wanted.contains($0.source) }
        #expect(found.map(\.source) == wanted)
        #expect(found.first?.world == .page)
        #expect(found.dropFirst().allSatisfy { $0.world == DarkPages.pageWorld })
        #expect(found.allSatisfy { !$0.mainOnly && !$0.atEnd })
    }

    @Test func groundIsToldAsAByteColor() {
        let value = ChromiumScripts.rgba(NSColor(srgbRed: 0.1, green: 0.2, blue: 1, alpha: 0.5))
        #expect(value?["r"] == .number(26))
        #expect(value?["g"] == .number(51))
        #expect(value?["b"] == .number(255))
        #expect(value?["a"] == .number(0.5))
    }

    @Test func darkRelayKeepsFramesFromTheEngineAndAnswersTheAsk() async {
        _ = NSApplication.shared
        let tab = Tab(shy: true)
        defer { tab.close() }
        let relay = tab.darkState.relay
        relay.tab = tab
        let main = PageFrame(isMain: true, url: URL(string: "https://example.test/"), token: NSObject())
        let child = PageFrame(isMain: false, url: URL(string: "https://frame.test/"), token: NSObject())
        func ask(_ frame: PageFrame) async -> (Any?, String?) {
            await withCheckedContinuation { done in
                relay.receive(PageScriptMessage(body: ["kind": "ask"], frame: frame)) { value, error in done.resume(returning: (value, error)) }
            }
        }
        let first = await ask(main)
        #expect(first.1 == nil)
        #expect((first.0 as? [String: Any])?["decision"] != nil)
        _ = await ask(child)
        #expect(tab.darkState.frames.count == 2)
        #expect(tab.darkState.frames.first?.isMain == true)
        // A child frame's "done" never speaks for the page.
        tab.darkState.host = "example.test"
        let before = tab.dark
        relay.receive(PageScriptMessage(body: ["kind": "done", "result": "own"], frame: child)) { _, _ in }
        #expect(tab.dark == before)
        // A body that is not a request is refused.
        let refused: String? = await withCheckedContinuation { done in
            relay.receive(PageScriptMessage(body: "nonsense", frame: main)) { _, error in done.resume(returning: error) }
        }
        #expect(refused == "Not a request")
    }

    @Test func aFreshChromiumProfileHasNoDarkReaderUntilChromeListsIt() {
        _ = NSApplication.shared
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab)
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        #expect(page.darkReaderOn == false)
        #expect(page.colorScheme == "light" || page.colorScheme == "dark")
    }
}
