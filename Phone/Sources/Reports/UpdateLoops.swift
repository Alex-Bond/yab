import Foundation
import UIKit

// The watchdog's kills (crashes 43 to 88) leave one sample of a main thread
// busy for 5 to 10 s inside one SwiftUI update of the window: PageHost and
// PageViewport.apply, or the + menu. One sample can't tell an update that
// keeps asking for itself from one slow call. This counts, in every build
// that sends reports, how often those places run in one busy stretch of the
// main run loop (from its waking to its next sleep), and when a stretch has
// run one of them `threshold` times and been busy `busySeconds`, writes it
// down at once, before the watchdog can end the app, then again each time
// that count doubles, and once more if the stretch ends after all. Nothing
// shows. The newest few go with the next report you agreed to send, as its
// stall log (`stalls`, CrashReports), then are forgotten.
//
// Inputs are read only from the iteration before the loop threshold. The
// first few changes in a bounded sample are kept beside the counts, without
// page text or URLs. The journal is written on its own queue.

@MainActor
final class UpdateLoops {
    enum Place: Int, CaseIterable {
        case viewport, pageHost, plusMenu, chromeHost, root

        var name: String {
            switch self {
            case .viewport: "viewport"
            case .pageHost: "pageHost"
            case .plusMenu: "plusMenu"
            case .chromeHost: "chromeHost"
            case .root: "root"
            }
        }
    }

    /// Only numeric inputs cross this boundary. Flags are 0 or 1; an
    /// unspecified vertical-controls preference is -1.
    struct Fingerprint {
        var fields: [String: Double] = [:]

        mutating func size(_ name: String, _ size: CGSize) {
            fields[name + ".width"] = Double(size.width)
            fields[name + ".height"] = Double(size.height)
        }

        mutating func rect(_ name: String, _ rect: CGRect) {
            fields[name + ".x"] = Double(rect.origin.x)
            fields[name + ".y"] = Double(rect.origin.y)
            size(name, rect.size)
        }

        mutating func insets(_ name: String, _ insets: UIEdgeInsets) {
            fields[name + ".top"] = Double(insets.top)
            fields[name + ".left"] = Double(insets.left)
            fields[name + ".bottom"] = Double(insets.bottom)
            fields[name + ".right"] = Double(insets.right)
        }

        mutating func chrome(_ chrome: PageViewport.Chrome) {
            fields["chrome.folded"] = chrome.folded ? 1 : 0
            fields["chrome.hasNow"] = chrome.hasNow ? 1 : 0
            fields["chrome.visible"] = chrome.visible ? 1 : 0
            fields["chrome.verticalControls"] = chrome.verticalControls.map { $0 ? 1 : 0 } ?? -1
            fields["chrome.leadingRail"] = chrome.leadingRail ? 1 : 0
        }

        var journal: [String: Any] { fields.mapValues(Self.value) }

        /// Old and new values, in that order. Nonfinite geometry must not
        /// make JSONSerialization drop the entire stall entry.
        func diff(from previous: Self) -> [String: [Any]] {
            if fields == previous.fields { return [:] }
            var changed: [String: [Any]] = [:]
            for key in Set(fields.keys).union(previous.fields.keys).sorted() {
                let old = previous.fields[key], new = fields[key]
                if old == new || (old?.isNaN == true && new?.isNaN == true) { continue }
                changed[key] = [old.map(Self.value) ?? "absent", new.map(Self.value) ?? "absent"]
            }
            return changed
        }

        private static func value(_ number: Double) -> Any {
            if number.isFinite { return number }
            if number.isNaN { return "nan" }
            return number > 0 ? "infinity" : "negativeInfinity"
        }
    }

    private struct Inputs {
        let first: Fingerprint
        let firstCount: Int
        var previous: Fingerprint
        var previousCount: Int
        var changes: [[String: Any]] = []

        var journal: [String: Any] {
            ["firstCount": firstCount, "first": first.journal,
             "sampledThrough": previousCount, "changes": changes]
        }
    }

    /// Set at launch for a build that has a site (Reports.start).
    static var shared: UpdateLoops?
    /// Runs of one place in one stretch before it is looked at: far past
    /// the few dozen a frame with 40 tabs takes.
    static let threshold = 1024
    static let busySeconds: CFTimeInterval = 1
    /// Stretches kept, newest last.
    static let kept = 5
    static let keptChanges = 4
    static let keptSamples = 8
    nonisolated private static let queue = DispatchQueue(label: "yab.update-loops", qos: .utility)

    @inline(__always)
    static func count(_ place: Place, inputs: () -> Fingerprint = { Fingerprint() }) {
        shared?.add(place, inputs: inputs)
    }

    let file: URL
    private let clock: () -> CFTimeInterval
    private let state: @MainActor () -> String
    private var counts = [Int](repeating: 0, count: Place.allCases.count)
    private var inputs = [Inputs?](repeating: nil, count: Place.allCases.count)
    private var samples = [Int](repeating: 0, count: Place.allCases.count)
    private var began: CFTimeInterval
    private var next = threshold
    /// This stretch, once written down.
    private var noted: [String: Any]?
    private var observers: [CFRunLoopObserver] = []

    init(file: URL, clock: @escaping () -> CFTimeInterval = CFAbsoluteTimeGetCurrent,
         state: @escaping @MainActor () -> String = UpdateLoops.applicationState) {
        self.file = file
        self.clock = clock
        self.state = state
        began = clock()
    }

    /// The main run loop's waking and sleeping bound each stretch.
    func start() {
        guard observers.isEmpty else { return }
        let main = CFRunLoopGetMain()
        let waking = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, Int.min) { _, _ in
            MainActor.assumeIsolated { UpdateLoops.shared?.woke() }
        }
        let sleeping = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, Int.max) { _, _ in
            MainActor.assumeIsolated { UpdateLoops.shared?.sleeps() }
        }
        for observer in [waking, sleeping].compactMap({ $0 }) {
            CFRunLoopAddObserver(main, observer, .commonModes)
            observers.append(observer)
        }
        woke()
    }

    @inline(__always)
    func add(_ place: Place, inputs: () -> Fingerprint = { Fingerprint() }) {
        counts[place.rawValue] &+= 1
        let finished = sample(place, inputs: inputs)
        if counts[place.rawValue] >= next {
            next = (counts.max() ?? next) * 2
            look()
        } else if finished {
            // One input snapshot per place, without waiting for the next
            // doubling or for a run loop the watchdog may never let sleep.
            look()
        }
    }

    private func sample(_ place: Place, inputs make: () -> Fingerprint) -> Bool {
        let index = place.rawValue, count = counts[index]
        guard count >= Self.threshold - 1,
              samples[index] < Self.keptSamples,
              (inputs[index]?.changes.count ?? 0) < Self.keptChanges else { return false }
        samples[index] += 1
        let finished = samples[index] == Self.keptSamples
        let fingerprint = make()
        guard !fingerprint.fields.isEmpty else { return finished }
        guard var seen = inputs[index] else {
            inputs[index] = Inputs(first: fingerprint, firstCount: count, previous: fingerprint, previousCount: count)
            return finished
        }
        let diff = fingerprint.diff(from: seen.previous)
        if !diff.isEmpty {
            seen.changes.append(["count": count, "previousCount": seen.previousCount, "fields": diff])
        }
        seen.previous = fingerprint
        seen.previousCount = count
        inputs[index] = seen
        return finished || seen.changes.count == Self.keptChanges
    }

    func woke() {
        began = clock()
        for index in counts.indices { counts[index] = 0 }
        for index in inputs.indices { inputs[index] = nil }
        for index in samples.indices { samples[index] = 0 }
        next = Self.threshold
        noted = nil
    }

    /// A stretch written down that ended after all: how long it took.
    func sleeps() {
        if var noted {
            noted["endedMs"] = milliseconds(clock() - began)
            noted["counts"] = named()
            noted["inputs"] = sampled()
            write(noted, replacing: true)
        }
        woke()
    }

    private func look() {
        let busy = clock() - began
        guard busy >= Self.busySeconds else { return }
        let again = noted != nil
        var line = noted ?? [
            "at": ISO8601DateFormatter().string(from: Date()),
            "state": state(),
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
        ]
        line["busyMs"] = milliseconds(busy)
        line["counts"] = named()
        line["inputs"] = sampled()
        noted = line
        write(line, replacing: again)
    }

    private func named() -> [String: Int] {
        Dictionary(uniqueKeysWithValues: Place.allCases.compactMap { counts[$0.rawValue] > 0 ? ($0.name, counts[$0.rawValue]) : nil })
    }

    private func sampled() -> [String: Any] {
        Dictionary(uniqueKeysWithValues: Place.allCases.compactMap { place -> (String, Any)? in
            guard counts[place.rawValue] >= Self.threshold, let seen = inputs[place.rawValue] else { return nil }
            return (place.name, seen.journal)
        })
    }

    private func milliseconds(_ seconds: CFTimeInterval) -> Int { Int((seconds * 1000).rounded()) }

    /// A stretch written down before is the file's last line, replaced.
    private func write(_ line: [String: Any], replacing: Bool) {
        let file = file, kept = Self.kept
        Self.queue.async {
            var all = Self.read(in: file)
            if replacing, !all.isEmpty { all.removeLast() }
            all = Array((all + [line]).suffix(kept))
            guard let data = try? JSONSerialization.data(withJSONObject: all, options: [.sortedKeys]) else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }

    nonisolated static func lines(in file: URL) -> [[String: Any]] {
        queue.sync { read(in: file) }
    }

    nonisolated private static func read(in file: URL) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: file),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list
    }

    /// As the site keeps a stall log: a line of JSON each, prefixed so it
    /// reads apart from the Mac's.
    nonisolated static func stalls(in file: URL) -> String? {
        let lines = lines(in: file).compactMap { line -> String? in
            guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return nil }
            return "update loop " + String(decoding: data, as: UTF8.self)
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    nonisolated static func forget(in file: URL) {
        queue.sync { try? FileManager.default.removeItem(at: file) }
    }

    static func applicationState() -> String {
        switch UIApplication.shared.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }
}
