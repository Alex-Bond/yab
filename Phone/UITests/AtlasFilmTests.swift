import XCTest

/// One transition, filmed: Phone/scripts/phone film starts this test,
/// waits for it to say the app is ready, starts `simctl io recordVideo`, and
/// the test makes the movement with a real finger while the camera runs.
/// The handshake is files in YAB_OUT/film:
///
///     ready       the test: the app is in its start state, still
///     recording   the script: the camera runs
///     done        the test: the movement arrived (times inside, JSON)
///
///     YAB_FILM_TRANSITION  a TransitionCatalog name (chromeFold ...)
///     YAB_FILM_STATE       a named state to start from instead of the transition's own
final class AtlasFilmTests: XCTestCase {
    func testFilm() throws {
        let env = Atlas.environment
        // Only `Phone/scripts/phone film` starts it with a transition to film;
        // in a run of every UI test it has nothing to do.
        guard let name = env["YAB_FILM_TRANSITION"].flatMap({ $0.isEmpty ? nil : $0 }) else {
            throw XCTSkip("no transition to film (YAB_FILM_TRANSITION is set by Phone/scripts/phone film)")
        }
        var transition = try XCTUnwrap(TransitionCatalog.named(name), "no transition named \(name)")
        if let state = env["YAB_FILM_STATE"], !state.isEmpty { transition.state = state }
        let arguments = transition.arguments + (env["YAB_FILM_REDUCED"] == "1" ? ["-YabReduceMotion", "YES"] : [])
        let folder = Atlas.out.appendingPathComponent("film", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in ["ready", "recording", "done"] { try? FileManager.default.removeItem(at: folder.appendingPathComponent(file)) }

        let app = XCUIApplication()
        let ready = Atlas.readyFolder()
        // The app marks the first motion after the camera starts (FrameMeter.FilmMark).
        var environment = ["YAB_FRAMEMETER": "1", "YAB_FILM_MARK": folder.appendingPathComponent("recording").path,
                           "YAB_PERF_OUT": folder.appendingPathComponent("frames.jsonl").path]
        if env["YAB_LOOK_DIAGNOSTIC"] == "1", name == "spaceTrayOpen" {
            environment["YAB_TEST"] = "1"
            environment["YAB_LOOK_DIAGNOSTIC_PATH"] = folder.appendingPathComponent("look-state.jsonl").path
        }
        if let state = transition.state {
            XCTAssertTrue(Atlas.launch(app, state: state, ready: ready, still: false, extra: arguments, environment: environment),
                          "\(state) never settled")
        } else {
            app.launchArguments = ["-YabWorld", Atlas.world] + arguments
            app.launchEnvironment = environment
            app.launch()
        }
        XCTAssertTrue(transition.ready(app), "\(name): never ready to start")
        try Data().write(to: folder.appendingPathComponent("ready"))
        XCTAssertTrue(Atlas.waitForFile(folder.appendingPathComponent("recording"), timeout: 30), "the camera never started")
        // A still moment before, so the strip starts from the start state.
        Thread.sleep(forTimeInterval: 0.5)
        let start = Date()
        transition.perform(app)
        let touched = Date()
        let arrived = transition.arrived(app)
        let end = Date()
        Thread.sleep(forTimeInterval: 0.6)
        let times: [String: Any] = [
            "transition": name, "state": transition.state ?? "",
            "start": start.timeIntervalSince1970, "touched": touched.timeIntervalSince1970,
            "arrived": end.timeIntervalSince1970, "ok": arrived,
        ]
        try Atlas.json(times).write(to: folder.appendingPathComponent("done"))
        XCTAssertTrue(arrived, "\(name): the movement didn't arrive")
    }
}
