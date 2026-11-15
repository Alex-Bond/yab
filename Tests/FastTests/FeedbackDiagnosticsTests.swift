import AppKit
import Testing
@testable import Fast

@MainActor
@Suite(.serialized)
struct FeedbackDiagnosticsTests {
    @Test func memoryAddsOnlyNumbersSettingsAndKindsToTheExistingShape() throws {
        let log = FeedbackDiagnostics(clock: { 100 })
        var state = FeedbackDiagnostics.State()
        state.memory = FeedbackDiagnostics.Memory(
            sample: MemoryCeiling.Sample(at: 95, yabFootprintBytes: 123_456_789, webProcessCount: 5,
                                         footprints: [100, 900, 300, 700]),
            sleepsTabs: true, configuredSleepAfterSeconds: 14_400, sleepAfterSeconds: 3600,
            lowPower: false, thrift: true)
        let text = try #require(log.snapshots(stallLog: "", state: state).first)
        let payload = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(Set(payload.keys) == ["schemaVersion", "windowSeconds", "events", "state", "system",
                                      "extensions", "stalls", "hitches", "timings", "memory"])
        #expect(payload["schemaVersion"] as? Int == 2)
        #expect(payload["windowSeconds"] as? Int == 300)
        let memory = try #require(payload["memory"] as? [String: Any])
        #expect(Set(memory.keys) == ["sampled", "sampleAgeSeconds", "yabFootprintBytes", "webProcessCount",
                                     "measuredWebProcessCount", "largestWebProcessFootprintsBytes", "sleepsTabs",
                                     "configuredSleepAfterSeconds", "sleepAfterSeconds", "lowPower", "thrift",
                                     "sleepsSinceLaunch", "reloadsSinceLaunch"])
        #expect(memory["sampled"] as? Bool == true)
        #expect(memory["sampleAgeSeconds"] as? Int == 5)
        #expect(memory["yabFootprintBytes"] as? UInt64 == 123_456_789)
        #expect(memory["webProcessCount"] as? Int == 5)
        #expect(memory["measuredWebProcessCount"] as? Int == 4)
        #expect(memory["largestWebProcessFootprintsBytes"] as? [UInt64] == [900, 700, 300])
        #expect(memory["sleepsTabs"] as? Bool == true)
        #expect(memory["configuredSleepAfterSeconds"] as? Int == 14_400)
        #expect(memory["sleepAfterSeconds"] as? Int == 3600)
        #expect(memory["lowPower"] as? Bool == false)
        #expect(memory["thrift"] as? Bool == true)
        let sleeps = try #require(memory["sleepsSinceLaunch"] as? [String: Any])
        #expect(Set(sleeps.keys) == ["count", "reasons"])
        #expect(sleeps["count"] as? Int == 0)
        let reasons = try #require(sleeps["reasons"] as? [String: [String: Any]])
        #expect(Set(reasons.keys) == Set(FeedbackDiagnostics.SleepReason.allCases.map(\.rawValue)))
        #expect(reasons.values.allSatisfy { Set($0.keys) == ["count"] && $0["count"] as? Int == 0 })
        let reloads = try #require(memory["reloadsSinceLaunch"] as? [String: Any])
        #expect(Set(reloads.keys) == ["count"] && reloads["count"] as? Int == 0)
    }

    @Test func missingMemoryReadingsAreNotReportedAsZero() {
        let log = FeedbackDiagnostics(clock: { 100 })
        var memory = FeedbackDiagnostics.Memory()
        let waiting = log.memoryFields(memory)
        #expect(waiting["sampled"] as? Bool == false)
        #expect(waiting["yabFootprintBytes"] == nil && waiting["webProcessCount"] == nil)
        memory.sample = MemoryCeiling.Sample(at: 99, yabFootprintBytes: nil, webProcessCount: nil, footprints: [])
        let unavailable = log.memoryFields(memory)
        #expect(unavailable["sampled"] as? Bool == true)
        #expect(unavailable["yabFootprintBytes"] == nil && unavailable["webProcessCount"] == nil)
        #expect(unavailable["measuredWebProcessCount"] as? Int == 0)
        #expect(unavailable["largestWebProcessFootprintsBytes"] as? [UInt64] == [])
        memory.sample = MemoryCeiling.Sample(at: 99, yabFootprintBytes: 10, webProcessCount: 0, footprints: [])
        #expect(log.memoryFields(memory)["webProcessCount"] as? Int == 0)
        memory.sample = MemoryCeiling.Sample(at: 99, yabFootprintBytes: 10, webProcessCount: 1, footprints: [20])
        #expect(log.memoryFields(memory)["largestWebProcessFootprintsBytes"] as? [UInt64] == [20])
    }

    @Test func launchCountsAndLastReasonsOutliveTheEventBuffer() throws {
        var now: TimeInterval = 10
        let log = FeedbackDiagnostics(clock: { now })
        for reason in FeedbackDiagnostics.SleepReason.allCases { log.slept(reason) }
        log.record(.webProcessTerminated, reason: .crash)
        let ended = try #require(log.memoryFields(.init())["reloadsSinceLaunch"] as? [String: Any])
        #expect(ended["count"] as? Int == 0, "An ended process has not necessarily been reloaded")
        log.reloadedAfterTermination(reason: .crash)
        now = 20
        log.slept(.idle)
        log.reloadedAfterTermination(reason: .memory)
        for _ in 0..<250 { log.record(.tabClosed) }
        now = 400
        #expect(log.events().isEmpty)
        let memory = log.memoryFields(.init())
        let sleeps = try #require(memory["sleepsSinceLaunch"] as? [String: Any])
        #expect(sleeps["count"] as? Int == FeedbackDiagnostics.SleepReason.allCases.count + 1)
        #expect(sleeps["lastReason"] as? String == "idle")
        #expect(sleeps["lastAgeSeconds"] as? Int == 380)
        let reasons = try #require(sleeps["reasons"] as? [String: [String: Any]])
        for reason in FeedbackDiagnostics.SleepReason.allCases {
            #expect(reasons[reason.rawValue]?["count"] as? Int == (reason == .idle ? 2 : 1))
            #expect(reasons[reason.rawValue]?["lastAgeSeconds"] as? Int == (reason == .idle ? 380 : 390))
        }
        let reloads = try #require(memory["reloadsSinceLaunch"] as? [String: Any])
        #expect(reloads["count"] as? Int == 2)
        #expect(reloads["lastAgeSeconds"] as? Int == 380)
        #expect(reloads["kind"] as? String == "webProcessTerminated")
        #expect(reloads["lastReason"] as? String == "memory")
        log.reloadedAfterTermination(reason: nil)
        let unknown = try #require(log.memoryFields(.init())["reloadsSinceLaunch"] as? [String: Any])
        #expect(unknown["lastReason"] as? String == "unknown")
    }

    @Test func onlyAnAwakeTabThatActuallySleepsIsCounted() throws {
        _ = NSApplication.shared
        let log = FeedbackDiagnostics.shared
        func count() throws -> Int {
            let sleeps = try #require(log.memoryFields(.init())["sleepsSinceLaunch"] as? [String: Any])
            let reasons = try #require(sleeps["reasons"] as? [String: [String: Any]])
            return try #require(reasons["heavyPage"]?["count"] as? Int)
        }
        let before = try count()
        let tab = Tab(), privateTab = Tab(shy: true)
        defer { tab.close(); privateTab.close() }
        tab.sleep(picture: nil, reason: .heavyPage)
        #expect(try count() == before, "No built page or address means nothing slept")
        tab.setAddressOptimistically(URL(string: "about:blank#diagnostics")!)
        _ = tab.page
        tab.sleep(picture: nil, reason: .heavyPage)
        #expect(tab.asleep && tab.builtPage == nil)
        #expect(try count() == before + 1)
        tab.sleep(picture: nil, reason: .heavyPage)
        #expect(try count() == before + 1, "An already sleeping tab is not counted again")
        privateTab.setAddressOptimistically(URL(string: "about:blank#private")!)
        _ = privateTab.page
        privateTab.sleep(picture: nil, reason: .heavyPage)
        #expect(privateTab.asleep)
        #expect(try count() == before + 1, "Private tabs follow the existing diagnostics exclusion")
    }

    @Test func recoveryCountsTheReloadRatherThanTheTerminationEvent() throws {
        _ = NSApplication.shared
        let log = FeedbackDiagnostics.shared
        func count() throws -> Int {
            let reloads = try #require(log.memoryFields(.init())["reloadsSinceLaunch"] as? [String: Any])
            return try #require(reloads["count"] as? Int)
        }
        let before = try count()
        let tab = Tab()
        defer { tab.close() }
        tab.recoverFromCrash()
        #expect(try count() == before, "No address means no recovery load")
        tab.setAddressOptimistically(URL(string: "about:blank#recovery")!)
        _ = tab.page
        tab.staleReason = .memory
        tab.stale = true
        #expect(try count() == before, "A background page waits until it is revisited")
        tab.revive()
        #expect(!tab.stale && tab.staleReason == nil)
        #expect(try count() == before + 1)
        let reloads = try #require(log.memoryFields(.init())["reloadsSinceLaunch"] as? [String: Any])
        #expect(reloads["lastReason"] as? String == "memory")
    }

    @Test func providerFailureKeepsOnlyTheActualRunnerAndHttpStatus() throws {
        let log = FeedbackDiagnostics(clock: { 10 })
        log.providerFailure(cli: "codex", status: 401)
        log.providerFailure(cli: "claude", status: nil)
        log.providerFailure(cli: "cursor", status: 403)
        log.providerFailure(cli: "gemini", status: 429)
        log.providerFailure(cli: "https://private.test/?token=secret", status: 401)
        #expect(log.events().map(\.kind) == [.codexRequestFailed, .claudeRequestFailed, .cursorRequestFailed, .geminiRequestFailed])
        #expect(log.events().map(\.code) == [401, nil, 403, 429])
        #expect(log.events().allSatisfy { $0.domain == nil && $0.extensionID == nil && $0.reason == nil })
        let text = String(decoding: try JSONEncoder().encode(log.events()), as: UTF8.self)
        #expect(!text.contains("private.test") && !text.contains("token") && !text.contains("secret"))
    }

    @Test func onePasswordReportsSayWhatItsAppToldYab() {
        let store = "aeblfdkhhhdcdjpifhhbdiojplfjncoa", beta = "khgocmkkpikpnmmkgmdnfckapcdkgfaf"
        #expect(FeedbackDiagnostics.appLink(store, refused: [store], answered: [], appHere: true) == "refused")
        #expect(FeedbackDiagnostics.appLink(beta, refused: [], answered: [beta], appHere: true) == "answered")
        #expect(FeedbackDiagnostics.appLink(store, refused: [], answered: [], appHere: true) == "silent")
        #expect(FeedbackDiagnostics.appLink(store, refused: [], answered: [], appHere: false) == "noApp")
        // Bitwarden, NordPass and the rest carry no such field.
        #expect(FeedbackDiagnostics.appLink("nngceckbapebfimnlniiiahkandclblb", refused: [], answered: [], appHere: true) == nil)
    }

    @Test func providerFailureDoesNotInventAnHttpStatus() {
        let log = FeedbackDiagnostics(clock: { 10 })
        for code in [0, 200, 399, 600, 999] { log.providerFailure(cli: "codex", status: code) }
        #expect(log.events().count == 5)
        #expect(log.events().allSatisfy { $0.code == nil })
    }

    @Test func anOlderSiteCanStillReceiveTheOtherDiagnostics() {
        let log = FeedbackDiagnostics(clock: { 10 })
        log.record(.tabClosed)
        log.providerFailure(cli: "codex", status: 401)
        let tries = log.snapshots(stallLog: "")
        #expect(tries.count == 2)
        #expect(tries.first?.contains("codexRequestFailed") == true)
        #expect(tries.last?.contains("codexRequestFailed") == false)
        #expect(tries.last?.contains("tabClosed") == true)
    }

    @Test func bufferExpiresAndStaysBounded() throws {
        var now: TimeInterval = 0
        let log = FeedbackDiagnostics(clock: { now })
        for _ in 0..<250 { log.record(.tabClosed) }
        #expect(log.events().count == 200)
        now = 300
        #expect(log.events().count == 200)
        now = 301
        #expect(log.events().isEmpty)
    }

    @Test func errorsCannotIncludeMessagesDomainsOrLocalExtensionPaths() throws {
        let log = FeedbackDiagnostics(clock: { 10 })
        log.record(.navigationFailed, error: NSError(domain: "secret-domain", code: 42,
            userInfo: [NSLocalizedDescriptionKey: "secret password", NSURLErrorKey: "https://private.test"]),
            extensionID: "/Users/secret/extension")
        let data = try JSONEncoder().encode(log.events())
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("secret"))
        #expect(!text.contains("private.test"))
        #expect(log.events().first?.domain == "other")
        #expect(log.events().first?.code == 42)
        #expect(log.events().first?.extensionID == nil)
    }

    @Test func importFailuresCarryOnlyTheirCode() throws {
        let log = FeedbackDiagnostics(clock: { 10 })
        let troubles: [TabImport.Trouble] = [.missing, .damaged, .unreadable, .newer(version: 4)]
        troubles.forEach { log.record(.importFailed, code: $0.code) }
        #expect(log.events().map(\.code) == [1, 2, 3, 1004])
        #expect(log.events().allSatisfy { $0.kind == .importFailed && $0.domain == nil && $0.extensionID == nil })
        let text = String(decoding: try JSONEncoder().encode(log.events()), as: UTF8.self)
        #expect(text.contains("\"importFailed\""))
    }

    /// A site that doesn't know importFailed yet turns the diagnostics
    /// down: they go again without it, the stalls and the rest still in.
    @Test func aSiteThatDoesntKnowANewerEventStillGetsTheRest() {
        let log = FeedbackDiagnostics(clock: { 10 })
        log.record(.navigationFailed, error: URLError(.timedOut))
        #expect(log.snapshots(stallLog: "").count == 1)
        log.record(.importFailed, code: TabImport.Trouble.unreadable.code)
        let tries = log.snapshots(stallLog: "")
        #expect(tries.count == 2)
        #expect(tries.first.map { $0.contains("\"importFailed\"") && $0.contains("\"navigationFailed\"") } == true)
        #expect(tries.last.map { !$0.contains("\"importFailed\"") && $0.contains("\"navigationFailed\"") } == true)
    }

    /// What the page in front says about its scale and canvases (#134):
    /// numbers only, in bounds, at most four canvases of four numbers.
    @Test func thePageSaysOnlyNumbers() throws {
        let said = """
        {"dpr": 2, "innerWidth": 1280, "outerWidth": 1280, "canvasCount": 9, "href": "https://docs.google.com/secret",
         "canvases": [[816.4, 1056, 816, 1056], [600, 400, 1200, 800], [1, 2, "x", 4], [10, 10, 10, 10], [5, 5, 5, 5], [4, 4, 4, 4]]}
        """
        let fields = FeedbackDiagnostics.pageFields(said)
        #expect(fields["dpr"] as? Double == 2)
        #expect(fields["innerWidth"] as? Int == 1280)
        #expect(fields["canvasCount"] as? Int == 9)
        #expect(fields["href"] == nil)
        #expect(fields["canvases"] as? [[Int]] == [[816, 1056, 816, 1056], [600, 400, 1200, 800], [10, 10, 10, 10]])
        #expect(FeedbackDiagnostics.pageFields("{\"dpr\": 1e9, \"innerWidth\": -4}")["dpr"] == nil)
        #expect(FeedbackDiagnostics.pageFields("{\"dpr\": 1e9, \"innerWidth\": -4}")["innerWidth"] == nil)
        #expect(FeedbackDiagnostics.pageFields("not json").isEmpty)

        let log = FeedbackDiagnostics(clock: { 10 })
        let sent = try #require(log.snapshots(stallLog: "", page: ["backing": 2.0, "dpr": 1.0]).first)
        let payload = try #require(try JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: Any])
        #expect((payload["page"] as? [String: Any])?["backing"] as? Double == 2)
        #expect(log.snapshots(stallLog: "").first.map { !$0.contains("\"page\"") } == true)
    }

    /// The tab in front is always `page`; another page that draws a canvas
    /// goes beside it as `pageBehind`, never in its place (#155).
    @Test func aPageBehindIsSentBesideTheFront() throws {
        let log = FeedbackDiagnostics(clock: { 10 })
        let sent = try #require(log.snapshots(stallLog: "", page: ["front": true, "canvasCount": 0, "woken": true],
                                              behind: ["front": false, "canvasCount": 5, "inWindow": false]).first)
        let payload = try #require(try JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: Any])
        let page = try #require(payload["page"] as? [String: Any])
        let behind = try #require(payload["pageBehind"] as? [String: Any])
        #expect(page["front"] as? Bool == true)
        #expect(page["woken"] as? Bool == true)
        #expect(behind["front"] as? Bool == false)
        #expect(behind["canvasCount"] as? Int == 5)
        let alone = try #require(log.snapshots(stallLog: "", page: ["front": true]).first)
        #expect(!alone.contains("pageBehind"))
    }

    @Test func onlyTheSitesNoToDiagnosticsSendsAgainWithout() {
        #expect(FeedbackSheet.refusesDiagnostics(Data("{\"error\":\"invalid diagnostics\"}".utf8)))
        #expect(!FeedbackSheet.refusesDiagnostics(Data("{\"error\":\"Write something first\"}".utf8)))
        #expect(!FeedbackSheet.refusesDiagnostics(Data("bad request".utf8)))
    }

    @Test func storeIDsAreStrict() {
        #expect(FeedbackDiagnostics.storeID(String(repeating: "a", count: 32)) != nil)
        #expect(FeedbackDiagnostics.storeID("local-private-name") == nil)
        #expect(FeedbackDiagnostics.storeID(String(repeating: "z", count: 32)) == nil)
    }

    @Test func watchdogExportsOnlyRecentDurations() {
        let now = Date(timeIntervalSince1970: 1000)
        let text = """
        1970-01-01T00:16:30Z  stall 1.2 s, phase /Users/secret
        1970-01-01T00:16:35Z  stalling 2.0 s so far, phase secret
        1970-01-01T00:00:00Z  stall 8.0 s, phase old
        1970-01-01T00:16:36Z  stall nan s, phase secret
            0 secret-stack
        """
        let result = FeedbackDiagnostics.stalls(text, now: now)
        #expect(result.count == 2)
        #expect(result.first?["durationMs"] as? Int == 1200)
        #expect(result.first?["ageSeconds"] as? Int == 10)
        #expect(result.allSatisfy { Set($0.keys) == ["ageSeconds", "durationMs"] })
    }

    @Test func toggleControlsTheActualRequestInBothFormats() throws {
        let site = URL(string: "https://example.test")!
        let diagnostics = "{\"schemaVersion\":1}"
        var draft = FeedbackSheet.Draft()
        draft.message = "Test"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("attachment".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        for attached in [false, true] {
            draft.files = attached ? [try #require(FeedbackFile(url: file))] : []
            for enabled in [false, true] {
                draft.includeDiagnostics = enabled
                let request = FeedbackSheet.request(draft, site: site, diagnostics: diagnostics)
                let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
                #expect(body.contains("diagnostics") == enabled)
                #expect(body.contains("schemaVersion") == enabled)
                #expect(body.contains("Test"))
                if attached { #expect(body.contains("attachment")) }
            }
        }
    }

    @Test func captureDiagnosticForm() async throws {
        guard let path = ProcessInfo.processInfo.environment["YAB_DIAGNOSTICS_SHOT"] else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 720),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 720))
        window.makeKeyAndOrderFront(nil)
        FeedbackSheet.show(on: window)
        defer { FeedbackSheet.dismiss(); window.close() }
        try await Task.sleep(for: .milliseconds(700))
        let view = try #require(window.childWindows?.last?.contentView)
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
}
