import Foundation
import Testing
@testable import Fast

struct SitePermissionsChromiumTests {
    /// A write of anything to the settings (a window frame, a scroll) reads
    /// them once and stops there when no answer a site was given changed.
    @Test @MainActor func anUnrelatedWriteSaysNothingAgain() {
        let before: [String: Any] = ["notifications.https://example.test": true, "window.frame": "1 2 3 4"]
        var after = before
        after["window.frame"] = "5 6 7 8"
        let said = ChromiumPermissions.wanted(before)
        #expect(!ChromiumPermissions.due(ChromiumPermissions.wanted(after), after: said))
        after["notifications.https://example.test"] = false
        #expect(ChromiumPermissions.due(ChromiumPermissions.wanted(after), after: said))
        // Nothing said yet to this helper: everything is due.
        #expect(ChromiumPermissions.due(said, after: nil))
    }

    /// A call allowed on this visit (register 2319): Chromium holds the
    /// camera and the microphone for the site while the visit lasts, as
    /// Chrome's "Allow this time", so the page lists and picks its speakers.
    /// A remembered no is never turned into a yes, and nothing is held once
    /// the visit is over.
    @Test @MainActor func aVisitsYesIsHeldInChromiumWhileItLasts() {
        let remembered = ChromiumPermissions.wanted(["capture.https://zoom.test:443|0": false])
        let goal = ChromiumPermissions.goal("Default", remembered: remembered,
            visits: [("https://meet.google.com:443", [.cameraAndMicrophone]), ("https://zoom.test:443", [.microphone, .camera])])
        #expect(goal["https://meet.google.com|camera"] == "allow")
        #expect(goal["https://meet.google.com|microphone"] == "allow")
        #expect(remembered["https://zoom.test|camera"] == "block" && goal["https://zoom.test|camera"] == "block")
        #expect(goal["https://zoom.test|microphone"] == "allow")
        let over = ChromiumPermissions.goal("Default", remembered: remembered, visits: [])
        #expect(over["https://meet.google.com|microphone"] == nil)
        #expect(ChromiumPermissions.changes(from: goal, to: over).contains { $0.origin == "https://meet.google.com" && $0.value == "default" })
    }
}
