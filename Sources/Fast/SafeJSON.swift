import Foundation

/// JSONSerialization raises an Objective-C exception, which Swift's `try`
/// and `try?` do not catch, for a value JSON has no form for: a Date, NaN,
/// Infinity, Data, any other object. WebKit hands Swift exactly those from a
/// page or an extension (a JS Date arrives as NSDate, NaN as a NaN number).
/// Raised inside a main-actor task, the exception unwinds the task's job,
/// AppKit reports it and carries on, and the main thread's executor record is
/// left pointing into the dead stack: the next isolation check anywhere (a
/// timer's or SwiftUI hover's MainActor.assumeIsolated) crashes in
/// swift_getObjectType, far from the cause. That is the 0.46.x executor
/// crash family (scripts/runs/probe_task_exception_appkit.py reproduces it).
/// Values that come from WebKit go through here before JSONSerialization.
enum SafeJSON {
    struct NotJSON: LocalizedError {
        var errorDescription: String? { "The value has no JSON form (a date, NaN or Infinity)." }
    }

    /// Whether JSONSerialization can write the value, scalar or container,
    /// everything nested in it included. Never raises.
    static func fits(_ value: Any) -> Bool {
        JSONSerialization.isValidJSONObject([value])
    }

    /// The value's JSON, or a Swift error where JSONSerialization would raise.
    /// Scalars are allowed at the top.
    static func data(_ value: Any, options: JSONSerialization.WritingOptions = []) throws -> Data {
        guard fits(value) else { throw NotJSON() }
        return try JSONSerialization.data(withJSONObject: value, options: options.union(.fragmentsAllowed))
    }

    /// The entries JSON can hold; a date or NaN among a script's stored
    /// values is left out rather than taking the rest down with it.
    static func keepable(_ values: [String: Any]) -> [String: Any] {
        values.filter { fits($0.value) }
    }
}
