import AppKit
import Combine

// A window an extension opens for a page of its own on a Chromium tab,
// chrome.windows.create with type "popup": Bitwarden's passkey prompt, its
// item and vault pop-outs. The window both engines show (ExtensionWindowFrame):
// under the extension's pin, at the size the extension asked for, focused.
//
// It was a Small Window (LinkWindow) until 0.46.31: a field, Back and Open
// over an extension's prompt, which has no address to show and nowhere to be
// kept.
//
// The tab stays outside the row (Browser.outside), as a Small Window's does:
// closing the window closes the tab, which tells the extension
// windows.onRemoved; the page's own window.close() or windows.remove closes
// the window (ChromiumTabAdoption).

@MainActor
final class ChromiumExtensionWindow: NSObject {
    /// Open ones, oldest first.
    private(set) static var open: [ChromiumExtensionWindow] = []

    let tab: Tab
    let shown: ExtensionWindowFrame
    var window: NSWindow { shown.window }
    private weak var browser: Browser?
    private var titled: AnyCancellable?
    private var closed = false

    static func owning(_ window: NSWindow?) -> ChromiumExtensionWindow? {
        guard let window else { return nil }
        return open.first { $0.window === window }
    }

    static func showing(_ tab: Tab) -> ChromiumExtensionWindow? {
        open.first { $0.tab === tab }
    }

    /// Up and focused, the page in it. `extension`: whose window it is;
    /// `from`: the tab it was opened over, whose site it acts for and whose
    /// pins it stands under; `size`: what windows.create asked for, both sides
    /// or neither.
    static func present(_ tab: Tab, for browser: Browser, extension id: String?, from anchor: Tab, size: NSSize?) {
        let id = id ?? tab.address?.host() ?? ""
        // Its button as the tab it came from has it, else the one in front.
        let button = ([anchor] + [browser.active].compactMap { $0 }).lazy
            .compactMap { tab in ChromiumColumn.shared.buttons(for: tab, all: true).first { $0.id == id } }.first
        let owner = ExtensionWindowFrame.Owner(id: id, name: button?.name ?? tab.title, button: button)
        let made = ChromiumExtensionWindow(tab: tab, browser: browser, owner: owner,
                                           size: size ?? NSSize(width: 380, height: 600))
        open.append(made)
        let parent = BrowserWindows.shared.window(for: browser)
        made.shown.show(focused: true) { glass in
            ExtensionWindowFrame.standing(glass, asked: nil, over: parent)
        }
        if Store.testing {
            let frame = made.window.frame
            FileHandle.standardError.write(Data("YAB_EXTENSION_WINDOW open window=\(made.window.windowNumber) frame=\([frame.minX, frame.minY, frame.width, frame.height])\n".utf8))
        }
    }

    private init(tab: Tab, browser: Browser, owner: ExtensionWindowFrame.Owner, size: NSSize) {
        self.tab = tab
        self.browser = browser
        shown = ExtensionWindowFrame(page: tab.page, owner: owner, browser: browser, asked: size)
        super.init()
        if !tab.title.isEmpty { shown.window.title = tab.title }
        shown.onClose = { [weak self] in self?.closedByWindow() }
        titled = tab.changes(\.title).receive(on: DispatchQueue.main).sink { [weak self] title in
            guard let self, !title.isEmpty else { return }
            self.shown.window.title = title
        }
    }

    /// Closed by ⌘W, its cross, or the page itself.
    func close() { shown.close() }

    private func closedByWindow() {
        guard !closed else { return }
        closed = true
        titled = nil
        Self.open.removeAll { $0 === self }
        if Store.testing {
            FileHandle.standardError.write(Data("YAB_EXTENSION_WINDOW closed window=\(window.windowNumber)\n".utf8))
        }
        guard !tab.gone else { return }
        if let browser { browser.letGo(outside: tab) } else { tab.close() }
    }
}
