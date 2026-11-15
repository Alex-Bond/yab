import AppKit
import SwiftUI
import WebKit

@available(macOS 15.4, *)
@MainActor
final class ExtensionSidePanelPage: NSObject, WKWebExtensionTab, WKNavigationDelegate {
    let id: String
    let contextID = UUID().uuidString
    private(set) var targetTabID: Int?
    weak var browser: Browser?
    /// The sign-in's extensions it is a panel of.
    unowned let owner: Extensions
    let web: WKWebView
    private var requestedURL: URL
    private var loadedURL: URL?

    init(id: String, browser: Browser, owner: Extensions, configuration: WKWebViewConfiguration, url: URL, tabID: Int?) {
        self.id = id
        self.browser = browser
        self.owner = owner
        targetTabID = tabID
        requestedURL = url
        AppleWritingTools.configure(configuration)
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: ChatLook.normal, height: 600),
                        configuration: configuration)
        super.init()
        web.navigationDelegate = self
        owner.controller.didOpenTab(self)
    }

    // Panel documents live outside Browser.tabs. WebKit needs the same
    // navigation-to-download handoff here as on an ordinary page; otherwise
    // an extension's a.download never gets a destination or a lifetime owner.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.shouldPerformDownload ? .download : .allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(PageResponsePolicy.decide(response.response,
                        canShowMIMEType: response.canShowMIMEType).webKitResponse)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        browser?.webView(webView, navigationAction: navigationAction, didBecome: download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        browser?.webView(webView, navigationResponse: navigationResponse, didBecome: download)
    }

    func load(_ url: URL, tabID: Int?) {
        requestedURL = url
        targetTabID = tabID
        startPending()
    }

    func startPending() {
        guard web.window != nil, loadedURL != requestedURL else { return }
        loadedURL = requestedURL
        web.load(URLRequest(url: requestedURL))
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        browser.flatMap { owner.panelWindow(for: $0) }
    }
    func indexInWindow(for context: WKWebExtensionContext) -> Int { NSNotFound }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { web }
    func title(for context: WKWebExtensionContext) -> String? { web.title }
    func url(for context: WKWebExtensionContext) -> URL? { web.url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !web.isLoading }
    func isSelected(for context: WKWebExtensionContext) -> Bool { false }
    func close(for context: WKWebExtensionContext) async throws {
        owner.closePanel(id, in: browser, tabID: targetTabID, contextID: contextID)
    }
}

@available(macOS 15.4, *)
private struct ExtensionSidePanelWeb: NSViewRepresentable {
    let page: ExtensionSidePanelPage

    final class Container: NSView {
        weak var page: ExtensionSidePanelPage?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            page?.startPending()
        }
    }

    func makeNSView(context: Context) -> Container { Container(frame: .zero) }

    func updateNSView(_ container: Container, context: Context) {
        container.page = page
        if page.web.superview !== container {
            page.web.removeFromSuperview()
            container.subviews.forEach { $0.removeFromSuperview() }
            page.web.frame = container.bounds
            page.web.autoresizingMask = [.width, .height]
            container.addSubview(page.web)
        }
        page.startPending()
    }

    static func dismantleNSView(_ container: Container, coordinator: ()) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }
}

@available(macOS 15.4, *)
struct ExtensionSidePanelColumn: View {
    let browser: Browser
    let page: ExtensionSidePanelPage
    let corner: CGFloat
    let width: CGFloat
    @Environment(\.tabTitleSize) private var titleSize
    /// The head's and the page's air from the column's edges: the page's
    /// corner is the column's less this, so the two curves are concentric.
    private static let inset: CGFloat = 4
    /// The cross: a control's plate, under the pointer, in a comfortable
    /// row; a compact row has room for the small one only.
    private static var cross: ButtonSize { SideBar.row >= ButtonSize.regular.height + 8 ? .regular : .small }
    private static var pageCorner: CGFloat { Radius.surface - inset } // design: concentric with the column's own corner, the inset in

    var body: some View {
        // Chrome's side panel head, laid as a tab's row in the column: the
        // extension's mark and name at a tab's size on the left, a cross on
        // the right, nothing else. Under it the extension's page lies in
        // the column as a card of its own, the same air from the sides and
        // the foot (as Dia lays its panels), so the column reads as Yab's
        // frame round somebody else's page.
        VStack(spacing: 0) {
            HStack(spacing: SideBar.markGap) {
                if let button = page.owner.buttons.first(where: { $0.id == page.id }) {
                    ExtensionIcon(button: button, size: SideBar.mark)
                        .frame(width: SideBar.mark, height: SideBar.mark)
                }
                Text(page.owner.installed.first(where: { $0.id == page.id })?.name ?? page.id)
                    .font(.system(size: titleSize, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button {
                    // The last panel: the column away with it, as Hide Chat.
                    if Extensions.all.flatMap({ $0.panelPages(in: browser) }).count > 1 {
                        page.owner.closePanel(page.id, in: browser, tabID: page.targetTabID, contextID: page.contextID)
                    } else {
                        browser.hideChat()
                    }
                } label: { Symbol("xmark", size: 13) }
                    .buttonStyle(.yab(.quiet, Self.cross, tint: Palette.ink, icon: .square))
                    .focusable(false)
                    .keyTip("Close", shortcut: "Hide Chat")
            }
            // The mark's middle and the cross's stand as far in from the
            // sides as from the top, half a row, so the head's air is the
            // same all round and the cross's plate is the larger target.
            .padding(.leading, (SideBar.row - SideBar.mark) / 2) // design: the mark's middle half a row in
            .padding(.trailing, (SideBar.row - Self.cross.height) / 2) // design: the cross's middle half a row in
            .frame(height: SideBar.row)
            .padding([.horizontal, .top], Self.inset)
            ExtensionSidePanelWeb(page: page)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Self.pageCorner, style: .continuous))
                .padding([.horizontal, .bottom], Self.inset)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Radius.surface, style: .continuous))
        .background { HUD.plate(Radius.surface, surface: .page) }
        .overlay(alignment: browser.chatLeads ? .trailing : .leading) {
            ChatEdge(browser: browser)
                .offset(x: browser.chatLeads ? Backdrop.inset : -Backdrop.inset)
        }
    }
}
