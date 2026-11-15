import AppKit

// The lock in the band over the page, pressed: Site Controls, turned to the
// connection's page, hanging from the lock (SiteControls.swift).

@MainActor
enum SiteLock {
    /// The lock pressed: the panel opens on the connection, or closes if it
    /// was already open on it for this tab.
    static func toggle(_ browser: Browser, _ tab: Tab, from frame: CGRect) {
        if browser.active?.id != tab.id { browser.focus(tab) }
        guard let content = (NSApp.currentEvent?.window ?? NSApp.keyWindow)?.contentView else {
            ExtensionPanel.shared.toggle(tab: tab, page: .connection)
            return
        }
        let rect = content.isFlipped ? frame : CGRect(x: frame.minX, y: content.bounds.height - frame.maxY, width: frame.width, height: frame.height)
        ExtensionPanel.shared.toggle(tab: tab, page: .connection, spot: (rect, content))
    }

    static func close() { ExtensionPanel.shared.close() }
}
