import Foundation

/// A task the Mac does in Yab with the person's sign-ins, given from the
/// iPhone in words. Its definition says what it is and the steps it goes
/// through; its run says how far it got (TaskRun).
struct TaskDefinition: Identifiable, Codable, Hashable, Sendable {
    typealias ID = String

    var id: ID
    /// "Lisbon flights".
    var name: String
    /// The site's icon it shows when done.
    var icon: String
    /// What was asked, in the person's words.
    var ask: String
    var steps: [Step]
    /// Done, in one line: "Booked · TAP, Oct 13 18:35, seat 14A".
    var result: String
    /// Done, said fully in its chat.
    var resultLong: String?
    /// Its tabs in its folder on the Mac, as far as it got: icon and title.
    var tabs: [TaskTab]
    /// What the Now line says when it needs a yes ("Pay €238 to TAP?"), a code
    /// ("Needs the code TAP sent you"), when it stopped, and while the Mac pays.
    var yes: String?
    var code: String?
    var failure: String?
    var paying: String?

    struct Step: Codable, Hashable, Sendable {
        /// The site it is on.
        var icon: String
        /// While it runs: "Comparing 4 direct flights".
        var run: String
        /// Once done: "Compared 4 direct flights".
        var done: String
        /// Two words for the Dynamic Island and the folded Now line: "4 direct".
        var island: String
        /// A second line, when there is more to say.
        var sub: String?
        /// What it will need from the person at this step.
        var needs: Need?
    }

    enum Need: String, Codable, Sendable {
        case code, yes
    }

    struct TaskTab: Codable, Hashable, Sendable {
        var icon: String
        var title: String
    }
}

/// Every state a task's Now line can say, the prototype's.
enum TaskStatus: String, Codable, CaseIterable, Sendable {
    /// Sent, before the Mac takes it.
    case sending
    /// The Mac works on it, a step in words.
    case running
    /// The site sent a code to this iPhone.
    case code
    /// A payment, a post or a cancel waits for the person's yes and Face ID.
    case yes
    /// It stopped: what happened, and Retry.
    case failed
    /// The Mac is asleep; it waits, not lost.
    case waits
    /// The Mac presses the site's Pay.
    case paying
    /// Done, until its result is opened.
    case done
    /// The person stopped it: nothing more is said about it (its tabs stay
    /// in their folder on the Mac).
    case stopped
}

/// How far a task got.
struct TaskRun: Identifiable, Codable, Hashable, Sendable {
    typealias ID = String

    /// The definition's id.
    var id: ID
    var status: TaskStatus
    /// The step it is on (the prototype's `k`).
    var step: Int
    /// Its result was opened: the Now line stops saying Done.
    var seen: Bool
    var codeGiven: Bool
    var yesGiven: Bool
    /// What stopped it, in the Mac's words, when it failed: "Couldn’t open
    /// flytap.com · the page didn’t load". None: the definition's own words.
    var failure: String?
    /// When the Mac fell asleep ("18:52"), for a task that waits for it;
    /// none when the Mac just hasn't answered.
    var asleepSince: String?

    init(id: ID, status: TaskStatus = .sending, step: Int = 0, seen: Bool = false, codeGiven: Bool = false, yesGiven: Bool = false,
         failure: String? = nil, asleepSince: String? = nil) {
        self.id = id
        self.status = status
        self.step = step
        self.seen = seen
        self.codeGiven = codeGiven
        self.yesGiven = yesGiven
        self.failure = failure
        self.asleepSince = asleepSince
    }

    enum CodingKeys: String, CodingKey { case id, status, step, seen, codeGiven, yesGiven, failure, asleepSince }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ID.self, forKey: .id)
        status = try c.decodeIfPresent(TaskStatus.self, forKey: .status) ?? .sending
        step = try c.decodeIfPresent(Int.self, forKey: .step) ?? 0
        seen = try c.decodeIfPresent(Bool.self, forKey: .seen) ?? false
        codeGiven = try c.decodeIfPresent(Bool.self, forKey: .codeGiven) ?? false
        yesGiven = try c.decodeIfPresent(Bool.self, forKey: .yesGiven) ?? false
        failure = try c.decodeIfPresent(String.self, forKey: .failure)
        asleepSince = try c.decodeIfPresent(String.self, forKey: .asleepSince)
    }

    /// Something the person has to do.
    var needsYou: Bool { status == .code || status == .yes }
    var isLive: Bool { status == .running || status == .sending }
}

/// The one line over the plate: the most important thing, in words. Nothing
/// to say, no line: quiet is the all clear.
struct NowItem: Equatable, Sendable {
    enum Kind: String, Sendable {
        /// Running, sending, paying: ink.
        case plain
        /// Needs you or stopped: orange words, an action.
        case warn
        /// Waits for the Mac: gray, the Mac's glyph.
        case wait
        /// Done and not opened: green.
        case done
        /// The tab in front on the Mac, a minute after it.
        case handoff
        /// An answer or a chat put away.
        case parked
        /// A page a Mac sent, waiting in Today (Send to iPhone).
        case arrived
        /// A file on its way, or just arrived (DownloadStore).
        case download
    }

    enum Icon: Equatable, Sendable {
        case favicon(String)
        case glyph(GlyphName)
        /// Yab's mark: sent, not taken yet.
        case mark
        /// The agent's face: a chat.
        case face
        /// A Mac menu mark: a file.
        case mac(MacGlyph)
    }

    /// The task's id, "mac" for the handoff, the chat's id for a parked one.
    var id: String
    var kind: Kind
    var title: String
    var subtitle: String
    /// The action capsule: Review, Enter Code, Retry.
    var action: String?
    /// The word it folds to beside the plate's capsule.
    var short: String
    var icon: Icon
    /// "+1", "+2 done": the rest are in the column.
    var more: String?
    /// The tab in front on the Mac as a small chip over the plate: its site's
    /// icon with the Mac's mark, and "Figma · On your Mac" (handoff only).
    var chip: Chip?
    /// A newer observation resets any in-flight dismissal, even with the same words.
    var noticeRevision: UInt64? = nil

    struct Chip: Equatable, Sendable {
        var icon: String
        var words: String
    }

    /// The task it speaks for, if it is a task's.
    var taskID: TaskRun.ID? { kind == .handoff || kind == .parked || kind == .arrived ? nil : id }

    /// What a task's line says (the prototype's nowItem).
    static func task(_ run: TaskRun, _ def: TaskDefinition) -> NowItem {
        let step = def.steps.isEmpty ? nil : def.steps[min(max(run.step, 0), def.steps.count - 1)]
        let siteIcon = Icon.favicon(step?.icon ?? def.icon)
        var item = NowItem(id: run.id, kind: .plain, title: def.name, subtitle: step?.run ?? "", action: nil,
                           short: step?.island ?? def.name, icon: siteIcon, more: nil)
        switch run.status {
        case .yes:
            item.kind = .warn
            item.subtitle = def.yes ?? "Needs your yes"
            item.action = "Review"
            item.short = "Needs you"
        case .code:
            item.kind = .warn
            item.subtitle = def.code ?? "Needs the code the site sent you"
            item.action = "Enter Code"
            item.short = "Code"
        case .failed:
            item.kind = .warn
            item.subtitle = run.failure ?? def.failure ?? "It stopped"
            item.action = "Retry"
            item.short = "Failed"
        case .waits:
            item.kind = .wait
            item.subtitle = run.asleepSince.map { "Waits for your Mac · asleep since \($0)" } ?? "Waits for your Mac · no answer yet"
            item.short = "Waits"
            item.icon = .glyph(.macbook)
        case .sending:
            item.subtitle = "Sending to your Mac"
            item.short = "Sending"
            item.icon = .mark
        case .paying:
            item.subtitle = def.paying ?? "Pressing Pay"
            item.short = "Paying"
        case .done:
            item.kind = .done
            item.subtitle = def.result
            item.short = "Done"
            item.icon = .favicon(def.icon)
        case .stopped:
            item.subtitle = "Stopped · its tabs stay on your Mac"
            item.short = "Stopped"
        case .running:
            break
        }
        return item
    }

    /// The tab in front on the Mac: open it here, on the same place of the page.
    static func handoff(_ tab: Tab) -> NowItem {
        NowItem(id: "mac", kind: .handoff, title: "On your Mac", subtitle: "\(tab.short) · \(tab.site)", action: nil,
                short: "From Mac", icon: .glyph(.macbook), more: nil,
                chip: Chip(icon: tab.icon, words: "\(tab.site) · On your Mac"))
    }

    /// A page a Mac sent, in Today: the same calm chip as the Mac's tab,
    /// its words "From <Mac>: <title>", and Open.
    static func arrived(_ page: ArrivedPage) -> NowItem {
        NowItem(id: "arrived." + page.tab, kind: .arrived, title: "From \(page.mac)", subtitle: page.title, action: "Open",
                short: "From Mac", icon: .glyph(.macbook), more: nil,
                chip: Chip(icon: page.icon, words: "From \(page.mac): \(page.title)"))
    }
}

/// A page a Mac sent this iPhone, put at the top of Today (Send to iPhone):
/// the tab it became, and what its card says.
struct ArrivedPage: Equatable, Sendable {
    var tab: Tab.ID
    var title: String
    var icon: String
    /// The Mac's name.
    var mac: String
}
