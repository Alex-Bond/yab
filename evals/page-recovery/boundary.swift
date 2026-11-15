import Foundation

// The only production code inserted here is the exact private recovery
// method. These boundaries make delayed callbacks deterministic, model
// silently ignored loads, and record lazy view creation and every open.
private let WKErrorDomain = "WKErrorDomain"
private enum WKError: Int { case webContentProcessTerminated = 2 }

@MainActor private enum Startup {
    static var loadOnWindow = true
    static func flag(_ name: String) -> Bool { name == "LOAD_ON_WINDOW" && loadOnWindow }
}

private struct Deadline {
    let seconds: Double
    @MainActor static func now() -> Deadline { Deadline(seconds: Scheduler.now) }
    static func + (lhs: Deadline, rhs: Double) -> Deadline { Deadline(seconds: lhs.seconds + rhs) }
}

@MainActor private enum Scheduler {
    private struct Work {
        let at: Double
        let order: Int
        let run: @MainActor () -> Void
    }
    static var now = 0.0
    private static var order = 0
    private static var work: [Work] = []
    static func reset() { now = 0; order = 0; work = []; Startup.loadOnWindow = true; Ledger.reset() }
    static func later(at: Double, _ run: @escaping @MainActor () -> Void) {
        order += 1
        work.append(Work(at: at, order: order, run: run))
    }
    static func advance(to target: Double) {
        var count = 0
        while let next = work.enumerated().filter({ $0.element.at <= target }).min(by: {
            $0.element.at == $1.element.at ? $0.element.order < $1.element.order : $0.element.at < $1.element.at
        }) {
            let task = work.remove(at: next.offset)
            now = task.at
            task.run()
            count += 1
            precondition(count < 1000, "Unbounded recovery scheduler loop")
        }
        now = target
    }
}

@MainActor private final class DispatchQueue {
    static let main = DispatchQueue()
    func async(_ work: @escaping @MainActor () -> Void) { Scheduler.later(at: Scheduler.now, work) }
    func asyncAfter(deadline: Deadline, execute work: @escaping @MainActor () -> Void) {
        Scheduler.later(at: deadline.seconds, work)
    }
}

@MainActor private enum Ledger {
    static var nextView = 0
    static var opens: [[String: Any]] = []
    static var evaluations: [Int] = []
    static func reset() { nextView = 0; opens = []; evaluations = [] }
    static func label(_ url: URL) -> String { url.path == "/a" ? "A" : url.path == "/b" ? "B" : "other" }
}

@MainActor private final class PageView {
    let number: Int
    var window: NSObject?
    var onWindow: (() -> Void)?
    var url: URL?
    var acceptsOpen = true
    var interactionState: Any?
    var completions: [(Any?, Error?) -> Void] = []
    init() { Ledger.nextView += 1; number = Ledger.nextView }
    func open(_ url: URL) {
        Ledger.opens.append(["view": number, "route": Ledger.label(url)])
        if acceptsOpen { self.url = url }
    }
    func evaluateQuietly(_ script: String, completion: @escaping (Any?, Error?) -> Void) {
        precondition(script == "document.readyState", "Unexpected boundary evaluation")
        Ledger.evaluations.append(number)
        completions.append(completion)
    }
    func replyTerminated() {
        precondition(!completions.isEmpty, "No pending ready-state evaluation")
        completions.removeFirst()(nil, NSError(domain: WKErrorDomain, code: WKError.webContentProcessTerminated.rawValue))
    }
    func attach() { window = NSObject(); onWindow?() }
}

@MainActor private final class Tab {
    var built: PageView?
    var pending: URL?
    var gone = false
    var address: URL?
    var goSerial = 0
    var askedAt: Double?
    var lazyCreations = 0
    var web: PageView {
        if let built { return built }
        let page = PageView()
        lazyCreations += 1
        built = page
        return page
    }
    init(_ url: URL) { address = url }
    func beginRecovery(_ url: URL) { loadAndVerify(url) }
    func navigate(to url: URL) {
        goSerial += 1
        address = url
        pending = nil
        web.open(url)
    }
    func discardForSleep() { pending = address; built = nil }
    func discardForClose() { gone = true; built = nil }
    func startNavigation() { askedAt = (askedAt ?? 0) + 1 }

    // ACTUAL_TAB_LOAD_AND_VERIFY_METHOD
}

private struct ContractFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor private enum Tests {
    static let first = URL(string: "https://recovery.test/a")!
    static let second = URL(string: "https://recovery.test/b")!
    static func expect(_ value: @autoclosure () -> Bool, _ why: String) throws {
        if !value() { throw ContractFailure(description: why) }
    }
    static func opened(_ url: URL) -> Int {
        Ledger.opens.filter { $0["route"] as? String == Ledger.label(url) }.count
    }
    static func live(_ url: URL) -> (Tab, PageView) {
        let tab = Tab(url)
        let page = tab.web
        page.window = NSObject()
        return (tab, page)
    }
    static func run() -> [[String: Any]] {
        let checks: [(String, @MainActor () throws -> Void)] = [
            ("live blank recovery retries", {
                let (tab, page) = live(first)
                page.url = URL(string: "about:blank")
                page.acceptsOpen = false
                tab.beginRecovery(first)
                Scheduler.advance(to: 1.5)
                try expect(opened(first) == 2, "The current silent blank load must be retried once")
                try expect(tab.built === page && tab.lazyCreations == 1, "A valid retry must keep its original view")
            }),
            ("live terminated recovery retries", {
                let (tab, page) = live(first)
                tab.beginRecovery(first)
                Scheduler.advance(to: 1.5)
                try expect(page.completions.count == 1, "The current page must be checked")
                page.replyTerminated()
                try expect(opened(first) == 2, "The current terminated-process answer must retry")
            }),
            ("unattached current recovery reaches fallback", {
                let tab = Tab(first)
                tab.beginRecovery(first)
                Scheduler.advance(to: 1)
                try expect(opened(first) == 1, "A current unattached view still loads at the one-second fallback")
                try expect(tab.lazyCreations == 1, "The fallback must reuse its original view")
            }),
            ("new navigation cancels stale attachment", {
                let tab = Tab(first)
                tab.beginRecovery(first)
                let old = tab.web
                let lateAttachment = old.onWindow
                tab.navigate(to: second)
                old.window = NSObject()
                lateAttachment?()
                Scheduler.advance(to: 1.1)
                try expect(opened(first) == 0, "A stale attachment callback reopened the previous address")
                try expect(opened(second) == 1 && old.url == second, "The newer navigation must remain selected")
            }),
            ("sleep before attachment cannot recreate view", {
                let tab = Tab(first)
                tab.beginRecovery(first)
                tab.discardForSleep()
                Scheduler.advance(to: 2.6)
                try expect(tab.built == nil && tab.lazyCreations == 1, "An old attach/fallback rebuilt a sleeping page")
                try expect(Ledger.opens.isEmpty && tab.pending == first, "A sleeping tab was reopened by stale recovery")
            }),
            ("close before attachment cannot recreate view", {
                let tab = Tab(first)
                tab.beginRecovery(first)
                tab.discardForClose()
                Scheduler.advance(to: 2.6)
                try expect(tab.gone && tab.built == nil && tab.lazyCreations == 1, "An old callback rebuilt a closed page")
                try expect(Ledger.opens.isEmpty, "A closed page was reopened")
            }),
            ("sleep before verification cannot recreate view", {
                let (tab, _) = live(first)
                tab.beginRecovery(first)
                tab.discardForSleep()
                Scheduler.advance(to: 1.5)
                try expect(tab.built == nil && tab.lazyCreations == 1, "Verification used the lazy getter after sleep")
                try expect(Ledger.evaluations.isEmpty && opened(first) == 1, "A sleeping page was checked or reopened")
            }),
            ("same URL replacement invalidates recovery", {
                let (tab, original) = live(first)
                tab.beginRecovery(first)
                let replacement = PageView()
                replacement.url = first
                replacement.window = NSObject()
                tab.built = replacement
                Scheduler.advance(to: 1.5)
                try expect(original.number != replacement.number, "The retained old view and replacement must be distinct")
                try expect(Ledger.evaluations.isEmpty, "Old recovery checked a different view with the same URL")
                try expect(opened(first) == 1 && tab.built === replacement, "Old recovery changed the replacement document")
            }),
            ("late terminated answer cannot undo navigation", {
                let (tab, page) = live(first)
                tab.beginRecovery(first)
                Scheduler.advance(to: 1.5)
                try expect(page.completions.count == 1, "Expected one deliberately delayed ready-state answer")
                tab.navigate(to: second)
                page.replyTerminated()
                try expect(opened(first) == 1 && opened(second) == 1 && page.url == second, "A late old-page error reopened the old address")
            }),
            ("same URL navigation start invalidates verification", {
                let (tab, page) = live(first)
                page.url = URL(string: "about:blank")
                page.acceptsOpen = false
                tab.beginRecovery(first)
                tab.startNavigation()
                Scheduler.advance(to: 1.5)
                try expect(opened(first) == 1 && Ledger.evaluations.isEmpty, "A newer navigation to the same URL must invalidate an old retry")
            }),
        ]
        var results: [[String: Any]] = []
        for (name, check) in checks {
            Scheduler.reset()
            do {
                try check()
                print("PASS \(name)")
                results.append(["name": name, "passed": true, "opens": Ledger.opens,
                                "view_creations": Ledger.nextView, "evaluations": Ledger.evaluations])
            } catch {
                print("FAIL \(name): \(error)")
                results.append(["name": name, "passed": false, "error": String(describing: error),
                                "opens": Ledger.opens, "view_creations": Ledger.nextView,
                                "evaluations": Ledger.evaluations])
            }
        }
        return results
    }
}

@main private struct Main {
    @MainActor static func main() throws {
        let results = Tests.run()
        let passed = results.allSatisfy { $0["passed"] as? Bool == true }
        let report: [String: Any] = ["passed": passed, "checks": results.count, "results": results]
        let bytes = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print(String(decoding: bytes, as: UTF8.self))
        if !passed { exit(1) }
    }
}
