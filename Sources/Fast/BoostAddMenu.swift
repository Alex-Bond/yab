import AppKit
import SwiftUI

/// Add beside Boosts, with the sidebar's searchable action menu.
struct BoostAddButton: View {
    let browser: Browser
    let tab: Tab
    var tile = false
    @State private var box = ViewBox()
    @State private var hovering = false

    var body: some View {
        Button { BoostAddMenu.show(browser: browser, tab: tab, under: box.view, leading: tile) } label: {
            if tile {
                TileFace(symbol: "plus", hovering: hovering)
            } else {
                HStack(spacing: 4) {
                    Text("Add")
                    Symbol("chevron.down", size: 8, weight: .medium)
                }
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .sidebarFont(size: 12)
        .foregroundStyle(Palette.muted)
        .focusable(false)
        .onHover { hovering = $0 }
        .accessibilityLabel("Add Boost")
        .background(BoostAddAnchor(box: box))
    }
}

private struct BoostAddAnchor: NSViewRepresentable {
    let box: ViewBox
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier(BoostAddMenu.anchorID)
        box.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { box.view = view }
}

@MainActor
enum BoostAddMenu {
    static let anchorID = "yab.boost-add"

    static func show(browser: Browser, tab: Tab, under view: NSView?, leading: Bool = false) {
        guard let view, let window = view.window else { return }
        let menu = make(browser: browser, tab: tab)
        // Keep the menu inside Site Controls from either Add or the empty tile.
        let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
        let width = ActionMenuList(menu: menu, falls: true).width
        ActionMenu.show(menu, in: window, at: NSPoint(x: leading ? frame.minX : frame.maxX - width, y: frame.minY - 4))
    }

    static func make(browser: Browser, tab: Tab) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, mark: String, act: @escaping () -> Void) {
            let item = PageMenuItem(title, act: act)
            MenuMark.put(mark, on: item)
            menu.addItem(item)
        }
        if BoostEditorLook.host(tab.address) != nil, !tab.shy {
            add("Customize…", mark: "paintbrush") { [weak browser, weak tab] in
                guard let browser, let tab else { return }
                BoostEditor.shared.show(browser, tab: tab, siteControls: true)
            }
        }
        if Agents.connected {
            add("Create with AI…", mark: "wand.and.stars") { [weak browser, weak tab] in
                guard Agents.connected, let browser, let tab else { return }
                ExtensionPanel.shared.close()
                browser.startBoost("Create a boost for \(tab.address?.host ?? "this site"): ", about: tab)
            }
        }
        add("Boost Store…", mark: "storefront") { [weak browser] in
            ExtensionPanel.shared.close()
            browser?.openPlace(.store)
        }
        menu.addItem(.separator())
        add("Userscript from File…", mark: "yab.puzzle.plus") { [weak browser, weak tab] in
            guard let browser, let tab else { return }
            ExtensionPanel.shared.close()
            // Let both menus close before presenting the Mac's file picker.
            Task { @MainActor in
                if let file = Userscripts.choose() { Userscripts.shared.add(file, browser: browser, tab: tab) }
            }
        }
        return menu
    }
}
