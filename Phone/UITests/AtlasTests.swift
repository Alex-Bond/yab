import XCTest

/// Every registered state in one run: launched still, settled, pictured, and
/// its elements' frames written beside the picture, the same files
/// `Phone/scripts/phone shot` makes (shots/<model>/<state>.png and
/// .frames.json; with YAB_XCUI=1 also .xcui.json, the tree as XCTest reads
/// it). The pictures are attached to the result too.
///
/// Slower than `shot --all` (which relaunches with simctl): XCTest waits for
/// the app to go idle after each launch, 6 s a state at best, and the
/// xcodebuild run around it costs half a minute; so `shot` stays the way to
/// re-shoot, and this is the way to have every picture in one result bundle.
///
///     Phone/scripts/remote ui AtlasTests
///     Phone/scripts/remote atlas [STATE...] [--device M]   (the same, collected)
final class AtlasTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    func testEveryState() throws {
        let app = XCUIApplication()
        let states = Atlas.states(app)
        XCTAssertFalse(states.isEmpty, "no states: neither YAB_STATES nor the app's catalog")
        let ready = Atlas.readyFolder()
        let folder = "shots/\(Atlas.model)"
        var failed: [String] = []
        var timings: [String] = []
        let started = Date()
        // XCTest's own tree too, with YAB_XCUI=1: it agrees with the app's
        // frames to the hundredth of a point, and costs seconds a state.
        let tree = Atlas.environment["YAB_XCUI"] == "1"
        for (name, title) in states {
            let t0 = Date()
            // A page that never drew is taken again; still blank, it is a
            // .not-ready picture and a failure, never a pass.
            let outcome = Atlas.open(app, state: name, ready: ready)
            let settled = outcome == .settled
            let t1 = Date()
            let shot = settled ? Atlas.picture() : XCUIScreen.main.screenshot()
            let t2 = Date()
            let suffix = settled ? "" : ".not-ready"
            Atlas.write(shot.pngRepresentation, to: "\(folder)/\(name)\(suffix).png")
            let frames = ready.appendingPathComponent("\(name).frames.json")
            if let data = try? Data(contentsOf: frames) { Atlas.write(data, to: "\(folder)/\(name).frames.json") }
            if let notes = try? Data(contentsOf: ready.appendingPathComponent(name)) { Atlas.write(notes, to: "\(folder)/\(name).txt") }
            if tree {
                Atlas.write(Atlas.json(["state": name, "source": "xcui", "elements": Atlas.elements(app)]), to: "\(folder)/\(name).xcui.json")
            }
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = "\(name) \(title)"
            attachment.lifetime = .keepAlways
            add(attachment)
            let seconds = Date().timeIntervalSince(t0)
            timings.append(String(format: "%@ %.2f (launch and settle %.2f, picture %.2f, rest %.2f)", name, seconds,
                                  t1.timeIntervalSince(t0), t2.timeIntervalSince(t1), Date().timeIntervalSince(t2)))
            print("atlas: shot \(timings.last!)\(settled ? "" : " NOT READY: \(outcome.words)")")
            if !settled { failed.append("\(name) (\(outcome.words))") }
        }
        let total = Date().timeIntervalSince(started)
        timings.append(String(format: "total %.2f for %d states", total, states.count))
        Atlas.write(Data((timings.joined(separator: "\n") + "\n").utf8), to: "\(folder)/atlas-timings.txt")
        XCTAssertTrue(failed.isEmpty, "never settled: \(failed.joined(separator: ", "))")
    }
}
