import AppKit

/// Show Yab: a key of the person's own, heard from every app, that brings
/// Yab to the front, and, pressed with Yab already there, gives the front
/// back to the app that had it, as iTerm's hotkey window and Raycast's app
/// keys do. No key out of the box (Settings › Shortcuts).
///
/// The window that comes is the one last used, out of the Dock if it was put
/// there, on its own desktop as ⌘Tab would go; with none, a new one, as a
/// click on the Dock icon gives. Going back never hides Yab: a floating
/// video or a small window stays where it is.
@MainActor
enum ShowYab {
    static let globalKey = GlobalKey(id: 2, pressed: { ShowYab.toggle() }, again: { ShowYab.hotkey() })

    static func hotkey() {
        watch()
        globalKey.register(on: true, keys: Keymap.shared.keys(.showYab))
    }

    /// The app that was in front before Yab, the one the key goes back to.
    private static weak var previous: NSRunningApplication?
    private static var watching: NSObjectProtocol?

    private static func watch() {
        guard watching == nil else { return }
        watching = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app, app != .current { previous = app }
            }
        }
    }

    static func toggle() {
        if NSApp.isActive, let key = NSApp.keyWindow, BrowserWindows.shared.browser(for: key) != nil {
            back()
        } else {
            bring()
        }
    }

    private static func bring() {
        if Headless.hidden { Headless.show(.person) }
        NSApp.activate()
        guard let window = BrowserWindows.shared.lastWindow else {
            Links.showBrowser()
            return
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    private static func back() {
        guard let app = previous, !app.isTerminated else {
            NSApp.hide(nil)
            return
        }
        NSApp.yieldActivation(to: app)
        app.activate()
    }
}
