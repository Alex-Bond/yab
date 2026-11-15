import AppKit
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct StageViewDeallocationTests {
    @Test func releasingAStageWithAChildDoesNotCreateAWeakReferenceDuringDeallocation() {
        weak var released: StageView?
        autoreleasepool {
            let stage = StageView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
            stage.addSubview(NSView(frame: stage.bounds))
            released = stage
        }
        #expect(released == nil)
    }

    @Test func removingAWindowStageWithAChildCanReleaseIt() {
        _ = NSApplication.shared
        weak var released: StageView?
        autoreleasepool {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let stage = StageView(frame: window.contentView!.bounds)
            stage.addSubview(NSView(frame: stage.bounds))
            released = stage
            window.contentView = stage
            window.contentView = nil
            window.close()
        }
        #expect(released == nil)
    }
}
