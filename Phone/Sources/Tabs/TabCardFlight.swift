import QuartzCore
import UIKit
import os

/// A thrown card keeps the finger's speed. It is removed when its bottom
/// clears the screen, rather than after a fixed animation duration.
struct TabCardTrajectory: Equatable {
    let start: CGFloat
    let velocity: CGFloat
    let bottom: CGFloat

    func offset(at seconds: Double) -> CGFloat {
        let t = CGFloat(max(0, seconds))
        return start + min(-Metrics.TabGallery.minimumThrowSpeed, velocity) * t
            - Metrics.TabGallery.throwAcceleration * t * t / 2
    }

    func hasLeft(at seconds: Double) -> Bool { bottom + offset(at: seconds) <= 0 }
}

@MainActor
final class TabCardFlight: NSObject {
    private var link: CADisplayLink?
    private let trajectory: TabCardTrajectory
    private let update: (CGFloat) -> Void
    private let completion: () -> Void
    private var start: CFTimeInterval = 0
    private var signpost: OSSignpostIntervalState?

    init(_ trajectory: TabCardTrajectory, update: @escaping (CGFloat) -> Void,
         completion: @escaping () -> Void) {
        self.trajectory = trajectory
        self.update = update
        self.completion = completion
        super.init()
    }

    func run() {
        if Motion.disabled || Motion.reduced {
            completion()
            return
        }
        start = CACurrentMediaTime()
        signpost = MotionSignposts.begin("tabsCardFly")
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        MotionSignposts.end("tabsCardFly", signpost)
        signpost = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let t = link.targetTimestamp - start
        update(trajectory.offset(at: t))
        if trajectory.hasLeft(at: t) {
            stop()
            completion()
        }
    }
}
