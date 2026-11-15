import Foundation

// When a change was made, in a way every device agrees on. A hybrid logical
// clock: the wall time in milliseconds, a counter for changes within the same
// millisecond or after a clock that ran ahead, and the device that made it,
// so no two changes are ever equal and every device picks the same winner.

public struct Stamp: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public var wall: Int64
    public var count: UInt32
    public var device: String

    public init(wall: Int64, count: UInt32 = 0, device: String) {
        self.wall = wall
        self.count = count
        self.device = device
    }

    public static func < (a: Stamp, b: Stamp) -> Bool {
        if a.wall != b.wall { return a.wall < b.wall }
        if a.count != b.count { return a.count < b.count }
        return a.device < b.device
    }

    public var description: String { "\(wall).\(count)@\(device)" }
}

/// Hands out stamps for one device. Each is later than every stamp this
/// device made or saw, and close to the wall clock.
public final class Clock: @unchecked Sendable {
    public let device: String
    /// A stamp further ahead of this Mac's wall clock than this is not
    /// followed: one device with its date set to next year would otherwise
    /// drag every later change on every device with it.
    public static let drift: Int64 = 24 * 60 * 60 * 1000

    private var last: Stamp
    private let lock = NSLock()
    private let now: () -> Int64

    public init(device: String, last: Stamp? = nil, now: @escaping () -> Int64 = Clock.wallNow) {
        self.device = device
        self.now = now
        self.last = last ?? Stamp(wall: 0, device: device)
    }

    public static func wallNow() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)) }

    /// A stamp for a change made here, now.
    public func tick() -> Stamp {
        lock.lock(); defer { lock.unlock() }
        let wall = now()
        if wall > last.wall {
            last = Stamp(wall: wall, count: 0, device: device)
        } else {
            last = Stamp(wall: last.wall, count: last.count &+ 1, device: device)
        }
        return last
    }

    /// Takes in a stamp from elsewhere, so the next change made here comes
    /// after it. Returns false, and follows nothing, for one too far ahead.
    @discardableResult
    public func observe(_ other: Stamp) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let wall = now()
        guard other.wall <= wall + Clock.drift else { return false }
        if other.wall > last.wall || (other.wall == last.wall && other.count > last.count) {
            last = Stamp(wall: other.wall, count: other.count, device: device)
        }
        return true
    }

    /// The latest stamp, to be written down and handed back to `init`.
    public var latest: Stamp {
        lock.lock(); defer { lock.unlock() }
        return last
    }
}
