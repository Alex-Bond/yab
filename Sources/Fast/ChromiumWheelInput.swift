import AppKit
import YabCoreClient

/// A wheel for a Chromium page or popup goes to YabCore as the scroll's own
/// CGEvent, whole (R2566). Chrome reads it in WebMouseWheelEventBuilder: the
/// continuous bit, a precise device's point deltas, a notch's accelerated
/// lines and ticks, phases, momentum, flags, the clock; cc then animates a
/// notch or not as Chromium does (NSScrollAnimationEnabled; Reduce Motion
/// doesn't stop it in Chrome). Rebuilt from AppKit's few numbers, as before,
/// Reduce Motion or smooth scrolling off made a notch Yab's own instant jump
/// of whole points (3 for a slow notch's 4, its tick dropped), a device's
/// points were scrollingDelta cut to whole ones rather than the fields Chrome
/// reads, and a popup got NSEvent's phase bits as CGEvent's (a trackpad's
/// "changed" read as "ended") and a notch's lines as points (a slow notch's
/// 0.1 as none). YabCore only moves the event to its own window
/// (wheel_event.h). Without a CGEvent the old fields still describe it.
@MainActor
enum ChromiumWheelInput {
    static func fields(_ event: NSEvent, at point: NSPoint) -> [String: JSONValue] {
        var fields: [String: JSONValue] = ["x": .number(point.x), "y": .number(point.y),
            "timestamp": .number(event.timestamp),
            "modifiers": .number(Double(event.modifierFlags.rawValue))]
        if let data = event.cgEvent?.data as Data?, !data.isEmpty {
            fields["event"] = .string(data.base64EncodedString())
            return fields
        }
        fields["deltaX"] = .number(event.scrollingDeltaX)
        fields["deltaY"] = .number(event.scrollingDeltaY)
        fields["phase"] = .number(Double(ChromiumWheelPhase.gesture(event.phase)))
        fields["momentumPhase"] = .number(Double(ChromiumWheelPhase.momentum(event.momentumPhase)))
        if !event.hasPreciseScrollingDeltas {
            fields["notch"] = .bool(true)
            fields["ticksX"] = .number(tick(event.scrollingDeltaX))
            fields["ticksY"] = .number(tick(event.scrollingDeltaY))
        }
        return fields
    }

    private static func tick(_ lines: CGFloat) -> Double { lines > 0 ? 1 : lines < 0 ? -1 : 0 }
}
