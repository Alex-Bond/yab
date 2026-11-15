import Foundation

/// A legacy answer choice is an array index. Validate before converting a remote
/// JSON number to Int: out-of-range conversion traps rather than throwing.
public enum SyncChoice {
    public static let invalidReason = "Yab couldn’t read that chat request. Send a new question."

    public static let targetReason = "This chat request is no longer supported. Send a new question."

    public static func index(_ value: Value?) -> Int? {
        guard let number = value?.number, number.isFinite, number >= 0,
              number.rounded(.towardZero) == number, number < Double(Int.max) else { return nil }
        return Int(number)
    }
}
