import AppKit

/// Test-person input through the page's AppKit view. Unlike an agent press,
/// this keeps the ordinary person-input path used by popup/media policy.
@MainActor
enum PageBenchInput {
    static func click(_ page: any PageHandle, x: Double, y: Double) -> Bool {
        guard x.isFinite, y.isFinite, let window = page.window else { return false }
        let zoom = page.pageZoom * page.magnification
        let local = CGPoint(x: x * zoom, y: page.isFlipped ? y * zoom : page.bounds.height - y * zoom)
        let point = page.convert(local, to: nil)
        func event(_ type: NSEvent.EventType, pressure: Float) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: pressure)
        }
        guard let down = event(.leftMouseDown, pressure: 1), let up = event(.leftMouseUp, pressure: 0) else { return false }
        page.mouseDown(with: down)
        page.mouseUp(with: up)
        return true
    }

    static func type(_ text: String, into page: any PageHandle) -> Bool {
        guard let window = page.window, window.makeFirstResponder(page) else { return false }
        page.insertAgentText(text)
        return true
    }
}
