import AppKit
import SwiftUI

extension Bench {
    /// Read the actual bound native cells, rather than recomputing a desired
    /// window tone. The fixture supplies ephemeral folders without making a
    /// private tab persistent through Keep Tab.
    func privateFolderCheck(_ request: [String: Any], browser: Browser) -> [String: Any] {
        guard Store.testing, browser.windowPurpose == .privateOnly else { return ["error": "private test window required"] }
        if request["fixture"] as? Bool == true {
            let folder = Nest(name: "Private folder", open: true)
            folder.fleeting = true
            for tab in browser.tabs.prefix(2) { tab.nest = folder }
            browser.folderBook.refresh()
            // Seed the drawn fixture once; subsequent clicks must reach
            // the column through the product's normal notification path.
            ColumnPages.relay(browser)
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        guard let window = BrowserWindows.shared.window(for: browser), let root = window.contentView else { return ["error": "no window"] }
        let views = descendants(root)
        let rows: [[String: Any]] = views.compactMap { view in
            guard let cell = view as? ColumnCell, !cell.isHiddenOrHasHiddenAncestor,
                  let tab = cell.rowTab, let current = cell.current, cell.alphaValue > 0.01, cell.bounds.height > 0 else { return nil }
            var env = EnvironmentValues()
            env.colorScheme = current.look.scheme
            env.tone = current.look.tone
            let ink = current.live || current.picked ? Palette.ink : Palette.muted(on: current.look.tone)
            let color = NSColor(cgColor: ink.resolve(in: env).cgColor)!.usingColorSpace(.sRGB)!
            return ["id": tab.id.uuidString, "title": tab.title, "engine": tab.engineKind.rawValue, "live": current.live,
                    "text": [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent],
                    "tone": current.look.tone?.page.hex ?? "", "dark": current.look.scheme == .dark]
        }
        return ["rows": rows, "window": window.windowNumber,
                "ownsFolders": browser.folderBook.browser === browser,
                "persistent": browser.tabs.contains { $0.store.isPersistent },
                "backdrops": views.compactMap { ($0 as? WindowBackdropView)?.glassReport }]
    }
}
