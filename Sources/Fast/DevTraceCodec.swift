import Foundation

/// Standard Chrome trace events, with original WebKit records kept as metadata.
/// Time units are microseconds in the exported file and seconds in WebKit.
enum DevTraceCodec {
    @MainActor static func export(_ model: DevWorkbench) -> String {
        let events: [[String: Any]] = model.trace.map { event in
            let args = DevWorkbench.parse(event.data) as? [String: Any] ?? [:]
            return ["name": event.name, "cat": "webkit", "ph": "X", "pid": 1, "tid": 1,
                    "ts": event.start * 1_000_000, "dur": event.duration * 1_000, "args": args]
        }
        return DevWorkbench.string(["traceEvents": events, "displayTimeUnit": "ms", "records": model.traceRaw, "memory": model.memorySamples.map { ["timestamp": $0.time, "categories": [["type": "total", "size": $0.bytes]]] as [String: Any] }])
    }
    static func records(_ document: [String: Any]) -> [[String: Any]]? {
        if let records = document["records"] as? [[String: Any]] { return records }
        guard let events = document["traceEvents"] as? [[String: Any]] else { return nil }
        return events.filter { $0["ph"] as? String == "X" }.map { event in
            let start = (event["ts"] as? Double ?? 0) / 1_000_000
            let duration = (event["dur"] as? Double ?? 0) / 1_000_000
            return ["type": event["name"] as? String ?? "Event", "startTime": start, "endTime": start + duration, "data": event["args"] ?? [:]]
        }
    }
}
