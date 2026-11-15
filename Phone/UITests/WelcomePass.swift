import XCTest

extension XCUIApplication {
    /// The first run's way on without a Mac (Welcome/FirstRun): Get Started,
    /// Continue Without a Mac, Continue under Private by Default, and Not Now
    /// on the optional default-browser step; the icon then stretches into
    /// the New Tab field over the empty page. Each step waits for its button
    /// to stand still: the steps morph into each other on springs, and a tap
    /// taken while one settles can land on what is still moving.
    func passWelcome(timeout: TimeInterval = 10) {
        for (id, wait) in [("welcome.start", timeout), ("welcome.noMac", 5), ("welcome.continue", 5)] {
            let button = buttons[id]
            guard button.waitForExistence(timeout: wait) else { return }
            button.waitUntilStill()
            button.tap()
        }
        let links = buttons["welcome.linksNotNow"]
        if links.waitForExistence(timeout: 5) {
            links.waitUntilStill()
            links.tap()
        }
    }

    /// Closes the field (the New Tab field the first run leaves over the
    /// page, or any other) by its ✕: New Tab's spaces fill the screen around
    /// it, so a tap "beside" it lands on a row (65619b17, aaf8443d). Waits
    /// for ✕ to land and for the field and keyboard to go.
    @discardableResult
    func closeField(timeout: TimeInterval = 5) -> Bool {
        let input = textFields["field.input"]
        guard input.waitForExistence(timeout: timeout) else { return true }
        let close = buttons["field.close"]
        // A tap a loaded farm Mac lost (a77f3205283a458a: ✕ on screen, the
        // field still up 13 s later) is taken again, as a finger would.
        for _ in 0..<3 where input.exists {
            close.waitUntilStill()
            if close.exists { close.tap() }
            let end = Date().addingTimeInterval(4)
            while input.exists || keyboards.firstMatch.exists, Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        }
        let end = Date().addingTimeInterval(4)
        while input.exists || keyboards.firstMatch.exists, Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        return !input.exists && !keyboards.firstMatch.exists
    }
}

extension XCUIElement {
    /// Hittable, and in the same place on two looks a beat apart: a spring
    /// has stopped moving it. Gives up after `timeout` and lets the tap tell.
    func waitUntilStill(timeout: TimeInterval = 5) {
        let end = Date().addingTimeInterval(timeout)
        var last = CGRect.null
        while Date() < end {
            let now = exists ? frame : .null
            if !now.isNull, now == last, isHittable { return }
            last = now
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
    }
}
