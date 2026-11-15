import XCTest
@testable import YabPhone

/// FrameMeter's arithmetic: what counts as a long frame, hitch time per
/// second, main thread time per frame.
final class FrameMeterTests: XCTestCase {
    private let sixty = 1.0 / 60

    func testSmoothMotionHasNoLongFramesAndNoHitches() {
        let frames = Array(repeating: sixty, count: 20)
        let r = FrameMeter.summary(name: "chromeFold", start: 0, end: 20 * sixty, frames: frames,
                                   expected: frames, busy: Array(repeating: 0.002, count: 20))
        XCTAssertEqual(r.frames, 20)
        XCTAssertEqual(r.fps, 60)
        XCTAssertEqual(r.long, 0)
        XCTAssertEqual(r.long_share, 0)
        XCTAssertEqual(r.hitch_ms_per_s, 0)
        XCTAssertEqual(r.worst_ms, 16.7, accuracy: 0.05)
        XCTAssertEqual(r.main_avg_ms, 2, accuracy: 0.05)
        XCTAssertEqual(r.duration_ms, 333.3, accuracy: 0.1)
    }

    func testADroppedFrameIsLongAndItsExtraTimeIsHitch() {
        // Nine frames on time and one that took three frame times.
        let frames = Array(repeating: sixty, count: 9) + [3 * sixty]
        let duration = 12 * sixty
        let r = FrameMeter.summary(name: "columnOpen", start: 1, end: 1 + duration, frames: frames,
                                   expected: Array(repeating: sixty, count: 10), busy: [0.001, 0.03])
        XCTAssertEqual(r.long, 1)
        XCTAssertEqual(r.long_share, 0.1)
        XCTAssertEqual(r.worst_ms, 50, accuracy: 0.05)
        // 33.3 ms past its frame time over 0.2 s of motion.
        XCTAssertEqual(r.hitch_ms_per_s, 166.7, accuracy: 0.1)
        XCTAssertEqual(r.main_max_ms, 30)
        XCTAssertEqual(r.main_avg_ms, 15.5, accuracy: 0.05)
    }

    func testAFrameJustUnderOneAndAHalfIsNotLong() {
        let r = FrameMeter.summary(name: "x", start: 0, end: 0.1, frames: [sixty * 1.49, sixty],
                                   expected: [sixty, sixty], busy: [])
        XCTAssertEqual(r.long, 0)
        XCTAssertGreaterThan(r.hitch_ms_per_s, 0)
        XCTAssertEqual(r.main_avg_ms, 0)
    }

    func testNoFramesIsAnEmptyResultNotACrash() {
        let r = FrameMeter.summary(name: "x", start: 5, end: 5, frames: [], expected: [], busy: [])
        XCTAssertEqual(r.frames, 0)
        XCTAssertEqual(r.long_share, 0)
        XCTAssertEqual(r.hitch_ms_per_s, 0)
        XCTAssertEqual(r.fps, 60)
    }

    /// What perf.py and the motion tests read from a line: the Motion's
    /// duration, the signpost's name, and whether it played as a fade.
    @MainActor
    func testALineSaysItsMotionsDurationAndSignpost() throws {
        let meter = FrameMeter(environment: ["YAB_PERF_OUT": NSTemporaryDirectory() + "frames-\(UUID().uuidString).jsonl"])
        meter.begin("chromeFold", signpost: "fade", expected: 0.2)
        meter.end("chromeFold")
        meter.begin("columnOpen", expected: 0.475)
        meter.end("columnOpen")
        let fade = try XCTUnwrap(meter.results.first)
        XCTAssertEqual(fade.signpost, "fade")
        XCTAssertTrue(fade.fade)
        XCTAssertEqual(fade.expected_ms, 200)
        let open = try XCTUnwrap(meter.results.last)
        XCTAssertEqual(open.signpost, "columnOpen")
        XCTAssertFalse(open.fade)
        XCTAssertEqual(open.expected_ms, 475)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(open)) as? [String: Any])
        for key in ["signpost", "expected_ms", "first_ms", "first_main_ms", "fade", "main_max_ms", "duration_ms"] {
            XCTAssertNotNil(json[key], key)
        }
    }

    func testAOneTwentyHertzDisplayJudgesByItsOwnFrameTime() {
        let fast = 1.0 / 120
        // 1/60 s is two frame times at 120 Hz: long.
        let r = FrameMeter.summary(name: "x", start: 0, end: 0.1, frames: [fast, fast, sixty],
                                   expected: [fast, fast, fast], busy: [])
        XCTAssertEqual(r.fps, 120)
        XCTAssertEqual(r.long, 1)
    }
    func testSchemaTwoSeparatesNominalFromObservedCallbacksWithoutChangingLegacyLimits() throws {
        let fast = 1.0 / 120
        let result = FrameMeter.summary(name: "x", start: 0, end: 4 * fast,
                                        frames: [fast, fast, 2 * fast], expected: [fast, fast, fast],
                                        busy: [0.001, 0.002, 0.003, 0.004], cpu: [0.0005, 0.001, 0.0015, 0.002])
        XCTAssertEqual(result.schema_version, 2)
        XCTAssertEqual(result.data_kind, "display_link_callbacks")
        XCTAssertEqual(try XCTUnwrap(result.nominal_callback_hz), 120, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(result.observed_callback_hz), 90, accuracy: 0.000001)
        XCTAssertEqual(result.fps, 120, "legacy nominal alias keeps its historical meaning")
        XCTAssertEqual(result.long, 1)
        XCTAssertEqual(result.hitch_ms_per_s, 250, accuracy: 0.1)
        XCTAssertEqual(result.callback_sample_count, 3)
        XCTAssertEqual(result.main_wall_samples_ms, [1, 2, 3, 4])
        XCTAssertEqual(result.callback_intervals_ms, [fast * 1000, fast * 1000, 2 * fast * 1000])
        XCTAssertEqual(result.expected_callback_intervals_ms, Array(repeating: fast * 1000, count: 3))
        XCTAssertEqual(result.measurement_complete, true)
        XCTAssertEqual(try JSONDecoder().decode(FrameMeter.Result.self, from: JSONEncoder().encode(result)), result)
    }

    func testSchemaTwoKeepsEachAdaptiveExpectedInterval() throws {
        let fast = 1.0 / 120
        let intervals = [fast, fast, sixty]
        let result = FrameMeter.summary(name: "adaptive", start: 0, end: intervals.reduce(0, +),
                                        frames: intervals, expected: intervals, busy: [])
        XCTAssertEqual(result.expected_callback_intervals_ms, intervals.map { $0 * 1000 })
        XCTAssertEqual(result.long, 0)
        XCTAssertEqual(result.hitch_ms_per_s, 0)
        XCTAssertEqual(try XCTUnwrap(result.nominal_callback_hz), 120, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(result.observed_callback_hz), 90, accuracy: 0.000001)
    }

    func testSchemaTwoEmptyResultDoesNotInventObservedSixtyHertz() {
        let result = FrameMeter.summary(name: "empty", start: 1, end: 1.1, frames: [], expected: [], busy: [])
        XCTAssertEqual(result.fps, 60, "the old alias stays readable but cannot certify data")
        XCTAssertNil(result.nominal_callback_hz)
        XCTAssertNil(result.observed_callback_hz)
        XCTAssertNil(result.first_callback_ms)
        XCTAssertEqual(result.callback_sample_count, 0)
        XCTAssertEqual(result.measurement_complete, false)
    }

    func testSchemaTwoInvalidSamplesAreNullableAtOriginalPositionsAndCannotPass() throws {
        let result = FrameMeter.summary(name: "invalid", start: 0, end: 0.1,
                                        frames: [sixty, .nan, 0], expected: [sixty, sixty, .infinity],
                                        busy: [0.002, .infinity])
        XCTAssertEqual(result.callback_sample_count, 3)
        XCTAssertEqual(result.invalid_sample_count, 3)
        XCTAssertEqual(result.measurement_complete, false)
        XCTAssertNil(result.nominal_callback_hz)
        XCTAssertNil(result.observed_callback_hz)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        let raw = try XCTUnwrap(json["callback_intervals_ms"] as? [Any])
        XCTAssertEqual(raw.count, 3)
        XCTAssertTrue(raw[1] is NSNull)
        XCTAssertEqual(raw[2] as? Double, 0)
        XCTAssertEqual(try JSONDecoder().decode(FrameMeter.Result.self, from: JSONEncoder().encode(result)), result)
    }

    func testSchemaTwoUnpairedExpectedIntervalsAreIncomplete() {
        let result = FrameMeter.summary(name: "unpaired", start: 0, end: 0.1,
                                        frames: [sixty, sixty], expected: [sixty], busy: [])
        XCTAssertEqual(result.measurement_complete, false)
        XCTAssertEqual(result.invalid_sample_count, 1)
        XCTAssertNil(result.observed_callback_hz)
    }

    func testFirstCallbackIsOptionalRawAndLegacyAliasIsRounded() throws {
        var result = FrameMeter.summary(name: "first", start: 0, end: 0.1,
                                        frames: [sixty], expected: [sixty], busy: [])
        XCTAssertNil(result.first_callback_ms)
        result.recordFirstCallback(after: 0.021234567, mainWall: 0.009876543)
        XCTAssertEqual(try XCTUnwrap(result.first_callback_ms), 21.234567, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(result.first_callback_main_wall_ms), 9.876543, accuracy: 0.000001)
        XCTAssertEqual(result.first_ms, 21.2)
        XCTAssertEqual(result.first_main_ms, 9.9)
    }

    func testSchemaOneDecodePreservesOldNumbersWithoutCreatingRawSamples() throws {
        let old = Data(#"{"name":"old","duration_ms":340,"frames":20,"fps":60,"worst_ms":16.7,"long":0,"long_share":0,"hitch_ms_per_s":0,"main_avg_ms":2,"main_max_ms":4,"t":1}"#.utf8)
        let result = try JSONDecoder().decode(FrameMeter.Result.self, from: old)
        XCTAssertEqual(result.fps, 60)
        XCTAssertEqual(result.duration_ms, 340)
        XCTAssertNil(result.schema_version)
        XCTAssertNil(result.callback_intervals_ms)
        XCTAssertNil(result.first_callback_ms)
        XCTAssertEqual(result.first_ms, 0)
        XCTAssertEqual(result.main_cpu_max_ms, 0)
    }

}
