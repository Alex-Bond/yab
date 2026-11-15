import Foundation

// Where a thing stands in a list, as a string that sorts between its
// neighbors: moving a tab writes that tab alone, never its neighbors (Chrome's
// UniquePosition, Figma's fractional indexes). Keys are digits in base 62
// read as a fraction, with no trailing zero, so there is always room between
// any two of them.

public enum Order {
    static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    static let base = digits.count
    private static let index: [Character: Int] = Dictionary(uniqueKeysWithValues: digits.enumerated().map { ($1, $0) })

    /// A key after `a` and before `b`; nil means the start or the end.
    /// Keys that are not in order, or not keys, are taken as missing.
    public static func between(_ a: String?, _ b: String?) -> String {
        var a = a.flatMap { valid($0) ? $0 : nil } ?? ""
        var b = b.flatMap { valid($0) ? $0 : nil }
        if let low = Optional(a), let high = b, !(low < high) {
            // Out of order: make room after the larger.
            a = max(low, high); b = nil
        }
        // At either end, step by one digit rather than halve: a list grown
        // a tab at a time from the top or the bottom keeps short keys.
        if b == nil { return a.isEmpty ? String(digits[base / 2]) : after(Array(a)) }
        if a.isEmpty, let b { return before(Array(b)) }
        return midpoint(Array(a), b.map(Array.init))
    }

    private static func after(_ a: [Character]) -> String {
        guard let first = a.first, let d = index[first] else { return String(digits[base / 2]) }
        if d < base - 1 { return String(digits[d + 1]) }
        return String(first) + after(Array(a.dropFirst()))
    }

    private static func before(_ b: [Character]) -> String {
        guard let first = b.first, let d = index[first] else { return String(digits[base / 2]) }
        if d > 1 { return String(digits[d - 1]) }
        if d == 1 && b.count > 1 { return String(first) }
        let rest = Array(b.dropFirst())
        return String(digits[0]) + (rest.isEmpty ? String(digits[base - 1]) : before(rest))
    }

    /// `count` keys in order between `a` and `b`, as short as they can be:
    /// what a list of a hundred tabs gets the first time it is numbered.
    public static func spread(_ count: Int, after a: String? = nil, before b: String? = nil) -> [String] {
        guard count > 0 else { return [] }
        // Halving here, even at the ends, keeps the whole list balanced.
        let low = a.flatMap { valid($0) ? $0 : nil } ?? ""
        let high = b.flatMap { valid($0) && low < $0 ? $0 : nil }
        let mid = midpoint(Array(low), high.map(Array.init))
        let left = (count - 1) / 2
        return spread(left, after: a, before: mid) + [mid] + spread(count - 1 - left, after: mid, before: b)
    }

    public static func valid(_ key: String) -> Bool {
        !key.isEmpty && key.last != "0" && key.allSatisfy { index[$0] != nil }
    }

    private static func midpoint(_ a: [Character], _ b: [Character]?) -> String {
        if let b {
            // The prefix both share stays; the rest is found below it.
            var n = 0
            while n < b.count && (n < a.count ? a[n] : "0") == b[n] { n += 1 }
            if n > 0 {
                let rest = midpoint(Array(a.dropFirst(min(n, a.count))), Array(b.dropFirst(n)))
                let shared = (0..<n).map { $0 < a.count ? a[$0] : "0" }
                return String(shared) + rest
            }
        }
        let lo = a.first.flatMap { index[$0] } ?? 0
        let hi = b?.first.flatMap { index[$0] } ?? base
        if hi - lo > 1 {
            return String(digits[(lo + hi + 1) / 2])
        }
        if let b, b.count > 1 {
            return String(b[0])
        }
        return String(digits[lo]) + midpoint(Array(a.dropFirst()), nil)
    }
}

public extension Order {
    /// Keys for `ids` in the order given, keeping every key it can from
    /// `previous`: the longest run of them already in order stays as it
    /// is, and only what moved or is new gets a key between its neighbors.
    /// A tab dragged to the top of a hundred changes one key, not a hundred.
    static func assign(_ ids: [String], previous: [String: String]) -> [String: String] {
        // The longest increasing run of old keys, by patience sorting.
        let old = ids.map { previous[$0].flatMap { valid($0) ? $0 : nil } }
        var tails: [Int] = []          // index into ids of the run's tail per length
        var back = [Int?](repeating: nil, count: ids.count)
        for (i, key) in old.enumerated() {
            guard let key else { continue }
            var lo = 0, hi = tails.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if old[tails[mid]]! < key { lo = mid + 1 } else { hi = mid }
            }
            back[i] = lo > 0 ? tails[lo - 1] : nil
            if lo == tails.count { tails.append(i) } else { tails[lo] = i }
        }
        var stays = Set<Int>()
        var at = tails.last
        while let i = at { stays.insert(i); at = back[i] }

        var out: [String: String] = [:]
        var i = 0
        var low: String?
        while i < ids.count {
            if stays.contains(i) {
                low = old[i]
                out[ids[i]] = low
                i += 1
                continue
            }
            // A stretch of new keys up to the next that stays.
            var j = i
            while j < ids.count && !stays.contains(j) { j += 1 }
            let high = j < ids.count ? old[j] : nil
            for (n, key) in spread(j - i, after: low, before: high).enumerated() {
                out[ids[i + n]] = key
            }
            low = out[ids[j - 1]]
            i = j
        }
        return out
    }
}
