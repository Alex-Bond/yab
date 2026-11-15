import AppKit

/// Only the second press of the click that raised the field belongs to
/// the band. AppKit's click count keeps clicks elsewhere from joining it.
struct AddressBarClickSequence {
    private var first: (at: TimeInterval, window: Int)?

    mutating func opened(at: TimeInterval, window: Int) {
        first = (at, window)
    }

    mutating func second(at: TimeInterval, window: Int, count: Int,
                         interval: TimeInterval, showing: Bool) -> Bool {
        defer { first = nil }
        guard let first, showing, count == 2, window == first.window else { return false }
        let elapsed = at - first.at
        return elapsed >= 0 && elapsed <= interval
    }
}

/// A single click opens the field at once. Listen briefly for its second
/// press before the newly opened field or its scrim can take it.
@MainActor
final class AddressBarClick {
    private var sequence = AddressBarClickSequence()
    private weak var browser: Browser?
    private weak var window: NSWindow?
    private var request = 0
    private var releasing = false
    private var monitor: Any?
    private var expiry: DispatchWorkItem?
    private let twice: @MainActor (NSWindow) -> Void

    init(twice: @escaping @MainActor (NSWindow) -> Void = { StripPress.twice($0) }) {
        self.twice = twice
    }

    func watch(_ event: NSEvent?, in browser: Browser) {
        cancel()
        guard let event, event.type == .leftMouseUp, event.clickCount == 1,
              let window = event.window else { return }
        self.browser = browser
        self.window = window
        request = browser.focusRequest
        sequence.opened(at: event.timestamp, window: window.windowNumber)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel
        ]) { [weak self] event in
            guard let self else { return event }
            return self.receive(event)
        }
        let expiry = DispatchWorkItem { [weak self] in self?.cancel() }
        self.expiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: expiry)
    }

    func cancel() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        expiry?.cancel()
        expiry = nil
        sequence = AddressBarClickSequence()
        releasing = false
        browser = nil
        window = nil
    }

    func receive(_ event: NSEvent) -> NSEvent? {
        if releasing, event.window === window {
            if event.type == .leftMouseDragged { return nil }
            if event.type == .leftMouseUp { cancel(); return nil }
        }
        guard event.type == .leftMouseDown,
              !event.modifierFlags.contains(.control),
              let browser, let window, event.window === window,
              sequence.second(at: event.timestamp, window: event.windowNumber, count: event.clickCount,
                              interval: NSEvent.doubleClickInterval,
                              showing: browser.editing && browser.focusRequest == request) else {
            cancel()
            return event
        }
        expiry?.cancel()
        expiry = nil
        releasing = true
        browser.dismiss()
        twice(window)
        return nil
    }
}
