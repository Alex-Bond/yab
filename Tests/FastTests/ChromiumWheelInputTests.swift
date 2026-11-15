import AppKit
import Testing
import YabCoreClient
@testable import Fast

/// A Chromium tab's wheel crosses to YabCore as the scroll's own CGEvent,
/// so Chrome's WebMouseWheelEventBuilder reads what it reads in Chrome
/// (R2566). The fields it reads are compared on the event YabCore decodes.
@MainActor
struct ChromiumWheelInputTests {
    private func wheel(precise: Bool, lines: Double = -0.1, points: Int64 = -1, pixels: Double = -2.75,
                       phase: Int64 = 0, momentum: Int64 = 0, flags: CGEventFlags = []) throws -> NSEvent {
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line,
            wheelCount: 2, wheel1: -1, wheel2: 0, wheel3: 0))
        cg.flags = flags
        cg.timestamp = 123_456_789_012
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: precise ? 1 : 0)
        // A smooth device's points are whole and its fixed-point deltas are
        // not; a notch's lines are accelerated fractions (0.1 a slow notch).
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: points)
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: precise ? pixels : lines)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        return try #require(NSEvent(cgEvent: cg))
    }

    private func decoded(_ fields: [String: JSONValue]) throws -> CGEvent {
        guard case .string(let bytes)? = fields["event"] else { Issue.record("no event bytes"); throw CancellationError() }
        let data = try #require(Data(base64Encoded: bytes))
        return try #require(CGEvent(withDataAllocator: nil, data: data as CFData))
    }

    /// What Chrome's builder reads off a wheel (web_input_event_builders_mac.mm).
    private func chromeReads(_ cg: CGEvent) throws -> [Double] {
        let event = try #require(NSEvent(cgEvent: cg))
        let continuous = cg.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let dx = continuous ? Double(cg.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)) : Double(event.deltaX) * 40
        let dy = continuous ? Double(cg.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)) : Double(event.deltaY) * 40
        return [continuous ? 1 : 0, dx, dy,
                Double(cg.getIntegerValueField(.scrollWheelEventDeltaAxis2)),
                Double(cg.getIntegerValueField(.scrollWheelEventDeltaAxis1)),
                Double(event.phase.rawValue), Double(event.momentumPhase.rawValue),
                Double(event.modifierFlags.rawValue), event.timestamp]
    }

    @Test(arguments: [false, true])
    func theScrollCrossesWhole(precise: Bool) throws {
        let event = try wheel(precise: precise, phase: precise ? 2 : 0, momentum: 0)
        let fields = ChromiumWheelInput.fields(event, at: NSPoint(x: 5, y: 9))
        #expect(fields["x"] == .number(5))
        #expect(fields["y"] == .number(9))
        #expect(fields["timestamp"] == .number(event.timestamp))
        #expect(fields["notch"] == nil)
        #expect(fields["deltaY"] == nil)
        let original = try #require(event.cgEvent)
        #expect(try chromeReads(decoded(fields)) == chromeReads(original))
    }

    @Test func aSmoothDevicesPointsAreItsOwn() throws {
        // Chrome reads a continuous wheel's points, not its fixed-point
        // delta nor AppKit's scrollingDelta: they stay as the device sent them.
        let event = try wheel(precise: true, points: -3, pixels: -2.75, phase: 0, momentum: 2)
        let cg = try decoded(ChromiumWheelInput.fields(event, at: .zero))
        #expect(cg.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == -3)
        #expect(cg.getIntegerValueField(.scrollWheelEventIsContinuous) == 1)
        #expect(cg.getIntegerValueField(.scrollWheelEventMomentumPhase) == 2)
    }

    @Test func aSlowNotchKeepsItsAcceleratedLinesAndTick() throws {
        let event = try wheel(precise: false, lines: -0.1)
        let cg = try decoded(ChromiumWheelInput.fields(event, at: .zero))
        #expect(cg.getIntegerValueField(.scrollWheelEventDeltaAxis1) == -1)
        #expect(cg.getIntegerValueField(.scrollWheelEventIsContinuous) == 0)
        let decodedEvent = try #require(NSEvent(cgEvent: cg))
        #expect(decodedEvent.deltaY == event.deltaY)
        #expect(!decodedEvent.hasPreciseScrollingDeltas)
    }

    @Test func modifiersAndTheClockStay() throws {
        let event = try wheel(precise: false, flags: [.maskControl, .maskShift])
        let cg = try decoded(ChromiumWheelInput.fields(event, at: .zero))
        #expect(cg.flags == event.cgEvent?.flags)
        #expect(cg.timestamp == 123_456_789_012)
    }
}
