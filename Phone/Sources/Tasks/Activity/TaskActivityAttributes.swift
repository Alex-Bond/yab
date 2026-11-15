import ActivityKit
import Foundation

/// The Live Activity of the task the Now line speaks for: the same one
/// thing, on the Lock Screen and in the Dynamic Island while another app is
/// in front. One activity for all tasks, as there is one Now line; what it
/// says changes with the task in front. Compiled into the app (which starts,
/// updates and ends it) and into YabActivity (which draws it).
///
/// Nothing in it names an amount or who gets paid: a locked iPhone shows it
/// to whoever holds it ("A payment needs you", the amount in Yab after
/// Face ID).
struct TaskActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        /// The task: its id, its name ("Lisbon flights") and its status (TaskStatus's raw value).
        var task: String
        var name: String
        var status: String
        /// The Island: the step's site and two words ("4 direct", "Code"); orange when it needs you.
        var icon: String
        var word: String
        var warn: Bool
        /// The Lock Screen: the state at the head's right ("On your Mac",
        /// "Needs you", "Done", "Stopped"), a title, a line, buttons.
        var head: String
        var title: String
        var line: String
        var buttons: [ActivityButton]
    }

    /// Whose tasks: the Mac that does them ("MacBook Pro").
    var mac: String
}

/// A button on the Lock Screen or the expanded Island. Enter Code, Review,
/// Retry and Open open Yab (its sheet grows out of the button); Stop and Not
/// Now act where they are.
struct ActivityButton: Codable, Hashable, Sendable {
    enum Style: String, Codable, Sendable {
        /// White at .18 on the dark card.
        case plain
        /// Orange, dark words: what needs you.
        case warn
        /// White, black words: Open on the expanded Island.
        case primary
    }

    /// code, review, notNow, stop, retry, open.
    var action: String
    var label: String
    var style: Style

    /// Opens Yab rather than acting from the Lock Screen.
    var opensApp: Bool { ["code", "review", "retry", "open"].contains(action) }

    /// The link that opens Yab at this task, the action's sheet ready.
    func url(task: String) -> URL {
        URL(string: "yab://task/\(task)/\(action)") ?? URL(string: "yab://task")!
    }
}
