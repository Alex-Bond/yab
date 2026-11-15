import AppKit
import Testing
import WebKit
@testable import Fast

// Explicit engine metadata drives the real Browser popup callback. This
// checks native focus policy, not physical WebKit modifier extraction.
@Suite(.serialized) @MainActor
struct AgentPopupFocusTests {
    enum Input: String, CaseIterable, Sendable {
        case command, middle, shiftCommand, shiftMiddle, plain
        var flags: NSEvent.ModifierFlags {
            switch self {
            case .command: .command
            case .shiftCommand: [.command, .shift]
            case .shiftMiddle: .shift
            case .middle, .plain: []
            }
        }
        var button: Int { self == .middle || self == .shiftMiddle ? 4 : 1 }
        var foreground: Bool { self == .plain || self == .shiftCommand || self == .shiftMiddle }
    }

    private func fixture(_ check: (Browser, Tab) throws -> Void) rethrows {
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        defer {
            browser.letGo()
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            if let id = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            }
        }
        let source = Tab(shy: true, bench: true, factory: .webKitOnly)
        browser.prepare(source)
        source.assistantSpace = browser.spaceID
        browser.lay(browser.tabs + [source])
        source.go(to: URL(string: "about:blank")!)
        browser.select(source)
        browser.editing = true
        // Selecting an actual agent-created page does not adopt it.
        #expect(source.bench && browser.activeID == source.id)
        try check(browser, source)
    }

    private func popup(_ browser: Browser, source: Tab, input: Input, scripted: Bool,
                       menuForeground: Bool? = nil) throws -> Tab {
        let url = URL(string: "http://127.0.0.1:9/agent-popup-\(input.rawValue)")!
        let id = UUID()
        let adapter = requireNativeWebKitFixture(source, "AgentPopupFocusTests").navigationEvents
        let configuration = requireNativeWebKitFixture(source, "AgentPopupFocusTests").configuration.copy() as! WKWebViewConfiguration
        // The actual adapter gives a child its own handlers before handing
        // the construction context to Browser.page(open:).
        configuration.userContentController = WKUserContentController()
        let context = WebKitPopup(configuration)
        adapter.popups[id] = context
        defer { adapter.popups[id] = nil }
        let action = PageAction(request: URLRequest(url: url), kind: scripted ? .other : .linkActivated,
            targetIsMainFrame: nil, source: nil, modifierFlags: input.flags,
            buttonNumber: input.button, shouldPerformDownload: false, userInitiated: true)
        let request = PagePopup(id: id, action: action, width: nil, height: nil,
                               toolbarsVisible: nil, menuForeground: menuForeground)
        var replies: [UUID?] = []
        browser.page(requireNativeWebKitFixture(source, "AgentPopupFocusTests"), open: request) { replies.append($0) }
        let destination = try #require(browser.tabs.last { $0 !== source && $0.bench })
        #expect(replies == [destination.id])
        #expect(destination.opener == source.id && destination.from == source.id)
        #expect(destination.assistantSpace == source.assistantSpace)
        #expect(destination.address == url)
        #expect(destination.bench && source.bench)
        #expect(requireNativeWebKitFixture(destination, "AgentPopupFocusTests").configuration.websiteDataStore === requireNativeWebKitFixture(source, "AgentPopupFocusTests").configuration.websiteDataStore)
        return destination
    }

    @Test(arguments: Input.allCases, [false, true])
    func selectedAgentPageHonorsExplicitInput(input: Input, scripted: Bool) throws {
        try fixture { browser, source in
            let destination = try popup(browser, source: source, input: input, scripted: scripted)
            #expect(browser.activeID == (input.foreground ? destination.id : source.id))
            #expect(browser.editing == !input.foreground)
            print("AGENT_POPUP_FOCUS selected input=\(input.rawValue) scripted=\(scripted) foreground=\(browser.activeID == destination.id)")
        }
    }

    @Test(arguments: Input.allCases)
    func hiddenAgentPageNeverTakesFocus(input: Input) throws {
        try fixture { browser, source in
            let front = browser.open(URL(string: "about:blank")!, foreground: true, shy: true)
            browser.editing = true
            _ = try popup(browser, source: source, input: input, scripted: true)
            #expect(browser.activeID == front.id && browser.editing)
        }
    }

    @Test(arguments: [false, true])
    func explicitMenuIntentRetainsPriority(foreground: Bool) throws {
        try fixture { browser, source in
            let input: Input = foreground ? .command : .shiftCommand
            let destination = try popup(browser, source: source, input: input, scripted: true,
                                        menuForeground: foreground)
            #expect(browser.activeID == (foreground ? destination.id : source.id))
            #expect(browser.editing == !foreground)
        }
    }
}
