import Foundation

public struct Meeting: Equatable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    /// The call it happens on, from its place, its link or its notes.
    public let link: URL?
    /// Who else is invited, by address, for mail that is about it.
    public var people: [String] = []
    /// The calendar it is in, when that isn't the account's own: "Team",
    /// "Personal". Nil for the primary and the Mac's.
    public var calendar: String?

    public init(id: String, title: String, start: Date, end: Date, link: URL?, people: [String] = [], calendar: String? = nil) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.link = link
        self.people = people
        self.calendar = calendar
    }
}

/// A stretch of your calendar that is taken (Meetings.busy): what an
/// invitation clashes with, and what free slots go round.
public struct BusyTime: Equatable, Sendable {
    public let title: String
    public let start: Date
    public let end: Date
    /// Its iCalendar UID, to tell an invitation's own event from the rest.
    public var uid = ""
    /// Not said yes to: maybe, or not answered yet.
    public var maybe = false
    /// Google Calendar's own page for it (its htmlLink); "" for the Mac's.
    public var link = ""

    public init(title: String, start: Date, end: Date, uid: String = "", maybe: Bool = false, link: String = "") {
        self.title = title
        self.start = start
        self.end = end
        self.uid = uid
        self.maybe = maybe
        self.link = link
    }
}
