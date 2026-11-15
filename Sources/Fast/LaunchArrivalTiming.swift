import Foundation

/// The Ray/Flow pacing, in shader seconds. Audio remains at its
/// original speed. The approved 300 ms handoff straddles its 5.56 s cue.
enum LaunchArrivalTiming {
    static let windowCue = 5.56
    static let revealStart = 5.36
    static let revealDuration = 0.30
    static let revealEnd = revealStart + revealDuration
    static let handoff = 2.05
    static let end = 2.88
    static let clockScale = 4.25 / windowCue

    struct Key {
        let real: Double
        let shader: Double
        let speed: Double
    }

    static let pacing: [Key] = [
        .init(real: 0, shader: 0, speed: 0),
        .init(real: 1, shader: 0.06, speed: 0.15),
        .init(real: 2.40, shader: 0.52, speed: 0.30),
        .init(real: 3.20, shader: 1, speed: 0.55),
        .init(real: 4, shader: 1.75, speed: 0.80),
        .init(real: 4.25, shader: 2.05, speed: 1.30),
        .init(real: 5.60, shader: 3.15, speed: 0.55),
    ]

    static func smooth(_ a: Double, _ b: Double, _ time: Double) -> Double {
        let t = min(1, max(0, (time - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    static func shaderTime(audioTime: Double) -> Double {
        let real = audioTime * clockScale
        guard real.isFinite, real > 0 else { return 0 }
        guard real < pacing.last!.real else { return end }
        let index = pacing.lastIndex { $0.real <= real }!
        let a = pacing[index], b = pacing[index + 1]
        let h = b.real - a.real, t = (real - a.real) / h
        let t2 = t * t, t3 = t2 * t
        let value = (2 * t3 - 3 * t2 + 1) * a.shader + (t3 - 2 * t2 + t) * h * a.speed
            + (-2 * t3 + 3 * t2) * b.shader + (t3 - t2) * h * b.speed
        return min(end, max(a.shader, min(b.shader, value)))
    }

    static func dimming(audioTime: Double) -> Double {
        let real = audioTime * clockScale
        return 0.72 * smooth(0, 1.1, real) * (1 - smooth(3.30, 4.05, real))
    }

    /// One clock drives both surfaces: no blank proxy and no light tail
    /// over the fully revealed native window.
    static func windowOpacity(audioTime: Double) -> Double {
        smooth(revealStart, revealEnd, audioTime)
    }
}

/// A device disappearing or a backwards audio reading cannot strand a hidden
/// window. A healthy audio clock wins; a stalled one falls back to wall time.
struct LaunchArrivalProgress {
    private(set) var audioTime = 0.0
    var shaderTime: Double { LaunchArrivalTiming.shaderTime(audioTime: audioTime) }
    var windowOpacity: Double { LaunchArrivalTiming.windowOpacity(audioTime: audioTime) }
    var lightOpacity: Double { 1 - windowOpacity }
    var revealsWindow: Bool { windowOpacity > 0 }
    var finished: Bool { audioTime >= LaunchArrivalTiming.revealEnd }

    mutating func advance(wallTime: Double, audioTime reading: Double?) {
        guard wallTime.isFinite, wallTime >= 0 else { return }
        let valid = reading.flatMap { value -> Double? in
            guard value.isFinite, value >= 0, abs(value - wallTime) <= 0.25 else { return nil }
            return value
        }
        audioTime = max(audioTime, valid ?? wallTime)
    }
}

struct LaunchArrivalEligibility {
    var primary = true
    var offered = false
    var headless = false
    var hidden = false
    var reduceMotion = false
    var testing = false
    /// Played once already, or this Mac has been welcomed: the opening
    /// belongs to the first launch only, and to Show Again (`replay`).
    var seen = false
    /// nil is the normal launch; 1 opts an isolated visual probe in, 0 opts out.
    /// "first" lets a test world launch as a person's Mac would, once
    /// (evals/launch-arrival/first_launch.py).
    var overrideValue: String?

    var plays: Bool {
        primary && !offered && !headless && !hidden && !reduceMotion
            && overrideValue != "0" && (!testing || overrideValue == "1" || overrideValue == "first")
            && (!seen || overrideValue == "1")
    }
}
