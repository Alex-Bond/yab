import AppKit

/// Keep the release behind the script that suppresses the page's click.
/// A press committed to Force Click cannot become a page drag meanwhile.
@MainActor
struct ChromiumForceClickInput {
    private var serial = 0
    private var pending = false
    private var active = false
    private var release: NSEvent?
    private var discardRelease = false

    private(set) var releaseCount = 0

    init() {}

    var holdsInput: Bool { active || discardRelease }

    mutating func begin() -> Int {
        serial &+= 1
        pending = true
        active = true
        release = nil
        return serial
    }

    mutating func interceptDown() -> Bool {
        if pending { discardRelease = true; return true }
        // A new down also ends a press whose capture was lost outside Yab.
        active = false
        return false
    }

    mutating func interceptUp(_ event: NSEvent) -> Bool {
        if discardRelease { discardRelease = false; return true }
        guard active else { return false }
        releaseCount &+= 1
        if pending {
            if release == nil { release = event }
            return true
        }
        active = false
        return false
    }

    mutating func finish(_ press: Int, handled: Bool) -> NSEvent? {
        guard pending, press == serial else { return nil }
        pending = false
        let up = release
        release = nil
        active = handled && up == nil
        return up
    }
}
