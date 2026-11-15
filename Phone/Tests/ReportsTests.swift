import SwiftUI
import XCTest
@testable import YabPhone

/// What Yab for iPhone sends to its site (Reports/): the day's count once a
/// UTC day unless turned off, and crash reports from MetricKit, shaped as the
/// Mac's, asked about once and sent only after a yes or with automatic
/// sending on. The sample payload is Phone/Tests/MetricKitPayload.json.
@MainActor
final class ReportsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var folder: URL!
    private let site = URL(string: "https://yetanotherbrowser.com")!

    override func setUp() {
        suiteName = "reports-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("reports-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - daily activity

    func testTheDayIsCountedOncePerUTCDay() async throws {
        var posted: [URLRequest] = []
        func count(at time: String) async -> Bool {
            await DailyActivity.sendIfDue(site: site, defaults: defaults, now: date(time)) { posted.append($0); return true }
        }
        let first = await count(at: "2026-10-09T00:30:00Z")
        let evening = await count(at: "2026-10-09T23:59:00Z")
        let nextDay = await count(at: "2026-10-10T00:01:00Z")
        XCTAssertTrue(first)
        XCTAssertFalse(evening, "one count a UTC day")
        XCTAssertTrue(nextDay)
        XCTAssertEqual(posted.count, 2)
        XCTAssertEqual(defaults.string(forKey: DailyActivity.dayKey), "2026-10-10")

        let request = try XCTUnwrap(posted.first)
        XCTAssertEqual(request.url?.absoluteString, "https://yetanotherbrowser.com/api/activity")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertFalse(request.httpShouldHandleCookies)
        let bodies = try posted.map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0.httpBody ?? Data()) as? [String: String]) }
        XCTAssertEqual(Set(bodies[0].keys), ["id", "platform"], "the Mac's payload and the platform, nothing else")
        XCTAssertEqual(bodies[0]["platform"], "iphone")
        XCTAssertEqual(bodies[0]["id"], bodies[1]["id"], "the same installation every day")
    }

    func testACountTheSiteDidNotTakeIsTriedAgainTheSameDay() async {
        var tries = 0
        let failed = await DailyActivity.sendIfDue(site: site, defaults: defaults, now: date("2026-10-09T08:00:00Z")) { _ in
            tries += 1
            return false
        }
        XCTAssertFalse(failed)
        XCTAssertNil(defaults.string(forKey: DailyActivity.dayKey))
        let again = await DailyActivity.sendIfDue(site: site, defaults: defaults, now: date("2026-10-09T09:00:00Z")) { _ in
            tries += 1
            return true
        }
        XCTAssertTrue(again)
        XCTAssertEqual(tries, 2)
    }

    func testShareDailyActivityOffSendsNothing() async {
        let store = SettingsStore(defaults: defaults)
        XCTAssertTrue(store.shareDailyActivity, "on unless turned off")
        XCTAssertTrue(DailyActivity.sends(defaults))
        store.shareDailyActivity = false
        XCTAssertFalse(DailyActivity.sends(defaults), "the switch and the count read one key")
        var posted = 0
        let sent = await DailyActivity.sendIfDue(site: site, defaults: defaults, now: Date()) { _ in posted += 1; return true }
        XCTAssertFalse(sent)
        XCTAssertEqual(posted, 0)
        store.shareDailyActivity = true
        let back = await DailyActivity.sendIfDue(site: site, defaults: defaults, now: Date()) { _ in posted += 1; return true }
        XCTAssertTrue(back)
        XCTAssertEqual(posted, 1)
    }

    func testTheInstallationIDIsMadeOnceInTheShapeTheSiteTakes() throws {
        let id = DailyActivity.installation(in: defaults)
        XCTAssertEqual(DailyActivity.installation(in: defaults), id)
        // fast-web's /api/activity takes a lowercase version 4 UUID.
        let shape = try NSRegularExpression(pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
        XCTAssertNotNil(shape.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)), id)
    }

    func testDebugBuildsAndTestRunsHaveNoSite() {
        XCTAssertNil(Reports.site(in: .main, options: LaunchOptions(arguments: ["Yab"])), "Debug's YabSite is empty")
        XCTAssertNil(Reports.site(in: .main, options: LaunchOptions(arguments: ["Yab", "-YabWorld", "mira"])))
        XCTAssertNil(Reports.site)
    }

    // MARK: - a MetricKit payload

    func testACrashBecomesAReportShapedAsTheMacs() throws {
        let reports = DiagnosticReports.crashes(inPayload: try payload(), bundle: "dev.serafim.fast.iphone")
        XCTAssertEqual(reports.count, 2)
        let crash = reports[0]
        XCTAssertEqual(crash.version, "0.0.8")
        XCTAssertEqual(crash.build, "202610081530")
        XCTAssertEqual(crash.os, "iPhone OS 26.0.1 (23A355)")
        XCTAssertEqual(crash.device, "iPhone17,1")
        XCTAssertNil(crash.exception)
        XCTAssertEqual(crash.at, date("2026-10-08T15:42:11Z"))

        let (head, body) = try parts(crash.report)
        // The site's madeBy reads the first line.
        XCTAssertEqual(head["app_version"] as? String, "0.0.8")
        XCTAssertEqual(head["build_version"] as? String, "202610081530")
        XCTAssertEqual(head["platform"] as? String, "iphone")
        XCTAssertEqual(head["device"] as? String, "iPhone17,1")
        XCTAssertEqual(head["bundleID"] as? String, "dev.serafim.fast.iphone")
        XCTAssertEqual(head["testflight"] as? Bool, true)

        let exception = try XCTUnwrap(body["exception"] as? [String: Any])
        XCTAssertEqual(exception["type"] as? String, "EXC_BREAKPOINT")
        XCTAssertEqual(exception["signal"] as? String, "SIGTRAP")
        XCTAssertEqual(exception["codes"] as? String, "0x0000000000000001")
        XCTAssertEqual((body["termination"] as? [String: Any])?["reason"] as? String, "Namespace SIGNAL, Code 5 Trace/BPT trap: 5")

        // The crashed thread is the one MetricKit attributes it to, its
        // frames innermost first, each in a binary listed once.
        XCTAssertEqual(body["faultingThread"] as? Int, 1)
        let threads = try XCTUnwrap(body["threads"] as? [[String: Any]])
        let images = try XCTUnwrap(body["usedImages"] as? [[String: Any]])
        XCTAssertEqual(threads.count, 2)
        XCTAssertEqual(threads[1]["triggered"] as? Bool, true)
        XCTAssertNil(threads[0]["triggered"])
        let frames = try XCTUnwrap(threads[1]["frames"] as? [[String: Any]])
        XCTAssertEqual(frames.count, 7)
        let names = frames.map { images[$0["imageIndex"] as! Int]["name"] as! String }
        XCTAssertEqual(names, ["libswiftCore.dylib", "Yab", "Yab", "UIKitCore", "UIKitCore", "Yab", "dyld"])
        XCTAssertEqual(images.filter { $0["name"] as? String == "Yab" }.count, 1)
        let yab = try XCTUnwrap(images.first { $0["name"] as? String == "Yab" })
        XCTAssertEqual(yab["uuid"] as? String, "8F3B6C1E-2D4A-3B5C-9E7F-1A2B3C4D5E6F")
        XCTAssertEqual(yab["arch"] as? String, "arm64", "the code's architecture, not the device's arm64e")
        XCTAssertEqual(frames[1]["imageOffset"] as? Int, 0x1F2A4)
        XCTAssertEqual(frames[1]["address"] as? Int, 0x1029E4000 + 0x1F2A4)

        // The site's signature: the exception and the first of Yab's own frames.
        let signature = [exception["type"] as! String] + frames
            .filter { (images[$0["imageIndex"] as! Int]["name"] as! String).lowercased() == "yab" }
            .prefix(4).map { "+\($0["imageOffset"] as! Int)" }
        XCTAssertEqual(signature, ["EXC_BREAKPOINT", "+127652", "+122896", "+1216"])

        // MetricKit's own tree goes too, frames only.
        let tree = try XCTUnwrap(body["callStackTree"] as? [String: Any])
        XCTAssertEqual((tree["callStacks"] as? [Any])?.count, 2)
    }

    func testWhatFindingTheCrashDoesNotNeedStaysOnTheIPhone() throws {
        let crash = try XCTUnwrap(DiagnosticReports.crashes(inPayload: try payload(), bundle: "x").first)
        for word in ["regionFormat", "virtualMemoryRegionInfo", "containers/Bundle", "pid", "lowPowerModeEnabled"] {
            XCTAssertFalse(crash.report.contains(word), word)
        }
        let (_, body) = try parts(crash.report)
        XCTAssertEqual(Set((body["metaData"] as? [String: Any] ?? [:]).keys), [
            "appVersion", "appBuildVersion", "osVersion", "deviceType", "platformArchitecture", "isTestFlightApp",
            "exceptionType", "exceptionCode", "signal", "terminationReason",
        ])
    }

    func testAnObjectiveCExceptionGoesWithoutItsArguments() throws {
        let crash = DiagnosticReports.crashes(inPayload: try payload(), bundle: "x")[1]
        XCTAssertEqual(crash.exception, "NSRangeException: *** -[__NSArrayM objectAtIndexedSubscript:]: index %lu beyond bounds [0 .. %lu]")
        XCTAssertFalse(crash.report.contains("mira@example.com"), "the composed message can hold anything")
        XCTAssertFalse(crash.report.contains("composedMessage"))
        let (_, body) = try parts(crash.report)
        XCTAssertEqual((body["exception"] as? [String: Any])?["type"] as? String, "EXC_CRASH")
        XCTAssertEqual((body["exception"] as? [String: Any])?["signal"] as? String, "SIGABRT")
        XCTAssertEqual((body["objcException"] as? [String: Any])?["name"] as? String, "NSRangeException")
        XCTAssertEqual(CrashReports.fields(crash)["exception"] as? String, crash.exception)
    }

    func testTheSameCrashHasTheSameKeyAndAnotherCrashAnother() throws {
        let data = try payload()
        let first = DiagnosticReports.crashes(inPayload: data, bundle: "x")
        let again = DiagnosticReports.crashes(inPayload: data, bundle: "x")
        XCTAssertEqual(first.map(\.key), again.map(\.key))
        XCTAssertNotEqual(first[0].key, first[1].key)
    }

    func testAReportTooBigForTheSiteLosesTheTreeThenOtherThreads() throws {
        let deep: [String: Any] = ["imageIndex": 0, "imageOffset": 1, "address": 2]
        let threads: [[String: Any]] = [
            ["id": 0, "frames": Array(repeating: deep, count: 8000)],
            ["id": 1, "triggered": true, "frames": [deep]],
        ]
        let body: [String: Any] = ["faultingThread": 1, "threads": threads, "callStackTree": ["x": String(repeating: "y", count: 400_000)]]
        let text = DiagnosticReports.text(head: ["app_name": "Yab"], body: body)
        XCTAssertLessThanOrEqual(text.utf8.count, DiagnosticReports.reportBytes)
        let (_, cut) = try parts(text)
        XCTAssertNil(cut["callStackTree"])
        let kept = try XCTUnwrap(cut["threads"] as? [[String: Any]])
        XCTAssertEqual((kept[0]["frames"] as? [Any])?.count, 0)
        XCTAssertEqual((kept[1]["frames"] as? [Any])?.count, 1, "the crashed thread is never cut")
    }

    func testAnOffsetIsReadAsTheSymbolsNeedIt() {
        XCTAssertEqual(DiagnosticReports.imageOffset(address: 0x1029E4000 + 0x1F2A4, offset: 0x1F2A4), 0x1F2A4)
        // A load address written where the offset belongs.
        XCTAssertEqual(DiagnosticReports.imageOffset(address: 0x1029E4000 + 0x1F2A4, offset: 0x1029E4000), 0x1F2A4)
        XCTAssertNil(DiagnosticReports.imageOffset(address: 5, offset: nil))
        XCTAssertNil(DiagnosticReports.imageOffset(address: 5, offset: -1))
    }

    func testHangStacksKeepOnlyFramesAndTheNewestFive() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try payload()) as? [String: Any])
        let hang = try XCTUnwrap((object["hangDiagnostics"] as? [[String: Any]])?.first)
        var tree = try XCTUnwrap(hang["callStackTree"] as? [String: Any])
        tree["somethingElse"] = "dropped"
        let stack = try XCTUnwrap(HangStacks.stack(milliseconds: 2500, build: "202610081530",
                                                   tree: JSONSerialization.data(withJSONObject: tree)))
        XCTAssertEqual(stack["ms"] as? Int, 2500)
        XCTAssertEqual(stack["build"] as? String, "202610081530")
        XCTAssertNil((stack["stack"] as? [String: Any])?["somethingElse"])
        let file = folder.appendingPathComponent("hang-stacks.json")
        HangStacks.keep(Array(repeating: stack, count: 4), in: file)
        HangStacks.keep(Array(repeating: stack, count: 4), in: file)
        XCTAssertEqual(HangStacks.stacks(in: file).count, HangStacks.kept)
        HangStacks.forget(in: file)
        XCTAssertTrue(HangStacks.stacks(in: file).isEmpty)
    }

    // MARK: - hangs

    func testALongHangBecomesAReportWithItsWholeTree() throws {
        let (reports, stacks) = DiagnosticReports.hangs(inPayload: try hangPayload(), bundle: "dev.serafim.fast.iphone")
        XCTAssertTrue(stacks.isEmpty)
        let hang = try XCTUnwrap(reports.first)
        XCTAssertEqual(reports.count, 1)
        XCTAssertTrue(hang.isHang)
        XCTAssertEqual(hang.kind, "hang")
        XCTAssertEqual(hang.version, "0.1.3")
        XCTAssertEqual(hang.build, "202610231200")
        XCTAssertEqual(hang.os, "iPhone OS 26.4 (23E244)")
        XCTAssertEqual(hang.device, "iPhone18,1")
        XCTAssertNil(hang.exception)

        let (head, body) = try parts(hang.report)
        XCTAssertEqual(head["kind"] as? String, "hang", "the site keeps it as a hang")
        XCTAssertEqual(head["app_version"] as? String, "0.1.3")
        XCTAssertEqual(head["build_version"] as? String, "202610231200")
        XCTAssertEqual(head["platform"] as? String, "iphone")
        XCTAssertEqual((body["hang"] as? [String: Any])?["ms"] as? Int, 8400)
        XCTAssertEqual((body["metaData"] as? [String: Any])?["hangDuration"] as? String, "8.4 sec")
        for word in ["regionFormat", "lowPowerModeEnabled", "pid"] {
            XCTAssertFalse(hang.report.contains(word), word)
        }

        // The heaviest path of the thread it is blamed on, innermost first,
        // though MetricKit gave it from dyld's start.
        XCTAssertEqual(body["faultingThread"] as? Int, 0)
        let threads = try XCTUnwrap(body["threads"] as? [[String: Any]])
        let images = try XCTUnwrap(body["usedImages"] as? [[String: Any]])
        let frames = try XCTUnwrap(threads.first?["frames"] as? [[String: Any]])
        let names = frames.map { images[$0["imageIndex"] as! Int]["name"] as! String }
        XCTAssertEqual(names, ["WebKit", "Yab", "SwiftUI", "UIKitCore", "dyld"])
        XCTAssertEqual(frames[1]["imageOffset"] as? Int, 0x2A000, "PageViewport.apply's branch, 7 of 9 samples")

        // The whole tree goes: both branches, every thread, their samples.
        let tree = try XCTUnwrap(body["callStackTree"] as? [String: Any])
        let stacks2 = try XCTUnwrap(tree["callStacks"] as? [[String: Any]])
        XCTAssertEqual(stacks2.count, 2)
        let root = try XCTUnwrap((stacks2[0]["callStackRootFrames"] as? [[String: Any]])?.first)
        let ui = try XCTUnwrap((root["subFrames"] as? [[String: Any]])?.first)
        let swiftUI = try XCTUnwrap((ui["subFrames"] as? [[String: Any]])?.first)
        XCTAssertEqual((swiftUI["subFrames"] as? [[String: Any]])?.map { $0["sampleCount"] as? Int }, [2, 7])
        XCTAssertNil(tree["somethingElse"])

        let fields = CrashReports.fields(hang)
        XCTAssertEqual(fields["kind"] as? String, "hang")
        XCTAssertEqual(fields["platform"] as? String, "iphone")
        XCTAssertNil(CrashReports.fields(try XCTUnwrap(sample().first))["kind"], "a crash says no kind")
        XCTAssertEqual(DiagnosticReports.hangs(inPayload: try hangPayload(), bundle: "x").reports.map(\.key),
                       reports.map(\.key), "the same hang twice is one")
    }

    func testAShortHangOnlyKeepsItsStack() throws {
        let short = DiagnosticReports.hangs(inPayload: try hangPayload(), bundle: "x", durations: [900])
        XCTAssertTrue(short.reports.isEmpty)
        XCTAssertEqual(short.stacks.first?["ms"] as? Int, 900, "MetricKit's own duration wins over its words")
        XCTAssertEqual(short.stacks.first?["build"] as? String, "202610231200")
        // The sample payload's 2.5 sec hang is long enough.
        XCTAssertEqual(DiagnosticReports.hangs(inPayload: try payload(), bundle: "x").reports.count, 1)
        XCTAssertEqual(DiagnosticReports.milliseconds("2.5 sec"), 2500)
        XCTAssertEqual(DiagnosticReports.milliseconds("2,5 sec"), 2500)
        XCTAssertEqual(DiagnosticReports.milliseconds("800 ms"), 800)
        XCTAssertEqual(DiagnosticReports.milliseconds("1 min"), 60_000)
        XCTAssertNil(DiagnosticReports.milliseconds("long"))
    }

    func testAHangNeverAsksOnItsOwnAndGoesUnderTheNextCrashsYes() async throws {
        let recorder = Recorder(answer: true)
        let reports = crashReports(recorder)
        let hangs = DiagnosticReports.hangs(inPayload: try hangPayload(), bundle: "x").reports
        await reports.received(hangs, hangs: [])
        XCTAssertEqual(recorder.asked, 0, "a hang alone waits")
        XCTAssertTrue(recorder.posted.isEmpty)
        XCTAssertEqual(reports.load().pending.count, 1)
        await reports.received(try sample(), hangs: [])
        XCTAssertEqual(recorder.asked, 1, "one question")
        XCTAssertEqual(recorder.posted.count, 3, "the yes covers the hang waiting")
        XCTAssertEqual(recorder.posted.compactMap { $0["kind"] as? String }, ["hang"])
        XCTAssertTrue(reports.load().pending.isEmpty)
    }

    func testADeclineDropsTheHangsWaitingToo() async throws {
        let recorder = Recorder(answer: false)
        let reports = crashReports(recorder)
        await reports.received(DiagnosticReports.hangs(inPayload: try hangPayload(), bundle: "x").reports, hangs: [])
        await reports.received(try sample(), hangs: [])
        XCTAssertEqual(recorder.asked, 1)
        XCTAssertTrue(recorder.posted.isEmpty)
        XCTAssertTrue(reports.load().pending.isEmpty)
    }

    func testWithAutomaticSendingAHangGoesAtOnce() async throws {
        let recorder = Recorder(answer: false)
        let reports = crashReports(recorder)
        SettingsStore(defaults: defaults).sendCrashReports = true
        await reports.received(DiagnosticReports.hangs(inPayload: try hangPayload(), bundle: "x").reports, hangs: [])
        XCTAssertEqual(recorder.asked, 0)
        XCTAssertEqual(recorder.posted.first?["kind"] as? String, "hang")
    }

    func testABuildWithoutASiteSendsNoHang() async throws {
        let recorder = Recorder(answer: true)
        let reports = CrashReports(defaults: defaults, folder: folder, ask: { recorder.ask() }, post: nil)
        SettingsStore(defaults: defaults).sendCrashReports = true
        await reports.received(DiagnosticReports.hangs(inPayload: try hangPayload(), bundle: "x").reports, hangs: [])
        await reports.received(try sample(), hangs: [])
        XCTAssertEqual(recorder.asked, 0)
        XCTAssertTrue(recorder.posted.isEmpty)
    }

    func testHangsWaitApartAndNeverPushACrashOut() {
        var ledger = CrashLedger()
        ledger.add((1 ... 5).map { report("c\($0)") })
        var hangs = (1 ... 4).map { report("h\($0)") }
        for index in hangs.indices { hangs[index].kind = "hang" }
        ledger.add(hangs)
        XCTAssertEqual(ledger.pending.map(\.key), ["c1", "c2", "c3", "c4", "c5", "h2", "h3", "h4"])
        ledger.add([report("c6")])
        XCTAssertEqual(ledger.pending.filter { !$0.isHang }.map(\.key), ["c2", "c3", "c4", "c5", "c6"])
        XCTAssertEqual(ledger.pending.filter(\.isHang).count, CrashLedger.hangsKept)
    }

    func testAnOlderLedgerWithoutKindsStillReads() throws {
        let old = #"{"pending":[{"key":"k","version":"0.1.1","build":"1","os":"iOS","device":"iPhone","report":"{}"}],"allowed":[],"seen":["k"]}"#
        let ledger = try JSONDecoder().decode(CrashLedger.self, from: Data(old.utf8))
        XCTAssertEqual(ledger.pending.first?.kind, nil)
        XCTAssertFalse(ledger.pending[0].isHang)
    }

    func testWhatWasKeptGoesWithTheFirstReportThenIsForgotten() async throws {
        let recorder = Recorder(answer: true)
        let reports = crashReports(recorder)
        let day = ExitCounts.day(begin: "2026-10-22 00:00:00 +0000", end: "2026-10-23 00:00:00 +0000", version: "0.1.3",
                                 build: "202610231200", foreground: ["watchdog": 2, "normal": 9], background: ["watchdog": 1],
                                 hangTime: [["from": 0, "to": 250, "count": 40]])
        ExitCounts.keep([day], in: reports.exitFile)
        var clock: CFTimeInterval = 0
        let loops = UpdateLoops(file: reports.loopFile, clock: { clock }, state: { "active" })
        loops.woke()
        clock = 3
        for index in 1 ... UpdateLoops.threshold {
            loops.add(.viewport) {
                UpdateLoops.Fingerprint(fields: ["chrome.folded": index == UpdateLoops.threshold ? 1 : 0])
            }
        }
        await reports.received(try sample(), hangs: [["ms": 600, "stack": ["callStacks": []]]])
        XCTAssertEqual(recorder.posted.count, 2)
        let first = recorder.posted[0]
        XCTAssertEqual((first["hangs"] as? [[String: Any]])?.count, 1)
        let exits = try XCTUnwrap(first["exits"] as? [[String: Any]])
        XCTAssertEqual(((exits[0]["exits"] as? [String: Any])?["foregroundExitData"] as? [String: Int])?["watchdog"], 2)
        let stalls = try XCTUnwrap(first["stalls"] as? String)
        XCTAssertTrue(stalls.hasPrefix("update loop {"))
        XCTAssertTrue(stalls.contains(#""viewport":1024"#))
        let line = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(stalls.dropFirst("update loop ".count).utf8)) as? [String: Any])
        let inputs = try XCTUnwrap(line["inputs"] as? [String: [String: Any]])
        let changes = try XCTUnwrap(inputs["viewport"]?["changes"] as? [[String: Any]])
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0]["fields"] as? [String: [Double]], ["chrome.folded": [0, 1]])
        for key in ["hangs", "exits", "stalls"] { XCTAssertNil(recorder.posted[1][key], key) }
        XCTAssertTrue(ExitCounts.days(in: reports.exitFile).isEmpty)
        XCTAssertTrue(UpdateLoops.lines(in: reports.loopFile).isEmpty)
        XCTAssertTrue(HangStacks.stacks(in: reports.hangFile).isEmpty)
    }

    func testExitCountsKeepAWeekAndADayOnce() {
        let file = folder.appendingPathComponent("exits.json")
        func day(_ n: Int) -> [String: Any] {
            ExitCounts.day(begin: "2026-10-\(10 + n) 00:00:00 +0000", end: "2026-10-\(11 + n) 00:00:00 +0000", version: nil,
                           build: nil, foreground: [:], background: ["watchdog": n], hangTime: [])
        }
        ExitCounts.keep((1 ... 5).map(day), in: file)
        ExitCounts.keep((4 ... 9).map(day), in: file)
        let kept = ExitCounts.days(in: file)
        XCTAssertEqual(kept.count, ExitCounts.kept)
        XCTAssertEqual(kept.map { $0["begin"] as? String }, (3 ... 9).map { "2026-10-\(10 + $0) 00:00:00 +0000" })
        XCTAssertNil(kept[0]["hangTime"])
    }

    // MARK: - update loops

    func testAnUpdateLoopIsWrittenDownBeforeTheWatchdogAndWhenItEnds() throws {
        let file = folder.appendingPathComponent("loops.json")
        var clock: CFTimeInterval = 100
        let loops = UpdateLoops(file: file, clock: { clock }, state: { "background" })
        // A busy frame that runs often but quickly writes nothing.
        loops.woke()
        for _ in 0 ..< 5000 { loops.add(.pageHost) }
        clock += 0.2
        loops.sleeps()
        XCTAssertTrue(UpdateLoops.lines(in: file).isEmpty)
        // One slow call, run a few times: nothing either.
        loops.woke()
        clock += 6
        for _ in 0 ..< 40 { loops.add(.viewport) }
        loops.sleeps()
        XCTAssertTrue(UpdateLoops.lines(in: file).isEmpty, "a slow call is not a loop")
        // A loop: past the threshold and a second busy, written at once.
        loops.woke()
        clock += 1.5
        for _ in 0 ..< UpdateLoops.threshold { loops.add(.viewport) }
        loops.add(.plusMenu)
        var lines = UpdateLoops.lines(in: file)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0]["busyMs"] as? Int, 1500)
        XCTAssertEqual(lines[0]["state"] as? String, "background")
        XCTAssertEqual(lines[0]["counts"] as? [String: Int], ["viewport": 1024])
        XCTAssertNil(lines[0]["endedMs"])
        // Climbing: the same line, written again when the count doubles.
        clock += 2
        for _ in 0 ..< UpdateLoops.threshold { loops.add(.viewport) }
        lines = UpdateLoops.lines(in: file)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0]["counts"] as? [String: Int], ["viewport": 2048, "plusMenu": 1])
        XCTAssertEqual(lines[0]["busyMs"] as? Int, 3500)
        // It ended after all.
        clock += 0.5
        loops.sleeps()
        lines = UpdateLoops.lines(in: file)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0]["endedMs"] as? Int, 4000)
        // The newest few stretches stay.
        for _ in 0 ..< 7 {
            loops.woke()
            clock += 1.1
            for _ in 0 ..< UpdateLoops.threshold { loops.add(.root) }
            clock += 1
        }
        lines = UpdateLoops.lines(in: file)
        XCTAssertEqual(lines.count, UpdateLoops.kept)
        XCTAssertEqual(lines.map { $0["counts"] as? [String: Int] }, Array(repeating: ["root": 1024], count: UpdateLoops.kept))
    }

    // MARK: - asked once

    func testNewReportsAskOnceAndADeclineDropsThem() async throws {
        let recorder = Recorder(answer: false)
        let reports = crashReports(recorder)
        await reports.received(try sample(), hangs: [])
        XCTAssertEqual(recorder.asked, 1)
        XCTAssertTrue(recorder.posted.isEmpty)
        XCTAssertTrue(reports.load().pending.isEmpty, "declined reports are left behind")
        // The same crash handed over at the next launch doesn't ask again.
        await reports.received(try sample(), hangs: [])
        await reports.offer()
        XCTAssertEqual(recorder.asked, 1)
        XCTAssertFalse(reports.automatic, "an answer never turns on automatic sending")
        // A new crash does.
        await reports.received([report("later")], hangs: [])
        XCTAssertEqual(recorder.asked, 2)
    }

    func testAYesSendsTheseReportsWithTheHangsOnceAndAutomaticStaysOff() async throws {
        let recorder = Recorder(answer: true)
        let reports = crashReports(recorder)
        let hang: [String: Any] = ["ms": 2500, "stack": ["callStacks": []]]
        await reports.received([], hangs: [hang])
        XCTAssertEqual(recorder.asked, 0, "hangs alone wait for a crash, as on the Mac")
        await reports.received(try sample(), hangs: [])
        XCTAssertEqual(recorder.asked, 1)
        XCTAssertEqual(recorder.posted.count, 2)
        XCTAssertNotNil(recorder.posted[0]["hangs"], "the hangs go with the first report")
        XCTAssertNil(recorder.posted[1]["hangs"])
        XCTAssertTrue(HangStacks.stacks(in: reports.hangFile).isEmpty, "then are forgotten")
        XCTAssertTrue(reports.load().pending.isEmpty)
        XCTAssertFalse(reports.automatic)
        let fields = recorder.posted[0]
        XCTAssertEqual(fields["platform"] as? String, "iphone")
        XCTAssertEqual(fields["version"] as? String, "0.0.8")
        XCTAssertEqual(fields["build"] as? String, "202610081530")
        XCTAssertEqual(fields["os"] as? String, "iPhone OS 26.0.1 (23A355)")
        XCTAssertEqual(fields["device"] as? String, "iPhone17,1")
        XCTAssertTrue((fields["report"] as? String ?? "").hasPrefix("{\"app_name\":\"Yab\""))
    }

    func testAutomaticSendingNeverAsks() async throws {
        let recorder = Recorder(answer: false)
        let reports = crashReports(recorder)
        SettingsStore(defaults: defaults).sendCrashReports = true
        XCTAssertTrue(reports.automatic, "the switch and the reports read one key")
        await reports.received(try sample(), hangs: [])
        XCTAssertEqual(recorder.asked, 0)
        XCTAssertEqual(recorder.posted.count, 2)
    }

    func testAQuestionThatCouldNotBeAskedIsAskedLater() async throws {
        let recorder = Recorder(answer: nil)
        let reports = crashReports(recorder)
        await reports.received(try sample(), hangs: [])
        XCTAssertEqual(recorder.asked, 1)
        XCTAssertEqual(reports.load().pending.count, 2, "still waiting")
        recorder.answer = true
        await reports.offer()
        XCTAssertEqual(recorder.asked, 2)
        XCTAssertEqual(recorder.posted.count, 2)
    }

    func testAReportTheSiteDidNotTakeStaysWithThoseAfterIt() async throws {
        let recorder = Recorder(answer: true)
        recorder.takes = false
        let reports = crashReports(recorder)
        await reports.received(try sample(), hangs: [])
        XCTAssertEqual(recorder.posted.count, 1, "the rest wait behind the one refused")
        XCTAssertEqual(reports.load().pending.count, 2)
        XCTAssertEqual(Set(reports.load().allowed), Set(reports.load().pending.map(\.key)), "the yes is kept")
        recorder.takes = true
        await reports.offer()
        XCTAssertEqual(recorder.asked, 1, "a yes is not asked for twice")
        XCTAssertEqual(recorder.posted.count, 3)
        XCTAssertTrue(reports.load().pending.isEmpty)
        XCTAssertTrue(reports.load().allowed.isEmpty)
    }

    func testTheFirstLaunchThatCouldSendPassesOverItsBacklog() async throws {
        let recorder = Recorder(answer: true)
        let reports = CrashReports(defaults: defaults, folder: folder, ask: { recorder.ask() }, post: { recorder.post($0) })
        reports.start(site: site)
        XCTAssertTrue(reports.backlog)
        await reports.received(try sample(), hangs: [])
        XCTAssertEqual(recorder.asked, 0)
        XCTAssertTrue(reports.load().pending.isEmpty)
        // The next launch: the same crashes are known, new ones ask.
        let next = CrashReports(defaults: defaults, folder: folder, ask: { recorder.ask() }, post: { recorder.post($0) })
        next.start(site: site)
        XCTAssertFalse(next.backlog)
        await next.received(try sample(), hangs: [])
        XCTAssertEqual(recorder.asked, 0)
        await next.received([report("after")], hangs: [])
        XCTAssertEqual(recorder.asked, 1)
        XCTAssertEqual(recorder.posted.count, 1)
    }

    func testTheLedgerKeepsTheNewestFiveAndRemembersWhatItSaw() {
        var ledger = CrashLedger()
        ledger.add((1 ... 7).map { report("r\($0)") })
        XCTAssertEqual(ledger.pending.map(\.key), ["r3", "r4", "r5", "r6", "r7"])
        ledger.allow(["r3", "r4", "gone"])
        XCTAssertEqual(ledger.allowed, ["r3", "r4"])
        XCTAssertEqual(ledger.unasked.map(\.key), ["r5", "r6", "r7"])
        ledger.remove(["r3", "r4", "r5", "r6", "r7"])
        XCTAssertTrue(ledger.allowed.isEmpty)
        ledger.add([report("r1")])
        XCTAssertTrue(ledger.pending.isEmpty, "seen before")
    }

    func testTheQuestionSpeaksTheMacsWords() {
        let alert = CrashQuestion.alert { _ in }
        XCTAssertEqual(alert.title, "Share saved crash reports?")
        XCTAssertEqual(alert.actions.map(\.title), ["Don’t Send", "Send"])
        XCTAssertEqual(alert.preferredAction?.title, "Send")
        for text in [CrashQuestion.message, SettingsContent.crashesFooter, SettingsContent.activityFooter, SettingsContent.sentFooter] {
            XCTAssertFalse(text.contains("\u{2014}") || text.contains("\u{2013}"), text)
            XCTAssertFalse(text.contains("macOS"), text)
        }
    }

    // MARK: - Settings › About

    func testAboutHasBothSwitchesWhenTheBuildSends() throws {
        let store = SettingsStore(defaults: defaults)
        XCTAssertFalse(store.sendCrashReports, "crash reports are off until said")
        XCTAssertTrue(store.shareDailyActivity)
        let content = SettingsContent(store: store, context: SettingsContext(reportsAvailable: true))
        let rows = content.sections(.about).flatMap(\.rows)
        XCTAssertEqual(rows.map(\.id), ["about.version", "about.crashes", "about.activity"])
        guard case let .toggle(crashes) = rows[1].kind, case let .toggle(activity) = rows[2].kind else {
            return XCTFail("switches")
        }
        XCTAssertEqual(rows[1].title, "Automatically send crash reports")
        XCTAssertEqual(rows[2].title, "Share daily activity")
        XCTAssertFalse(crashes.wrappedValue)
        XCTAssertTrue(activity.wrappedValue)
        activity.wrappedValue = false
        XCTAssertFalse(DailyActivity.sends(defaults))
        crashes.wrappedValue = true
        XCTAssertTrue(defaults.bool(forKey: CrashReports.key))
        XCTAssertEqual(content.sections(.privacy).first { $0.id == "privacy" }?.footer, SettingsContent.sentFooter)
        XCTAssertEqual(SettingsIndex.matches("crash", content: content).first?.page, .about)
    }

    func testABuildThatSendsNothingShowsNoSwitches() {
        let content = SettingsContent(store: SettingsStore(defaults: defaults), context: SettingsContext(reportsAvailable: false))
        XCTAssertEqual(content.sections(.about).flatMap(\.rows).map(\.id), ["about.version"])
        XCTAssertNil(content.sections(.privacy).first { $0.id == "privacy" }?.footer)
    }

    // MARK: - helpers

    /// Answers the question as told (nil: couldn't ask now) and the site as
    /// told, writing down what came.
    @MainActor
    private final class Recorder {
        var answer: Bool?
        var takes = true
        var asked = 0
        var posted: [[String: Any]] = []
        init(answer: Bool?) { self.answer = answer }
        func ask() -> Bool? { asked += 1; return answer }
        func post(_ fields: [String: Any]) -> Bool { posted.append(fields); return takes }
    }

    /// Not the first launch that could send: reports wait for a yes.
    private func crashReports(_ recorder: Recorder) -> CrashReports {
        defaults.set(Date(timeIntervalSince1970: 0), forKey: CrashReports.sinceKey)
        let reports = CrashReports(defaults: defaults, folder: folder, ask: { recorder.ask() }, post: { recorder.post($0) })
        reports.start(site: site)
        return reports
    }

    private func payload() throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("MetricKitPayload.json"))
    }

    /// A payload with one 8.4 s hang, as a watchdog kill's: the main
    /// thread's samples merged into a tree from dyld's start, two branches
    /// under SwiftUI's update, and a second thread.
    private func hangPayload() throws -> Data {
        func frame(_ name: String, _ offset: Int, _ samples: Int, _ sub: [[String: Any]] = []) -> [String: Any] {
            var frame: [String: Any] = ["binaryName": name, "binaryUUID": "UUID-\(name)", "offsetIntoBinaryTextSegment": offset,
                                        "address": 0x1_0000_0000 + offset, "sampleCount": samples]
            if !sub.isEmpty { frame["subFrames"] = sub }
            return frame
        }
        let main = frame("dyld", 0x100, 9, [frame("UIKitCore", 0x200, 9, [frame("SwiftUI", 0x300, 9, [
            frame("Yab", 0x1B000, 2, [frame("UIKitCore", 0x400, 2)]),
            frame("Yab", 0x2A000, 7, [frame("WebKit", 0x500, 7)]),
        ])])])
        let payload: [String: Any] = [
            "timeStampBegin": "2026-10-23 10:00:00 +0000", "timeStampEnd": "2026-10-23 10:30:00 +0000",
            "hangDiagnostics": [[
                "version": "1.0.0",
                "callStackTree": [
                    "callStackPerThread": false, "somethingElse": "dropped",
                    "callStacks": [["threadAttributed": true, "callStackRootFrames": [main]],
                                   ["callStackRootFrames": [frame("libsystem_kernel.dylib", 0x10, 9)]]],
                ],
                "diagnosticMetaData": [
                    "appBuildVersion": "202610231200", "appVersion": "0.1.3", "hangDuration": "8.4 sec",
                    "osVersion": "iPhone OS 26.4 (23E244)", "deviceType": "iPhone18,1", "platformArchitecture": "arm64e",
                    "regionFormat": "US", "lowPowerModeEnabled": false, "pid": 812,
                ],
            ]],
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private func sample() throws -> [CrashReport] {
        DiagnosticReports.crashes(inPayload: try payload(), bundle: "dev.serafim.fast.iphone")
    }

    private func report(_ key: String) -> CrashReport {
        CrashReport(key: key, version: "0.0.8", build: "1", os: "iPhone OS 26.0", device: "iPhone17,1", exception: nil,
                    report: "{\"app_name\":\"Yab\"}\n{}", at: nil)
    }

    private func parts(_ report: String) throws -> ([String: Any], [String: Any]) {
        let lines = report.split(separator: "\n", maxSplits: 1).map(String.init)
        XCTAssertEqual(lines.count, 2, "a first line, then the body")
        let head = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        return (head, body)
    }

    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }
}
