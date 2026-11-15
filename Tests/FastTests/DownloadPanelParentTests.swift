import AppKit
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct DownloadPanelParentTests {
    private func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 400, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func reopeningAfterOrderOutRestoresTheActualParent() {
        let parent = window(), panel = window()
        defer { panel.close(); parent.close() }
        for _ in 0..<3 {
            WindowHosting.attach(panel, to: parent)
            #expect(panel.parent === parent)
            #expect(parent.childWindows?.filter { $0 === panel }.count == 1)
            panel.orderOut(nil)
        }
    }

    @Test func movingToAnotherOwnerDoesNotLeaveAnOldChild() {
        let old = window(), next = window(), panel = window()
        defer { panel.close(); next.close(); old.close() }
        WindowHosting.attach(panel, to: old)
        WindowHosting.attach(panel, to: next)
        WindowHosting.attach(panel, to: next)
        #expect(panel.parent === next)
        #expect(old.childWindows?.contains { $0 === panel } != true)
        #expect(next.childWindows?.filter { $0 === panel }.count == 1)
    }
}
