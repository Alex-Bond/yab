import AppKit

/// Two fingers or a wheel over a field of many lines that holds more words
/// than it shows (the chat's composer, a task's line, Mail's asks: SwiftUI's
/// TextField(axis: .vertical) with a line limit) scroll its words (#129).
/// SwiftUI's field is an NSTextField: while it is typed in, its editor sits
/// in a clip view with no scroll view round it, which moves only to follow
/// the caret, so a scroll over it went up the responders to nothing. And
/// the editor is often no taller than the field (fit), so even the clip
/// view had nowhere to go.
///
/// A gesture that begins over such a field stays with it, its glide too, as
/// a page's does (ScrollLatch); a wheel's line moves it while there is room
/// and goes on as before at either end. Anything else is not looked at
/// beyond the window's first responder: no hit test, so the latches' savings
/// stand.
@MainActor
enum FieldWheel {
    private static var monitor: Any?
    /// The field's clip view a gesture began over.
    private static weak var held: NSClipView?

    static func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            MainActor.assumeIsolated { route(event) }
        }
    }

    /// The field being typed in in `window`: its editor, the clip view the
    /// editor scrolls in, and the field.
    static func editing(_ window: NSWindow?) -> (editor: NSTextView, clip: NSClipView, field: NSTextField)? {
        guard let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor,
              let field = editor.delegate as? NSTextField, let clip = editor.superview as? NSClipView
        else { return nil }
        return (editor, clip, field)
    }

    /// How far the clip view can go: the editor's height past what it shows.
    static func room(_ editor: NSTextView, _ clip: NSClipView) -> CGFloat {
        max(0, editor.frame.height - clip.bounds.height)
    }

    /// The editor as tall as its words. It is left the field's height while
    /// its words run on below (TextKit 2 grows it only as it lays out what
    /// is in sight), and then its clip view has nowhere to go.
    static func fit(_ editor: NSTextView) {
        let words: CGFloat
        if let layout = editor.textLayoutManager {
            layout.ensureLayout(for: layout.documentRange)
            words = layout.usageBoundsForTextContainer.maxY
        } else if let layout = editor.layoutManager, let container = editor.textContainer {
            layout.ensureLayout(for: container)
            words = layout.usedRect(for: container).maxY
        } else { return }
        let tall = ceil(words + editor.textContainerInset.height * 2)
        guard tall > editor.frame.height + 0.5 else { return }
        editor.setFrameSize(NSSize(width: editor.frame.width, height: tall))
    }

    private static func route(_ event: NSEvent) -> NSEvent? {
        let gesture = event.phase != [] || event.momentumPhase != []
        if gesture, event.phase != .began, event.phase != .mayBegin {
            // A gesture's moves and glide: only one that began over a field.
            guard let clip = held else { return event }
            guard clip.window === event.window, let editor = clip.documentView as? NSTextView else {
                held = nil
                return event
            }
            move(editor, clip, event)
            if event.momentumPhase == .ended || event.momentumPhase == .cancelled || event.phase == .cancelled { held = nil }
            return nil
        }
        // A gesture's start or a wheel's line: over a field with more words
        // than it shows?
        held = nil
        guard let (editor, clip, field) = editing(event.window),
              field.bounds.contains(field.convert(event.locationInWindow, from: nil))
        else { return event }
        fit(editor)
        guard room(editor, clip) > 0.5 else { return event }
        if gesture {
            held = clip
            move(editor, clip, event)
            return nil
        }
        return move(editor, clip, event) ? nil : event
    }

    /// Moves the words by the event's distance; false if they were at that end.
    @discardableResult
    private static func move(_ editor: NSTextView, _ clip: NSClipView, _ event: NSEvent) -> Bool {
        var dy = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas {
            // A wheel's lines, a line of the field's font each. Not asked of
            // its layoutManager: that turns a TextKit 2 editor into a 1.
            let font = editor.font ?? .systemFont(ofSize: NSFont.systemFontSize)
            dy *= ceil(font.ascender - font.descender + font.leading)
        }
        guard dy != 0 else { return false }
        let origin = clip.bounds.origin
        // A finger or a wheel going down shows the words above.
        let y = min(room(editor, clip), max(0, origin.y + (clip.isFlipped ? -dy : dy)))
        guard abs(y - origin.y) > 0.01 else { return false }
        clip.scroll(to: NSPoint(x: origin.x, y: y))
        return true
    }
}
