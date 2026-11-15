import Foundation

/// Keep completed blocks warm without retaining hundreds of large stream
/// prefixes. Cost estimates text storage and attributed-run overhead; it is
/// not a measurement of the process's physical footprint. Callers own isolation.
struct RichTextCache {
    private struct Entry {
        var value: AttributedString
        var used: UInt64
        var cost: Int
    }

    let costLimit: Int
    let countLimit: Int
    private var entries: [String: Entry] = [:]
    private var clock: UInt64 = 0
    private(set) var estimatedCost = 0
    var count: Int { entries.count }

    init(costLimit: Int = 8 * 1024 * 1024, countLimit: Int = 4096) {
        self.costLimit = max(0, costLimit)
        self.countLimit = max(0, countLimit)
    }

    mutating func value(_ words: String, make: () -> AttributedString) -> AttributedString {
        clock &+= 1
        if let entry = entries[words] {
            entries[words]?.used = clock
            return entry.value
        }
        let made = make()
        let cost = words.utf8.count * 4 + made.runs.count * 128 + 256
        // An oversized answer still renders correctly, without displacing
        // the small completed blocks that are already on screen.
        guard countLimit > 0, cost <= costLimit else { return made }
        while entries.count >= countLimit || estimatedCost > costLimit - cost {
            guard let oldest = entries.min(by: { $0.value.used < $1.value.used }) else { break }
            entries.removeValue(forKey: oldest.key)
            estimatedCost -= oldest.value.cost
        }
        entries[words] = Entry(value: made, used: clock, cost: cost)
        estimatedCost += cost
        return made
    }
}
