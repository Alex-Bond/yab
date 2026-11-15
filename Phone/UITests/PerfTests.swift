import XCTest

/// Level 1 of PLAN-iphone.md section 8: on the simulator, compared only with
/// the same Mac's same simulator (Phone/perf/baselines). Each transition of
/// TransitionCatalog is repeated under XCTOSSignpostMetric on its Motion's
/// signposts, while the app's FrameMeter writes each repeat's frames (worst
/// frame, long frames, main thread time per frame, the first frame) to
/// YAB_OUT/perf/frames.jsonl, between the test's own start and stop marks.
/// Launch and memory too. `Phone/scripts/remote perf` runs these, collects
/// both and compares them with the baseline.
///
/// Memory: XCTMemoryMetric and XCTCPUMetric see Yab's own process only, and
/// a page's memory is its WebContent process's. So while perf runs, the
/// script samples every process of the simulator, Yab's and WebKit's, once
/// a second (perf/memory.jsonl), and the collector reads them between the
/// same marks: testPagingMemory's tabs, made and let go over and over, must
/// not leave memory behind (8.2: no growth after paging).
///
/// XCTest takes one measure per test method, so each transition has its own
/// test: a feature adds `func testSpacesMorph() throws { try measure("spacesMorph") }`
/// in its own `PerfTests+<Feature>.swift`.
///
///     YAB_PERF_REPEATS  repeats per transition (default 5)
final class PerfTests: XCTestCase {
    static let subsystem = "dev.serafim.fast.iphone"
    static let category = "PointsOfInterest"

    override func setUp() {
        continueAfterFailure = false
    }

    var repeats: Int { max(1, Int(Atlas.environment["YAB_PERF_REPEATS"] ?? "") ?? 5) }
    private var framesFile: URL { Atlas.out.appendingPathComponent("perf/frames.jsonl") }

    // MARK: - the page

    func testChromeFold() throws { try measure("chromeFold") }
    func testChromeUnfold() throws { try measure("chromeUnfold") }

    // MARK: - launch and memory

    /// Launch until the app answers, mira's first page.
    func testLaunch() throws {
        let options = XCTMeasureOptions()
        options.iterationCount = repeats
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options) {
            let app = XCUIApplication()
            app.launchArguments = ["-YabWorld", Atlas.world]
            app.launch()
        }
    }

    /// Memory and CPU of the app scrolling a long page down and up (Yab's
    /// process; the page's WebContent process is in perf/memory.jsonl).
    func testScrollMemory() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-YabWorld", Atlas.world, "-YabTab", "work-launch-notes"]
        app.launch()
        let page = app.webViews.firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 60))
        let options = XCTMeasureOptions()
        options.iterationCount = repeats
        var iteration = 0
        measure(metrics: [XCTMemoryMetric(application: app), XCTCPUMetric(application: app)], options: options) {
            iteration += 1
            mark("start", "scroll", iteration, memory: true)
            page.swipeUp(velocity: .fast)
            page.swipeDown(velocity: .fast)
            mark("stop", "scroll", iteration, memory: true)
        }
    }

    /// Every tab of the world in front in turn, over and over, the app
    /// turning them itself (`-YabState perf.paging`, a tab every 0.6 s): web
    /// views are made and let go the way paging does (WebPool keeps three).
    /// Each repeat goes once round the world's tabs, so XCTest's warm-up
    /// repeat has made every page once (WebKit keeps some of their processes
    /// for a while) and the measured repeats see the same round again.
    /// Yab's memory and CPU here; Yab's and WebKit's processes together in
    /// perf/memory.jsonl, which must not grow from the first measured repeat
    /// to the last. Mira's tabs until the `heavy` world comes.
    func testPagingMemory() throws {
        let app = XCUIApplication()
        let ready = Atlas.readyFolder()
        let gap = 0.6
        XCTAssertTrue(Atlas.launch(app, state: "perf.paging", ready: ready, still: false,
                                   environment: ["YAB_PAGING_MS": "\(Int(gap * 1000))", "YAB_HAPTICS_SILENT": "1"]),
                      "perf.paging never started")
        // The app says how many tabs it turns: "tabs=25".
        let notes = (try? String(contentsOf: ready.appendingPathComponent("perf.paging"), encoding: .utf8)) ?? ""
        let tabs = notes.split(separator: "\n").first { $0.hasPrefix("tabs=") }.flatMap { Int($0.dropFirst(5)) } ?? 25
        let round = Double(tabs) * gap + 1
        let options = XCTMeasureOptions()
        options.iterationCount = repeats
        var iteration = 0
        measure(metrics: [XCTMemoryMetric(application: app), XCTCPUMetric(application: app)], options: options) {
            iteration += 1
            mark("start", "paging", iteration, memory: true)
            RunLoop.current.run(until: Date().addingTimeInterval(round))
            mark("stop", "paging", iteration, memory: true)
        }
        app.terminate()
    }

    // MARK: - running a transition

    /// Measures a transition of TransitionCatalog by name, `repeats` times.
    func measure(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let transition = try XCTUnwrap(TransitionCatalog.named(name), "no transition named \(name)", file: file, line: line)
        let ready = Atlas.readyFolder()
        var app = launch(transition, ready: ready)
        XCTAssertTrue(transition.ready(app), "\(name): never ready to start", file: file, line: line)
        let metrics: [XCTMetric] = transition.signposts.map {
            XCTOSSignpostMetric(subsystem: Self.subsystem, category: Self.category, name: $0)
        }
        let options = XCTMeasureOptions()
        options.iterationCount = repeats
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        var iteration = 0
        var missed: [Int] = []
        measure(metrics: metrics, options: options) {
            iteration += 1
            if transition.undo == nil && iteration > 1 {
                app = launch(transition, ready: ready)
                _ = transition.ready(app)
            }
            mark("start", name, iteration)
            startMeasuring()
            transition.perform(app)
            let arrived = transition.arrived(app)
            // The movement's last frames and its signpost's end, inside.
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            stopMeasuring()
            mark("stop", name, iteration)
            if !arrived { missed.append(iteration) }
            transition.undo?(app)
        }
        XCTAssertTrue(missed.isEmpty, "\(name): didn't arrive in repeats \(missed)", file: file, line: line)
        app.terminate()
    }

    private func launch(_ transition: Transition, ready: URL) -> XCUIApplication {
        let app = XCUIApplication()
        let environment = ["YAB_FRAMEMETER": "1", "YAB_PERF_OUT": framesFile.path, "YAB_HAPTICS_SILENT": "1"]
        if let state = transition.state {
            Atlas.launch(app, state: state, ready: ready, still: false, extra: transition.arguments, environment: environment)
        } else {
            app.launchArguments = ["-YabWorld", Atlas.world] + transition.arguments
            app.launchEnvironment = environment
            app.launch()
        }
        return app
    }

    /// A line in the frames file, so the collector knows which of the app's
    /// lines, and which memory samples (by `t`, the Mac's clock, which the
    /// simulator shares), fell inside which measured repeat.
    /// `memory`: a window the collector reads the processes' memory in.
    private func mark(_ what: String, _ transition: String, _ iteration: Int, memory: Bool = false) {
        let t = String(format: "%.3f", Date().timeIntervalSince1970)
        let line = "{\"mark\":\"\(what)\",\"transition\":\"\(transition)\",\"iteration\":\(iteration),\"test\":\"\(name)\",\"t\":\(t),\"memory\":\(memory)}\n"
        let url = framesFile
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
