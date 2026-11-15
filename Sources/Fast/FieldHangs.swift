import Foundation
import MetricKit

// How long Yab stops answering on people's Macs, from macOS's own count
// (MetricKit): about once a day the system hands over a histogram of hang
// times for the day before. When crash reports are sent automatically
// (Settings › About), its buckets go to the site: how many hangs of what
// length, with the build and macOS and nothing else. No id; only this
// version's; only a day that ended in the last 24 hours; never twice. A
// day that came while sending was off is passed over for good.
//
// What the main thread was doing in a hang (MetricKit's hang diagnostics, a
// call stack of frames and image ids) stays here, the newest few, and goes
// only inside a crash report you agreed to send (Crashes).
//
// The rules are DuckDuckGo's HangMetrics'; the code is Yab's own. Watchdog
// is the other half: stalls of a second or more, seen from inside.

enum FieldHangs {
    /// One bar of the histogram, in milliseconds.
    struct Bucket: Equatable {
        var from: Int
        var to: Int
        var count: Int
    }

    /// One payload, as much of it as is used.
    struct Day: Equatable {
        var version: String
        var build: String?
        /// The day saw more than one version of Yab.
        var mixed: Bool
        var end: Date
        var buckets: [Bucket]
    }

    /// The end of the newest day looked at, sent or not.
    static let sentKey = "hangs.sent"
    /// Only a day that ended this recently goes.
    static let window: TimeInterval = 24 * 60 * 60

    /// What goes from these days: their buckets summed by their bounds,
    /// those with no hangs left out, smallest first.
    static func toSend(_ days: [Day], version: String, build: Int, now: Date, after sent: Date?) -> [Bucket] {
        var summed: [String: Bucket] = [:]
        for day in days {
            if let sent, day.end <= sent { continue }
            guard !day.mixed, day.version == version, day.build.map({ $0 == String(build) }) ?? true,
                  day.end >= now.addingTimeInterval(-window), day.end <= now.addingTimeInterval(60 * 60)
            else { continue }
            for bucket in day.buckets where bucket.count > 0 {
                let key = "\(bucket.from)-\(bucket.to)"
                summed[key, default: Bucket(from: bucket.from, to: bucket.to, count: 0)].count += bucket.count
            }
        }
        return summed.values.sorted { ($0.from, $0.to) < ($1.from, $1.to) }
    }

    static func newest(_ days: [Day]) -> Date? { days.map(\.end).max() }

    /// A bar as MetricKit gives it, in whatever unit, to whole milliseconds.
    static func bucket(from start: Measurement<UnitDuration>, to end: Measurement<UnitDuration>, count: Int) -> Bucket {
        Bucket(from: Int(start.converted(to: .milliseconds).value.rounded()),
               to: Int(end.converted(to: .milliseconds).value.rounded()), count: count)
    }

    /// What the site is sent, all of it.
    static func body(_ buckets: [Bucket], version: String, build: Int, system: String) -> [String: Any] {
        ["version": version, "build": build, "os": system,
         "buckets": buckets.map { ["from": $0.from, "to": $0.to, "count": $0.count] }]
    }

    /// The days macOS handed over: looked at once, sent when crash reports
    /// are sent automatically.
    static func handle(_ days: [Day], defaults: UserDefaults, now: Date = Date(), sends: Bool,
                       post: ([String: Any]) -> Void) {
        let sent = defaults.object(forKey: sentKey) as? Date
        let buckets = toSend(days, version: Updater.version, build: Updater.build, now: now, after: sent)
        if let newest = newest(days) { defaults.set(max(newest, sent ?? .distantPast), forKey: sentKey) }
        guard sends, !buckets.isEmpty else { return }
        post(body(buckets, version: Updater.version, build: Updater.build, system: Updater.system))
    }

    // MARK: stacks

    /// Where the stacks wait for a crash report.
    static var stackFile: URL { Store.file("hang-stacks.json") }
    /// How many are kept, newest last.
    static let stacksKept = 5

    /// Only what reads a stack: frames, the images they are in by name and
    /// id, and offsets. Anything else MetricKit adds stays here.
    static let stackKeys: Set<String> = [
        "callStackTree", "callStacks", "callStackPerThread", "threadAttributed", "callStackRootFrames", "subFrames",
        "binaryUUID", "binaryName", "offsetIntoBinaryTextSegment", "address", "sampleCount",
    ]

    static func stackOnly(_ value: Any) -> Any? {
        switch value {
        case let object as [String: Any]:
            return object.reduce(into: [String: Any]()) { kept, pair in
                guard stackKeys.contains(pair.key), let inner = stackOnly(pair.value) else { return }
                kept[pair.key] = inner
            }
        case let list as [Any]: return list.compactMap(stackOnly)
        case is String, is NSNumber: return value
        default: return nil
        }
    }

    /// A hang's stack as kept: how long, which build, the frames.
    static func stack(milliseconds: Int, build: String?, tree: Data) -> [String: Any]? {
        guard let json = try? JSONSerialization.jsonObject(with: tree), let frames = stackOnly(json) else { return nil }
        var kept: [String: Any] = ["ms": milliseconds, "stack": frames]
        if let build { kept["build"] = build }
        return kept
    }

    static func stacks(in file: URL = stackFile) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: file),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list
    }

    /// At most this much of them, so a crash report never grows past what
    /// the site takes for one.
    static let stacksBytes = 128 * 1024

    static func keep(_ new: [[String: Any]], in file: URL = stackFile) {
        guard !new.isEmpty else { return }
        var all = Array((stacks(in: file) + new).suffix(stacksKept))
        var data = (try? JSONSerialization.data(withJSONObject: all)) ?? Data()
        while data.count > stacksBytes, !all.isEmpty {
            all.removeFirst()
            data = (try? JSONSerialization.data(withJSONObject: all)) ?? Data()
        }
        guard !all.isEmpty else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    static func forgetStacks(in file: URL = stackFile) {
        try? FileManager.default.removeItem(at: file)
    }

    // MARK: MetricKit

    /// At launch, for a build that has a site: listen, and look at what
    /// macOS kept from before.
    @MainActor
    static func start() {
        guard Updater.site != nil, !Store.testing || ProcessInfo.processInfo.environment["YAB_FEED"] != nil else { return }
        Watcher.shared.start()
    }

    private final class Watcher: NSObject, MXMetricManagerSubscriber {
        static let shared = Watcher()
        private let queue = DispatchQueue(label: "yab.field-hangs", qos: .utility)
        private var started = false
        private static let session: URLSession = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            return URLSession(configuration: configuration)
        }()

        func start() {
            guard !started else { return }
            started = true
            let manager = MXMetricManager.shared
            manager.add(self)
            queue.async { [self] in
                handle(manager.pastPayloads)
                handle(manager.pastDiagnosticPayloads)
            }
        }

        func didReceive(_ payloads: [MXMetricPayload]) { queue.async { [self] in handle(payloads) } }
        func didReceive(_ payloads: [MXDiagnosticPayload]) { queue.async { [self] in handle(payloads) } }

        private func handle(_ payloads: [MXMetricPayload]) {
            let days = payloads.compactMap { payload -> Day? in
                guard let hangs = payload.applicationResponsivenessMetrics?.histogrammedApplicationHangTime else { return nil }
                var buckets: [Bucket] = []
                let bars = hangs.bucketEnumerator
                while let bar = bars.nextObject() as? MXHistogramBucket<UnitDuration> {
                    buckets.append(FieldHangs.bucket(from: bar.bucketStart, to: bar.bucketEnd, count: bar.bucketCount))
                }
                return Day(version: payload.latestApplicationVersion, build: payload.metaData?.applicationBuildVersion,
                           mixed: payload.includesMultipleApplicationVersions, end: payload.timeStampEnd, buckets: buckets)
            }
            guard !days.isEmpty, let site = Updater.site else { return }
            FieldHangs.handle(days, defaults: Store.settings, sends: Crashes.sends) { body in
                var request = URLRequest(url: site.appendingPathComponent("api/hangs"))
                request.httpMethod = "POST"
                request.timeoutInterval = 15
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)
                Watcher.session.dataTask(with: request).resume()
            }
        }

        private func handle(_ payloads: [MXDiagnosticPayload]) {
            let stacks = payloads.flatMap { $0.hangDiagnostics ?? [] }.compactMap { hang in
                FieldHangs.stack(milliseconds: Int(hang.hangDuration.converted(to: .milliseconds).value.rounded()),
                                 build: hang.metaData.applicationBuildVersion,
                                 tree: hang.callStackTree.jsonRepresentation())
            }
            FieldHangs.keep(stacks)
        }
    }
}
