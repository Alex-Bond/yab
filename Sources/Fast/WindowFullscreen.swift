import AppKit

/// AppKit's frame autosave remembers a rectangle, not native fullscreen.
/// Keep the user's choice per normal browser window, including the first
/// SwiftUI window. Closing or quitting must not turn its teardown into an
/// explicit Exit Full Screen. Private windows never get one of these.
@MainActor
final class WindowFullscreen {
    private weak var window: NSWindow?
    private let settings: UserDefaults
    private let key: String
    private var watches: [NSObjectProtocol] = []
    private var closing = false
    private var quitting = false
    private var moving = false
    private var queued = false

    init(_ window: NSWindow, id: UUID, settings: UserDefaults = Store.settings) {
        self.window = window
        self.settings = settings
        key = "window.\(id.uuidString).fullscreen"
        let center = NotificationCenter.default
        func hear(_ name: NSNotification.Name, _ action: @escaping (WindowFullscreen) -> Void) {
            watches.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { action(self) } }
            })
        }
        hear(NSWindow.willEnterFullScreenNotification) { state in
            state.moving = true
            if !state.closing && !state.quitting { state.settings.set(true, forKey: state.key) }
        }
        hear(NSWindow.didEnterFullScreenNotification) { $0.moving = false }
        hear(NSWindow.willExitFullScreenNotification) { $0.moving = true }
        hear(NSWindow.didExitFullScreenNotification) { state in
            state.moving = false
            if !state.closing && !state.quitting && state.window?.isVisible == true {
                state.settings.set(false, forKey: state.key)
            }
            // Reopened before the close's native transition finished: keep
            // the saved choice, then enter once that exit has settled.
            if state.window?.isVisible == true {
                state.closing = false
                state.restore()
            }
        }
        hear(NSWindow.willCloseNotification) { $0.closing = true }
        hear(NSWindow.didBecomeKeyNotification) { state in
            if !state.moving { state.closing = false }
            state.restore()
        }
        if window.styleMask.contains(.fullScreen) { settings.set(true, forKey: key) }
        restore()
    }

    deinit {
        for token in watches { NotificationCenter.default.removeObserver(token) }
    }

    func prepareToQuit() { quitting = true }

    /// A settled native fullscreen owner, never a saved choice or an
    /// enter/exit/close that is still in flight.
    var isSettledFullscreen: Bool {
        !moving && !queued && !closing && !quitting
            && window?.isVisible == true && window?.styleMask.contains(.fullScreen) == true
    }

    private func restore() {
        guard !queued, !moving, !quitting, settings.bool(forKey: key) else { return }
        queued = true
        // Registration happens while SwiftUI dresses the window. Let that
        // finish and make it visible, then enter on the next run-loop turn,
        // with no startup timer. Check again: macOS may have restored it.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.queued = false
            guard !self.closing, !self.quitting, !self.moving,
                  self.settings.bool(forKey: self.key), let window = self.window,
                  window.isVisible, !window.styleMask.contains(.fullScreen) else { return }
            window.toggleFullScreen(nil)
        }
    }
}
