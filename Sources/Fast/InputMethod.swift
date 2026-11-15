import AppKit
import Observation

/// Words an input method is still composing (Pinyin, Kana, Hangul, an
/// accent held on a key): the marked text under the caret. While it is
/// there, Return, Escape, Space, Tab, the arrows and the digits are the
/// input method's, to pick and commit a candidate, as in every Mac field.
/// SwiftUI's onKeyPress and the window's key monitor hear a key before the
/// input method does, so a field that takes Return or the arrows itself
/// asks this first and lets the key go while words are being composed.
enum InputMethod {
    /// The responder holding the keyboard has marked text: the key window's
    /// field editor by default, or a page's web view.
    @MainActor static func composing(_ responder: NSResponder? = NSApp.keyWindow?.firstResponder) -> Bool {
        (responder as? NSTextInputClient)?.hasMarkedText() == true
    }
}

extension InputMethod {
    /// For a placeholder drawn over a field: whether the field, holding the
    /// keyboard, has words being composed. SwiftUI gives a field's binding
    /// its words only once the input method commits them, so a placeholder
    /// shown while the binding is empty sat over Kana still being typed
    /// (row 1014). `focused` is the field's own focus, as its view knows it.
    @MainActor static func composing(focused: Bool) -> Bool {
        focused && Marking.shared.composing
    }

    /// Whether the text view holding the keyboard has marked text, kept as
    /// the text views say they changed: an input method setting its words
    /// changes the text and the selection, committing or dropping them does
    /// too, and leaving the field commits them. Words unmarked with no change
    /// told are caught after the event that did it. Observable, so a view's
    /// body that read it is drawn again when composing starts or stops.
    @MainActor @Observable final class Marking {
        static let shared = Marking()
        private(set) var composing = false
        /// The text view composing, while one is.
        @ObservationIgnored private weak var view: NSTextView?
        @ObservationIgnored private var watchers: [NSObjectProtocol] = []

        init(center: NotificationCenter = .default) {
            // A text view may post from another thread (crash #221).
            // Deliver on main before touching AppKit or observable state.
            for name in [NSText.didChangeNotification, NSTextView.didChangeSelectionNotification, NSText.didEndEditingNotification] {
                watchers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    let ended = note.name == NSText.didEndEditingNotification
                    let view = note.object as? NSTextView
                    AppKitMainThread.sync { self?.saw(view, ended: ended) }
                })
            }
            // Once an event is handled: only a check while composing.
            watchers.append(center.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: .main) { [weak self] _ in
                AppKitMainThread.sync { self?.recheck() }
            })
        }

        /// A text view told of a change. Another view's selection moving
        /// (a transcript's, a label's) says nothing about the one typed in.
        func saw(_ view: NSTextView?, ended: Bool) {
            guard let view else { return }
            if ended {
                if view === self.view || self.view == nil { set(nil) }
                return
            }
            guard view.window?.firstResponder === view else { return }
            set(view.hasMarkedText() ? view : nil)
        }

        private func recheck() {
            guard composing else { return }
            if let view, view.hasMarkedText(), view.window?.firstResponder === view { return }
            set(nil)
        }

        private func set(_ view: NSTextView?) {
            self.view = view
            if composing != (view != nil) { composing = view != nil }
        }
    }
}
