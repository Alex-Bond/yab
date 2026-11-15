import Foundation

/// What the virtual Mac knows that the real one would read off the pages it
/// works on: which site sends a code, what a yes is for and its facts, where
/// a task breaks in the fail mode, and how it behaves (awake, asleep, slow,
/// failing). A world says it under "virtualMac" (tasks-live.json,
/// mac-states.json); without it the prototype's own story stands: the TAP
/// code for Lisbon flights and its payment.
struct MacScript: Codable, Sendable {
    /// How the Mac behaves.
    enum Mode: String, Codable, CaseIterable, Sendable {
        /// Awake: takes tasks at once, a step every 1.7 s.
        case online
        /// Asleep since `asleepSince`: tasks wait; wakes after `wakeAfter` if set.
        case asleep
        /// Awake but slow: everything it says comes 2 s late.
        case slow
        /// A task breaks where `scripts[id].fail` says, once; Retry goes on.
        case fail
    }

    var mode: Mode
    /// Seconds between steps.
    var stepSeconds: Double
    /// How late everything comes in the slow mode.
    var slowSeconds: Double
    /// How long it takes the Mac to take a task it was sent.
    var takeSeconds: Double
    /// How long it presses Pay before it is done.
    var paySeconds: Double
    /// When it fell asleep, as the Now line says it.
    var asleepSince: String
    /// Asleep: wakes this many seconds after launch. None: sleeps until woken.
    var wakeAfter: Double?
    /// How long the Mac has been idle when it asks for a yes on the iPhone.
    var idleMinutes: Int
    var scripts: [TaskRun.ID: TaskScript]

    /// One task's story on the Mac.
    struct TaskScript: Codable, Sendable {
        var code: CodeRequest?
        /// The code the site sent; anything else is asked again.
        var expectedCode: String?
        var yes: YesRequest?
        /// Where it breaks in the fail mode, and its words.
        var failStep: Int?
        var failure: TaskFailure?
        /// The Lock Screen when done: "Booked TAP, seat 14A" and where it is.
        var doneTitle: String?
        var doneLine: String?
    }

    init(mode: Mode = .online, stepSeconds: Double = 1.7, slowSeconds: Double = 2, takeSeconds: Double = 0.5,
         paySeconds: Double = 0.9, asleepSince: String = "18:52", wakeAfter: Double? = nil, idleMinutes: Int = 12,
         scripts: [TaskRun.ID: TaskScript] = MacScript.story) {
        self.mode = mode
        self.stepSeconds = stepSeconds
        self.slowSeconds = slowSeconds
        self.takeSeconds = takeSeconds
        self.paySeconds = paySeconds
        self.asleepSince = asleepSince
        self.wakeAfter = wakeAfter
        self.idleMinutes = idleMinutes
        self.scripts = scripts
    }

    enum CodingKeys: String, CodingKey {
        case mode, stepSeconds, slowSeconds, takeSeconds, paySeconds, asleepSince, wakeAfter, idleMinutes, scripts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = MacScript()
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? base.mode
        stepSeconds = try c.decodeIfPresent(Double.self, forKey: .stepSeconds) ?? base.stepSeconds
        slowSeconds = try c.decodeIfPresent(Double.self, forKey: .slowSeconds) ?? base.slowSeconds
        takeSeconds = try c.decodeIfPresent(Double.self, forKey: .takeSeconds) ?? base.takeSeconds
        paySeconds = try c.decodeIfPresent(Double.self, forKey: .paySeconds) ?? base.paySeconds
        asleepSince = try c.decodeIfPresent(String.self, forKey: .asleepSince) ?? base.asleepSince
        wakeAfter = try c.decodeIfPresent(Double.self, forKey: .wakeAfter)
        idleMinutes = try c.decodeIfPresent(Int.self, forKey: .idleMinutes) ?? base.idleMinutes
        // A world's scripts add to the story; the same id replaces it.
        let own = try c.decodeIfPresent([TaskRun.ID: TaskScript].self, forKey: .scripts) ?? [:]
        scripts = MacScript.story.merging(own) { _, new in new }
    }

    func script(_ id: TaskRun.ID) -> TaskScript { scripts[id] ?? TaskScript() }

    // MARK: - the prototype's story

    /// Lisbon flights as the prototype tells it: TAP's code 482 913 from
    /// Messages, then €238 to TAP with the facts from the payment page.
    static let story: [TaskRun.ID: TaskScript] = [
        "lisbon": TaskScript(
            code: CodeRequest(sender: "TAP", icon: "tap", site: "flytap.com"),
            expectedCode: "482913",
            yes: YesRequest(
                kind: .pay, icon: "tap", title: "Pay €238.00 to TAP Air Portugal?", subtitle: "flytap.com · Lisbon flights",
                facts: [
                    ["Out", "Tue, Oct 13 · ARN 18:35 → LIS 22:10 · nonstop"],
                    ["Back", "Sat, Oct 17 · LIS 10:40 → ARN 15:15 · nonstop"],
                    ["Traveler", "Mira Lindqvist · seat 14A, window"],
                    ["Card", "Visa ·· 4242"],
                ],
                button: "Pay with Face ID", waiting: "Waiting for you: Pay €238"),
            failStep: 2,
            failure: TaskFailure(line: "Couldn’t open flytap.com · the page didn’t load",
                                 long: "Couldn’t open flytap.com: the page didn’t load on your Mac",
                                 lockTitle: "Couldn’t open flytap.com",
                                 lockLine: "The page didn’t load on your Mac. Retry from Yab."),
            doneTitle: "Booked TAP, seat 14A", doneLine: "Confirmation in Mail · flight in Daybook"),
    ]

    // MARK: - from a world

    /// The script a world carries under "virtualMac", if any; a world's Mac
    /// marked asleep sleeps.
    static func load(world: World) -> MacScript {
        var script = MacScript()
        if let url = World.folder?.appendingPathComponent("\(world.name).json"),
           let data = try? Data(contentsOf: url),
           let wrapper = try? JSONDecoder().decode(Wrapper.self, from: data),
           let own = wrapper.virtualMac {
            script = own
        }
        if world.mac.asleep, script.mode == .online { script.mode = .asleep }
        return script
    }

    private struct Wrapper: Decodable { var virtualMac: MacScript? }

    /// Launch arguments over the world's own: -YabMac online|asleep|slow|fail,
    /// -YabMacWake <seconds>, -YabMacStep <seconds>.
    func applying(arguments: [String]) -> MacScript {
        func value(_ key: String) -> String? {
            guard let i = arguments.firstIndex(of: "-" + key), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        var script = self
        if let mode = value("YabMac").flatMap(Mode.init(rawValue:)) { script.mode = mode }
        if let wake = value("YabMacWake").flatMap(Double.init) { script.wakeAfter = wake }
        if let step = value("YabMacStep").flatMap(Double.init) { script.stepSeconds = step }
        return script
    }
}
