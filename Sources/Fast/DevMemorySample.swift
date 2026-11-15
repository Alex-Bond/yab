import Foundation

struct DevMemorySample {
    var time: Double
    var bytes: Int
    init?(_ raw: [String: Any]) {
        guard let time = raw["timestamp"] as? Double else { return nil }
        self.time = time
        bytes = (raw["categories"] as? [[String: Any]] ?? []).reduce(0) { $0 + ($1["size"] as? Int ?? 0) }
    }
}
