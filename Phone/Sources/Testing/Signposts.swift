import Foundation

/// Where a motion's signpost interval is also told to the test build's own
/// meters: MotionSignposts (Design/Motion.swift) calls these beside
/// os_signpost, so FrameMeter measures exactly the frames of each named
/// movement. Debug builds only, like the signposts themselves.
enum Signposts {
    /// `name` is the Motion's; `signpost` the interval's own name when it
    /// isn't (Reduce Motion's "fade"); `expected` the Motion's duration.
    static func began(_ name: StaticString, signpost: StaticString? = nil, expected: TimeInterval = 0) {
        #if DEBUG
        onMain { FrameMeter.shared?.begin("\(name)", signpost: signpost.map { "\($0)" }, expected: expected) }
        #endif
    }

    static func ended(_ name: StaticString) {
        #if DEBUG
        onMain { FrameMeter.shared?.end("\(name)") }
        #endif
    }

    /// Motions run on the main thread; one that doesn't is not measured
    /// rather than measured from the wrong thread.
    private static func onMain(_ body: @MainActor () -> Void) {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated(body)
    }
}
