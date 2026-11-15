import AppKit
import Testing
@testable import Fast

@MainActor
struct ChromiumPeekInputTests {
    private final class Listener: PageEvents {
        var actions: [PageAction] = []
        func page(_ page: any PageHandle, navigation event: PageNavigationEvent) { }
        func page(_ page: any PageHandle, decide action: PageAction,
                  reply: @escaping @MainActor (PagePolicy) -> Void) {
            actions.append(action)
            reply(.cancel)
        }
        func page(_ page: any PageHandle, decide response: PageDocumentResponse,
                  reply: @escaping @MainActor (PagePolicy) -> Void) { reply(.cancel) }
    }

    @Test func foregroundDispositionDoesNotInventShiftForNativeLinkPresses() throws {
        _ = NSApplication.shared
        let tab = Tab(shy: true), page = ChromiumPage(tab: tab), listener = Listener()
        page.events = listener
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        let url = URL(string: "https://www.ithome.com/0/123/456.htm")!
        for flags: NSEvent.ModifierFlags in [[], .option, .shift, .command, [.command, .shift], [.option, .shift]] {
            for foreground in [false, true] {
                page.lastPress = (flags, 0, ProcessInfo.processInfo.systemUptime)
                page.receiveOpenLink(["url": .string(url.absoluteString), "foreground": .bool(foreground), "gesture": .bool(true)])
                let action = try #require(listener.actions.last)
                #expect(action.modifierFlags == flags)
                #expect(action.kind == .linkActivated)
                #expect(Browser.shouldPeek(url, from: nil, pinned: false, flags: action.modifierFlags,
                                           button: action.buttonNumber, peekClick: .option) == (flags == .option))
                #expect(Browser.shouldPeek(url, from: nil, pinned: false, flags: action.modifierFlags,
                                           button: action.buttonNumber, peekClick: .shift) == (flags == .shift))
            }
        }
        #expect(listener.actions.count == 12)
    }

    @Test func aLinkWithoutARecentPressRetainsTheDispositionFallback() throws {
        _ = NSApplication.shared
        let tab = Tab(shy: true), page = ChromiumPage(tab: tab), listener = Listener()
        page.events = listener
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        for stale in [false, true] {
            page.lastPress = stale ? (.option, 0, ProcessInfo.processInfo.systemUptime - 3) : nil
            for foreground in [false, true] {
                page.receiveOpenLink(["url": .string("https://example.com/article"), "foreground": .bool(foreground)])
                let flags = try #require(listener.actions.last).modifierFlags
                #expect(flags == (foreground ? [.command, .shift] : [.command]))
            }
        }
    }
}
