import CoreGraphics

/// Normalized points and fixed RGB do not depend on the view's size or trait.
/// Canvas still positions each dot in its current geometry on every draw.
final class LookFieldGrid: Sendable {
    struct Sample: Equatable, Sendable {
        let point: CGPoint
        let color: RGB
    }
    let samples: [Sample]

    fileprivate init(lightness: Double, columns: Int, rows: Int) {
        samples = (0..<rows).flatMap { row in
            (0..<columns).map { column in
                let point = CGPoint(x: Double(column) / Double(columns - 1),
                                    y: Double(row) / Double(rows - 1))
                var color = LookColor(lightness: lightness, reach: 0, hue: 0)
                color.move(to: point)
                return Sample(point: point, color: color.rgb)
            }
        }
    }
}

/// Moving a handle changes hue and reach, so the expensive gamut field stays
/// the same. A small shared LRU also bounds grids from older editor sessions.
@MainActor
final class LookFieldGridCache {
    static let shared = LookFieldGridCache()
    private struct Key: Equatable {
        let lightness: Double
        let columns: Int
        let rows: Int
    }
    private struct Entry {
        let key: Key
        let grid: LookFieldGrid
    }
    private let limit: Int
    private var entries: [Entry] = []
    var count: Int { entries.count }

    init(limit: Int = 8) {
        precondition(limit > 0)
        self.limit = limit
    }

    func grid(lightness: Double, columns: Int, rows: Int) -> LookFieldGrid {
        precondition(columns > 1 && rows > 1)
        let key = Key(lightness: min(0.75, max(0.55, lightness)), columns: columns, rows: rows)
        if let index = entries.firstIndex(where: { $0.key == key }) {
            let entry = entries.remove(at: index)
            entries.append(entry)
            return entry.grid
        }
        let grid = LookFieldGrid(lightness: key.lightness, columns: columns, rows: rows)
        entries.append(Entry(key: key, grid: grid))
        if entries.count > limit { entries.removeFirst() }
        return grid
    }
}
