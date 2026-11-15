import Foundation
import MetricKit

// How Yab for iPhone ended, as iOS counts it once a day (MetricKit's
// MXAppExitMetric): normal exits, the watchdog's kills, memory, crashes, in
// front and in the back, with the day's hang-time histogram beside. A crash
// report shows one kill; these say how often. The newest week stays here
// and goes only with a report you agreed to send (CrashReports), then is
// forgotten. Counts only: no times of day, no pages.

enum ExitCounts {
    /// Days kept, newest last.
    static let kept = 7

    /// One day's counts as kept and sent. MetricKit's times are its own
    /// words ("2026-10-22 00:00:00 +0000").
    static func day(begin: String, end: String, version: String?, build: String?,
                    foreground: [String: Int], background: [String: Int], hangTime: [[String: Int]]) -> [String: Any] {
        var day: [String: Any] = [
            "begin": begin, "end": end,
            "exits": ["foregroundExitData": foreground, "backgroundExitData": background],
        ]
        if let version { day["version"] = version }
        if let build { day["build"] = build }
        if !hangTime.isEmpty { day["hangTime"] = hangTime }
        return day
    }

    /// The day in one of MetricKit's daily payloads, or nil when it counted
    /// no exits.
    static func day(_ payload: MXMetricPayload) -> [String: Any]? {
        guard let exits = payload.applicationExitMetrics else { return nil }
        let front = exits.foregroundExitData, back = exits.backgroundExitData
        let foreground = [
            "normal": front.cumulativeNormalAppExitCount, "watchdog": front.cumulativeAppWatchdogExitCount,
            "memoryLimit": front.cumulativeMemoryResourceLimitExitCount, "badAccess": front.cumulativeBadAccessExitCount,
            "illegalInstruction": front.cumulativeIllegalInstructionExitCount, "abnormal": front.cumulativeAbnormalExitCount,
        ]
        let background = [
            "normal": back.cumulativeNormalAppExitCount, "watchdog": back.cumulativeAppWatchdogExitCount,
            "memoryLimit": back.cumulativeMemoryResourceLimitExitCount, "memoryPressure": back.cumulativeMemoryPressureExitCount,
            "badAccess": back.cumulativeBadAccessExitCount, "illegalInstruction": back.cumulativeIllegalInstructionExitCount,
            "abnormal": back.cumulativeAbnormalExitCount, "cpuLimit": back.cumulativeCPUResourceLimitExitCount,
            "lockedFile": back.cumulativeSuspendedWithLockedFileExitCount,
            "taskTimeout": back.cumulativeBackgroundTaskAssertionTimeoutExitCount,
        ]
        var hangTime: [[String: Int]] = []
        if let histogram = payload.applicationResponsivenessMetrics?.histogrammedApplicationHangTime {
            for case let bucket as MXHistogramBucket<UnitDuration> in histogram.bucketEnumerator {
                hangTime.append([
                    "from": Int(bucket.bucketStart.converted(to: .milliseconds).value.rounded()),
                    "to": Int(bucket.bucketEnd.converted(to: .milliseconds).value.rounded()),
                    "count": bucket.bucketCount,
                ])
            }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return day(begin: formatter.string(from: payload.timeStampBegin), end: formatter.string(from: payload.timeStampEnd),
                   version: payload.latestApplicationVersion,
                   build: payload.metaData?.applicationBuildVersion,
                   foreground: foreground, background: background, hangTime: hangTime)
    }

    static func days(in file: URL) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: file),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list
    }

    /// The new days kept with those before, a day iOS hands over twice once.
    static func keep(_ new: [[String: Any]], in file: URL) {
        guard !new.isEmpty else { return }
        var seen = Set<String>()
        let all = (days(in: file) + new).reversed().filter { day in
            seen.insert("\(day["begin"] ?? "")|\(day["end"] ?? "")").inserted
        }.reversed().suffix(kept)
        guard let data = try? JSONSerialization.data(withJSONObject: Array(all)) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    static func forget(in file: URL) {
        try? FileManager.default.removeItem(at: file)
    }
}
