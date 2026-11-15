import Foundation
import QuartzCore
import UIKit
import os

/// Display-link callbacks of each signposted motion in DEBUG test builds
/// (PLAN-iphone.md 8.1, level 1). Timestamp gaps and run-loop work are
/// comparative proxies, not unique presented frames or render-server hitches.
/// Run-loop observers add up main-thread work between callbacks. When the
/// interval ends, one line of JSON says how it went:
///
///     {"name":"chromeFold","signpost":"chromeFold","expected_ms":340,
///      "duration_ms":352.1,"frames":21,"fps":60,"worst_ms":33.4,"long":1,
///      "long_share":0.048,"hitch_ms_per_s":47.3,"main_avg_ms":4.1,
///      "main_max_ms":9.8,"main_cpu_avg_ms":2.9,"main_cpu_max_ms":6.1,
///      "first_ms":21.2,"first_main_ms":9.8,"fade":false,
///      "t":12.302,"begin":1791280162.061}
///
/// `t` is when it ended, in seconds since the meter's first motion; `begin`
/// when it began on the wall clock (the simulator's is the Mac's), which is
/// how a film finds the motion in its recording. `expected_ms` is the
/// Motion's own duration (Design/Motion.swift), what the signpost's should
/// be within 20 % of (PLAN-iphone.md 5.3); `signpost` is the interval's name,
/// `fade` under Reduce Motion, when the morph plays as a short cross-fade.
///
/// Busy time is everything the main thread does between waking and going to
/// sleep, its frame's layout, render and commit included: the observer that
/// ends a busy stretch runs last of all before the run loop sleeps (order
/// CFIndex.max, after Core Animation's commit at 2,000,000), the one that
/// starts it first after waking. The first eligible callback counts too.
/// `first_callback_ms` is measured from Motion.begin to that callback;
/// it does not observe UITouch or prove a visible frame. `first_ms` remains
/// its rounded legacy alias. External Release traces measure presentation.
///
/// A long frame took more than one and a half of the display's frame time;
/// hitch time is what frames took past their own frame time, per second of
/// the motion, a display-link delay proxy rather than Apple's render hitch ratio.
/// The simulator draws on the Mac's GPU, so
/// these numbers are only compared with the same Mac's, same simulator's
/// (Phone/perf/baselines).
///
/// On with YAB_FRAMEMETER=1 or -YabFrameMeter YES, in debug builds; lines go
/// to YAB_PERF_OUT (a file on the Mac running the simulator, for UI tests) or
/// Library/Caches/yab-frames.jsonl.
@MainActor
final class FrameMeter {
    static let shared: FrameMeter? = {
        #if DEBUG
        let info = ProcessInfo.processInfo
        let arguments = info.arguments
        let asked = info.environment["YAB_FRAMEMETER"] == "1"
            || arguments.firstIndex(of: "-YabFrameMeter").map { $0 + 1 < arguments.count && ["yes", "true", "1"].contains(arguments[$0 + 1].lowercased()) } == true
        return asked ? FrameMeter(environment: info.environment) : nil
        #else
        return nil
        #endif
    }()

    /// One open motion's frames so far.
    private final class Interval {
        let name: String
        let signpost: String
        let expectedDuration: Double
        let start: CFTimeInterval
        /// The wall clock at the start, to find the motion in a recording.
        let began = Date().timeIntervalSince1970
        var frames: [Double] = []      // seconds between this frame and the last
        var expected: [Double] = []    // the display's frame time then
        var busy: [Double] = []        // main thread busy since the last frame
        var cpu: [Double] = []         // the main thread's own CPU time in it
        /// The first eligible callback after Motion.begin and main-thread
        /// work before it; nil until observed, not a visible-frame timestamp.
        var firstFrame: Double?
        var firstBusy: Double = 0
        #if DEBUG
        var nativeID: UUID?
        var logicalBeginObserved = false
        #endif
        init(name: String, signpost: String, expected: Double, start: CFTimeInterval) {
            self.name = name; self.signpost = signpost; self.expectedDuration = expected; self.start = start
        }
    }

    struct Result: Codable, Equatable {
        var name: String
        var duration_ms: Double
        var frames: Int
        var fps: Double
        var worst_ms: Double
        var long: Int
        var long_share: Double
        var hitch_ms_per_s: Double
        var main_avg_ms: Double
        var main_max_ms: Double
        /// The main thread's own CPU time per frame: the same stretches as
        /// main_avg_ms / main_max_ms, less any time the thread waited for a
        /// core, which a loaded Mac adds to the wall clock and a phone doesn't.
        var main_cpu_avg_ms: Double = 0
        var main_cpu_max_ms: Double = 0
        var t: Double
        /// When it began, seconds since 1970 (the simulator's clock is the Mac's).
        var begin: Double = 0
        /// The interval's signpost name: the motion's own, or "fade" under Reduce Motion.
        var signpost: String = ""
        /// The Motion's duration, what the interval should last (0: not said).
        var expected_ms: Double = 0
        /// Rounded legacy aliases for the first eligible callback and its
        /// main-thread work. Neither records touch or visible-frame latency.
        var first_ms: Double = 0
        var first_main_ms: Double = 0
        /// Played as Reduce Motion's short cross-fade instead of the morph.
        var fade: Bool = false
        /// Optional additions let schema 1 recordings decode unchanged.
        var schema_version: Int? = 2
        var data_kind: String? = "display_link_callbacks"
        var nominal_callback_hz: Double?
        var observed_callback_hz: Double?
        var callback_intervals_ms: [Double?]?
        var expected_callback_intervals_ms: [Double?]?
        var main_wall_samples_ms: [Double?]?
        var main_cpu_samples_ms: [Double?]?
        var first_callback_ms: Double?
        var first_callback_main_wall_ms: Double?
        var callback_sample_count: Int?
        var invalid_sample_count: Int?
        var measurement_complete: Bool?
        /// Native Settings completion is distinct from the SwiftUI path's
        /// logical completion and does not claim a presented frame.
        var interval_id: String?
        var completion_source: String?
        var completion_observed: Bool?
        var expected_duration_source: String?

        enum CodingKeys: String, CodingKey {
            case name, duration_ms, frames, fps, worst_ms, long, long_share, hitch_ms_per_s
            case main_avg_ms, main_max_ms, main_cpu_avg_ms, main_cpu_max_ms, t, begin
            case signpost, expected_ms, first_ms, first_main_ms, fade
            case schema_version, data_kind, nominal_callback_hz, observed_callback_hz
            case callback_intervals_ms, expected_callback_intervals_ms
            case main_wall_samples_ms, main_cpu_samples_ms
            case first_callback_ms, first_callback_main_wall_ms
            case callback_sample_count, invalid_sample_count, measurement_complete
            case interval_id, completion_source, completion_observed, expected_duration_source
        }

        mutating func recordFirstCallback(after seconds: Double, mainWall: Double) {
            guard seconds.isFinite, seconds >= 0, (seconds * 10_000).isFinite,
                  mainWall.isFinite, mainWall >= 0, (mainWall * 10_000).isFinite else { return }
            first_callback_ms = seconds * 1000
            first_callback_main_wall_ms = mainWall * 1000
            first_ms = (seconds * 10_000).rounded() / 10
            first_main_ms = (mainWall * 10_000).rounded() / 10
        }
    }

    private var open: [Interval] = []
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var observers: [CFRunLoopObserver] = []
    private var awake: CFTimeInterval = 0
    private var busySinceTick: CFTimeInterval = 0
    private var awakeCPU: UInt64 = 0
    private var cpuSinceTick: Double = 0
    private let out: URL?
    /// Films: YAB_FILM_MARK names the file the film script writes once its
    /// camera runs; the first motion to begin after it puts a blue mark in
    /// the corner in its first frame, so the recording knows that frame.
    private let filmMark: String?
    private let launched = CACurrentMediaTime()
    private let log = Logger(subsystem: "dev.serafim.fast.iphone", category: "frames")
    /// Every result since launch, for unit tests and the log.
    private(set) var results: [Result] = []

    init(environment: [String: String]) {
        filmMark = environment["YAB_FILM_MARK"].flatMap { $0.isEmpty ? nil : $0 }
        if let path = environment["YAB_PERF_OUT"], !path.isEmpty {
            let file = URL(fileURLWithPath: path)
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            out = file
        } else {
            out = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("yab-frames.jsonl")
        }
    }

    // MARK: - intervals

    /// A motion began: `name` is the Motion's, `signpost` its interval's
    /// ("fade" under Reduce Motion), `expected` its own duration in seconds.
    func begin(_ name: String, signpost: String? = nil, expected: Double = 0) {
        #if DEBUG
        // Settings armed this interval immediately before the unchanged
        // Motion.run. Its logical completion must not end UIKit's movement.
        if let interval = open.first(where: { $0.name == name && $0.nativeID != nil && !$0.logicalBeginObserved }) {
            interval.logicalBeginObserved = true
            return
        }
        #endif
        open.append(Interval(name: name, signpost: signpost ?? name, expected: expected, start: CACurrentMediaTime()))
        start()
        if let filmMark, FileManager.default.fileExists(atPath: filmMark) { FilmMark.show() }
    }

    func end(_ name: String) {
        guard let i = open.firstIndex(where: { $0.name == name }) else { return }
        #if DEBUG
        guard open[i].nativeID == nil else { return }
        #endif
        finish(at: i)
    }

    #if DEBUG
    func beginNative(_ name: String, id: UUID, signpost: String, expected: Double) {
        let interval = Interval(name: name, signpost: signpost, expected: expected, start: CACurrentMediaTime())
        interval.nativeID = id
        open.append(interval)
        start()
        if let filmMark, FileManager.default.fileExists(atPath: filmMark) { FilmMark.show() }
    }

    func endNative(_ id: UUID, completed: Bool, source: String) {
        guard let i = open.firstIndex(where: { $0.nativeID == id }) else { return }
        finish(at: i, nativeID: id, completed: completed, source: source)
    }
    #endif

    private func finish(at i: Int, nativeID: UUID? = nil, completed: Bool? = nil, source: String? = nil) {
        let interval = open.remove(at: i)
        var result = Self.summary(name: interval.name, start: interval.start, end: CACurrentMediaTime(),
                                  frames: interval.frames, expected: interval.expected, busy: interval.busy,
                                  cpu: interval.cpu, since: launched)
        func ms(_ s: Double) -> Double { (s * 10_000).rounded() / 10 }
        result.begin = (interval.began * 1000).rounded() / 1000
        result.signpost = interval.signpost
        result.expected_ms = ms(interval.expectedDuration)
        result.fade = interval.signpost == "fade"
        if let first = interval.firstFrame {
            result.recordFirstCallback(after: first, mainWall: interval.firstBusy)
        }
        if let nativeID {
            result.interval_id = nativeID.uuidString
            result.completion_source = source
            result.completion_observed = completed
            result.expected_duration_source = "Motion.definition"
            result.measurement_complete = result.measurement_complete == true && completed == true
        }
        results.append(result)
        write(result)
        if open.isEmpty { stop() }
    }

    /// The numbers of one interval, from its frames. Static so unit tests
    /// can feed it frames of their own.
    nonisolated static func summary(name: String, start: CFTimeInterval, end: CFTimeInterval,
                                    frames: [Double], expected: [Double], busy: [Double],
                                    cpu: [Double] = [], since launched: CFTimeInterval = 0) -> Result {
        func positive(_ value: Double) -> Bool { value.isFinite && value > 0 && (value * 10_000).isFinite && (1 / value).isFinite }
        func nonnegative(_ value: Double) -> Bool { value.isFinite && value >= 0 && (value * 10_000).isFinite }
        let validFrames = frames.filter(positive)
        let validExpected = expected.filter(positive)
        let validBusy = busy.filter(nonnegative), validCPU = cpu.filter(nonnegative)
        let elapsed = end - start
        let duration = elapsed.isFinite && (elapsed * 10_000).isFinite ? max(0, elapsed) : 0
        // Keep the valid historical arithmetic and rounded aliases unchanged.
        let nominal = validExpected.isEmpty ? 1.0 / 60 : validExpected.sorted()[validExpected.count / 2]
        var long = 0
        var hitch = 0.0
        for (k, frame) in frames.enumerated() where positive(frame) {
            let own = k < expected.count && positive(expected[k]) ? expected[k] : nominal
            if frame > own * 1.5 { long += 1 }
            hitch += max(0, frame - own)
        }
        func ms(_ seconds: Double) -> Double { (seconds * 10_000).rounded() / 10 }
        var result = Result(
            name: name,
            duration_ms: ms(duration),
            frames: frames.count,
            fps: nominal > 0 ? (1 / nominal).rounded() : 0,
            worst_ms: ms(validFrames.max() ?? 0),
            long: long,
            long_share: frames.isEmpty ? 0 : (Double(long) / Double(frames.count) * 1000).rounded() / 1000,
            hitch_ms_per_s: duration > 0 ? ((hitch * 1000) / duration * 10).rounded() / 10 : 0,
            main_avg_ms: validBusy.isEmpty ? 0 : ms(validBusy.reduce(0, +) / Double(validBusy.count)),
            main_max_ms: ms(validBusy.max() ?? 0),
            main_cpu_avg_ms: validCPU.isEmpty ? 0 : ms(validCPU.reduce(0, +) / Double(validCPU.count)),
            main_cpu_max_ms: ms(validCPU.max() ?? 0),
            t: ((end - launched) * 1000).isFinite ? ((end - launched) * 1000).rounded() / 1000 : 0
        )
        let invalidPairs = (0..<max(frames.count, expected.count)).filter { index in
            index >= frames.count || index >= expected.count
                || !positive(frames[index]) || !positive(expected[index])
        }.count
        let invalid = invalidPairs + busy.filter { !nonnegative($0) }.count
            + cpu.filter { !nonnegative($0) }.count
            + (start.isFinite && end.isFinite && duration > 0 ? 0 : 1)
        let complete = !frames.isEmpty && invalid == 0
        result.callback_sample_count = frames.count
        result.invalid_sample_count = invalid
        result.measurement_complete = complete
        func rawMS(_ values: [Double]) -> [Double?] {
            values.map { ($0 * 1000).isFinite ? $0 * 1000 : nil }
        }
        result.callback_intervals_ms = rawMS(frames)
        result.expected_callback_intervals_ms = rawMS(expected)
        result.main_wall_samples_ms = rawMS(busy)
        result.main_cpu_samples_ms = rawMS(cpu)
        if complete {
            result.nominal_callback_hz = 1 / nominal
            result.observed_callback_hz = Double(frames.count) / frames.reduce(0, +)
        }
        return result
    }

    // MARK: - the display link and the run loop

    private func start() {
        guard link == nil else { return }
        lastTick = 0
        busySinceTick = 0
        cpuSinceTick = 0
        awake = CACurrentMediaTime()
        awakeCPU = Self.threadCPU()
        let link = CADisplayLink(target: Ticker(self), selector: #selector(Ticker.tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        // Waking: first of every observer, so the whole pass counts.
        let woke: CFRunLoopObserver? = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.awake = CACurrentMediaTime()
                self.awakeCPU = Self.threadCPU()
            }
        }
        // Going to sleep: last of every observer, after Core Animation's
        // commit (order 2,000,000), so the frame's layout and commit count.
        let sleeps: CFRunLoopObserver? = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = CACurrentMediaTime(), cpu = Self.threadCPU()
                self.busySinceTick += now - self.awake
                self.cpuSinceTick += Double(cpu &- self.awakeCPU) / 1e9
                self.awake = now
                self.awakeCPU = cpu
            }
        }
        for observer in [woke, sleeps].compactMap({ $0 }) {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            observers.append(observer)
        }
    }

    private func stop() {
        link?.invalidate()
        link = nil
        for observer in observers {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            CFRunLoopObserverInvalidate(observer)
        }
        observers = []
    }

    fileprivate func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime(), cpuNow = Self.threadCPU()
        // The busy stretch this tick runs in counts up to now.
        busySinceTick += now - awake
        cpuSinceTick += Double(cpuNow &- awakeCPU) / 1e9
        awake = now
        awakeCPU = cpuNow
        defer { lastTick = link.timestamp; busySinceTick = 0; cpuSinceTick = 0 }
        // First eligible callback after Motion.begin. CADisplayLink does not
        // expose a presentation receipt or the preceding physical touch.
        // A callback whose timestamp precedes the motion cannot count.
        for interval in open where interval.firstFrame == nil && link.timestamp >= interval.start {
            interval.firstFrame = now - interval.start
            interval.firstBusy = busySinceTick
        }
        guard lastTick > 0 else {
            // The meter's first tick has no frame before it to measure from,
            // but the main thread's work for it counts.
            for interval in open { interval.busy.append(busySinceTick); interval.cpu.append(cpuSinceTick) }
            return
        }
        let frame = link.timestamp - lastTick
        let expected = link.targetTimestamp - link.timestamp
        for interval in open {
            interval.frames.append(frame)
            interval.expected.append(expected > 0 ? expected : link.duration)
            interval.busy.append(busySinceTick)
            interval.cpu.append(cpuSinceTick)
        }
    }

    /// The calling thread's CPU time so far, in nanoseconds (the observers
    /// and the tick run on the main thread, so it is the main thread's).
    nonisolated private static func threadCPU() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    }

    private func write(_ result: Result) {
        log.info("frames \(result.name, privacy: .public): \(result.frames) frames, worst \(result.worst_ms) ms, main \(result.main_avg_ms) ms")
        guard let out, let data = try? JSONEncoder().encode(result) else { return }
        let line = data + Data("\n".utf8)
        if let handle = try? FileHandle(forWritingTo: out) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: out)
        }
    }

    /// The film's sync mark: 4 × 4 pt of pure blue in the screen's top left
    /// corner, over everything, from the first motion on. Phone/scripts/phone
    /// film finds the first frame of the recording with it.
    @MainActor
    enum FilmMark {
        private static weak var view: UIView?

        static func show() {
            guard view == nil,
                  let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                    .flatMap(\.windows).first(where: \.isKeyWindow) else { return }
            let mark = UIView(frame: CGRect(x: 0, y: 0, width: 4, height: 4))
            mark.backgroundColor = UIColor(red: 0, green: 0, blue: 1, alpha: 1)
            mark.isUserInteractionEnabled = false
            mark.accessibilityElementsHidden = true
            mark.layer.zPosition = 10_000
            window.addSubview(mark)
            view = mark
        }
    }

    /// The display link holds its target strongly; this keeps the meter free.
    private final class Ticker: NSObject {
        weak var meter: FrameMeter?
        init(_ meter: FrameMeter) { self.meter = meter }
        @MainActor @objc func tick(_ link: CADisplayLink) { meter?.tick(link) }
    }
}

/// Decode schema 1 lines without inventing schema 2 samples.
extension FrameMeter.Result {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        duration_ms = try values.decode(Double.self, forKey: .duration_ms)
        frames = try values.decode(Int.self, forKey: .frames)
        fps = try values.decode(Double.self, forKey: .fps)
        worst_ms = try values.decode(Double.self, forKey: .worst_ms)
        long = try values.decode(Int.self, forKey: .long)
        long_share = try values.decode(Double.self, forKey: .long_share)
        hitch_ms_per_s = try values.decode(Double.self, forKey: .hitch_ms_per_s)
        main_avg_ms = try values.decode(Double.self, forKey: .main_avg_ms)
        main_max_ms = try values.decode(Double.self, forKey: .main_max_ms)
        t = try values.decode(Double.self, forKey: .t)
        main_cpu_avg_ms = try values.decodeIfPresent(Double.self, forKey: .main_cpu_avg_ms) ?? 0
        main_cpu_max_ms = try values.decodeIfPresent(Double.self, forKey: .main_cpu_max_ms) ?? 0
        begin = try values.decodeIfPresent(Double.self, forKey: .begin) ?? 0
        signpost = try values.decodeIfPresent(String.self, forKey: .signpost) ?? ""
        expected_ms = try values.decodeIfPresent(Double.self, forKey: .expected_ms) ?? 0
        first_ms = try values.decodeIfPresent(Double.self, forKey: .first_ms) ?? 0
        first_main_ms = try values.decodeIfPresent(Double.self, forKey: .first_main_ms) ?? 0
        fade = try values.decodeIfPresent(Bool.self, forKey: .fade) ?? false
        schema_version = try values.decodeIfPresent(Int.self, forKey: .schema_version)
        data_kind = try values.decodeIfPresent(String.self, forKey: .data_kind)
        nominal_callback_hz = try values.decodeIfPresent(Double.self, forKey: .nominal_callback_hz)
        observed_callback_hz = try values.decodeIfPresent(Double.self, forKey: .observed_callback_hz)
        callback_intervals_ms = try values.decodeIfPresent([Double?].self, forKey: .callback_intervals_ms)
        expected_callback_intervals_ms = try values.decodeIfPresent([Double?].self, forKey: .expected_callback_intervals_ms)
        main_wall_samples_ms = try values.decodeIfPresent([Double?].self, forKey: .main_wall_samples_ms)
        main_cpu_samples_ms = try values.decodeIfPresent([Double?].self, forKey: .main_cpu_samples_ms)
        first_callback_ms = try values.decodeIfPresent(Double.self, forKey: .first_callback_ms)
        first_callback_main_wall_ms = try values.decodeIfPresent(Double.self, forKey: .first_callback_main_wall_ms)
        callback_sample_count = try values.decodeIfPresent(Int.self, forKey: .callback_sample_count)
        invalid_sample_count = try values.decodeIfPresent(Int.self, forKey: .invalid_sample_count)
        measurement_complete = try values.decodeIfPresent(Bool.self, forKey: .measurement_complete)
        interval_id = try values.decodeIfPresent(String.self, forKey: .interval_id)
        completion_source = try values.decodeIfPresent(String.self, forKey: .completion_source)
        completion_observed = try values.decodeIfPresent(Bool.self, forKey: .completion_observed)
        expected_duration_source = try values.decodeIfPresent(String.self, forKey: .expected_duration_source)
    }
}
