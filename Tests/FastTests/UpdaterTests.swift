import XCTest
@testable import YabUpdate
@testable import Fast

/// The appcast as the site writes it, the rollout's turn on a fixed number
/// and clock, and why an update failed said once with the next check.
@MainActor
final class UpdaterTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        super.setUp()
        suite = "UpdaterTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func appcast(_ extra: [String: Any] = [:]) -> Data {
        var json: [String: Any] = [
            "version": "0.0.9", "build": 202610060900,
            "url": "https://blob.example/yab-0.0.9.zip", "dmg": "https://blob.example/yab-0.0.9.dmg",
            "sha256": " ABCDEF ", "notes": "Fixes", "changelog": "https://yetanotherbrowser.com/changelog/0.0.9",
            "minimumSystemVersion": "15.4",
        ]
        json.merge(extra) { $1 }
        return try! JSONSerialization.data(withJSONObject: json)
    }

    private func at(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    // MARK: - the file

    func testCriticalAndRolloutAreRead() throws {
        let release = try XCTUnwrap(Updater.parse(appcast([
            "critical": true, "rolloutHours": 48, "published": "2026-10-05T10:00:00.123Z",
        ]), allowingHTTP: false))
        XCTAssertTrue(release.critical)
        XCTAssertEqual(release.rolloutHours, 48)
        XCTAssertEqual(try XCTUnwrap(release.published).timeIntervalSince(at("2026-10-05T10:00:00Z")), 0.123, accuracy: 0.001)
        XCTAssertEqual(release.build, 202610060900)
        XCTAssertEqual(release.sha256, "abcdef")
        // Without milliseconds too, as a hand-written file has it.
        XCTAssertEqual(Updater.parse(appcast(["published": "2026-10-05T10:00:00Z"]), allowingHTTP: false)?.published,
                       at("2026-10-05T10:00:00Z"))
    }

    /// Captured from the public Nightly appcast on 2026-11-03. The site
    /// exposes camelCase rolloutHours; rollout_hours is a database column.
    func testPublished0467FeedCanReplace0466() throws {
        let data = Data(#"""
        {"version":"0.46.7","build":202611030445,
         "url":"https://8hauzhgbhxiipn9a.public.blob.vercel-storage.com/releases/yab-0.46.7-202611030445.zip",
         "dmg":"https://8hauzhgbhxiipn9a.public.blob.vercel-storage.com/releases/yab-0.46.7-202611030445.dmg",
         "sha256":"7d4bab38a44bb4a79ebff34c210a7602df73376a951d8d8ac8467f5fa0cc75ec",
         "arch":"universal","minimumSystemVersion":"15.4","critical":false,
         "published":"2026-11-03T15:15:41.470Z"}
        """#.utf8)
        let release = try XCTUnwrap(Updater.parse(data, allowingHTTP: false, architecture: "arm64"))
        XCTAssertTrue(release.isUpdate(from: "0.46.6", build: 202611030107, asked: true))
        XCTAssertEqual(release.rolloutHours, 0)
        XCTAssertNotNil(release.published)
        XCTAssertEqual(release.sha256, "7d4bab38a44bb4a79ebff34c210a7602df73376a951d8d8ac8467f5fa0cc75ec")
        XCTAssertNil(Updater.Settle.wait(release, dice: 0.99, since: at("2026-11-03T15:00:00Z"),
                                        now: at("2026-11-03T16:00:00Z"), asked: false, nightly: true))
    }

    func testOlderEligibleFeedCannotDowngradeANightlyCopy() throws {
        // Held releases do not appear in the server response. Stable, or
        // Nightly when its newest build is held, can name an older release.
        let release = try XCTUnwrap(Updater.parse(appcast([
            "version": "0.45.2", "build": 202611011012, "rolloutHours": 4,
            "published": "2026-11-03T00:12:31.192Z",
        ]), allowingHTTP: false))
        XCTAssertEqual(release.rolloutHours, 4)
        XCTAssertFalse(release.isUpdate(from: "0.46.6", build: 202611030107, asked: true))
        XCTAssertFalse(release.isUpdate(from: "0.46.6", build: 202611030107, asked: false))
    }

    func testExplicitChannelSelectionAcceptsOnlyTheSelectedOlderBuild() throws {
        let stable = 202611011012, nightly = 202611040850
        XCTAssertThrowsError(try Swap.checkBuild(stable, current: nightly, selected: stable))
        XCTAssertNoThrow(try Swap.checkBuild(stable, current: nightly, selected: stable, allowDowngrade: true))
        XCTAssertThrowsError(try Swap.checkBuild(nightly, current: nightly, selected: stable, allowDowngrade: true))
        XCTAssertThrowsError(try Swap.checkBuild(0, current: nightly, selected: 0, allowDowngrade: true))
        XCTAssertThrowsError(try Swap.checkBuild(nightly, current: nightly, selected: nightly, allowDowngrade: true))
        // A downloaded Nightly waiting for restart must also yield to Stable.
        XCTAssertNoThrow(try Swap.checkBuild(stable, current: nightly, staged: nightly + 1,
                                           selected: stable, allowDowngrade: true))
        XCTAssertThrowsError(try Swap.checkBuild(stable, current: nightly, staged: nightly + 1, selected: stable))
        XCTAssertNoThrow(try Swap.checkBuild(nightly + 2, current: nightly, staged: nightly + 1, selected: nightly + 2))
    }

    func testAPlainFileIsAPlainRelease() throws {
        let release = try XCTUnwrap(Updater.parse(appcast(), allowingHTTP: false))
        XCTAssertFalse(release.critical)
        XCTAssertEqual(release.rolloutHours, 0)
        XCTAssertNil(release.published)
        // What the site wrote before rollouts: critical false, nothing else.
        XCTAssertEqual(Updater.parse(appcast(["critical": false]), allowingHTTP: false), release)
    }

    func testNonsenseInTheNewFieldsIsNone() throws {
        let cases: [(Any, Any)] = [(NSNull(), -5), ("yes", "48"), (NSNull(), NSNull())]
        for (critical, hours) in cases {
            let release = try XCTUnwrap(Updater.parse(appcast(["critical": critical, "rolloutHours": hours,
                                                                "published": "yesterday"]), allowingHTTP: false))
            XCTAssertFalse(release.critical)
            XCTAssertEqual(release.rolloutHours, 0)
            XCTAssertNil(release.published)
        }
        XCTAssertEqual(Updater.parse(appcast(["rolloutHours": 1e9]), allowingHTTP: false)?.rolloutHours, 24 * 30)
    }

    func testPlainHTTPOnlyForATestFeed() {
        let http = appcast(["url": "http://localhost:8080/yab.zip"])
        XCTAssertNil(Updater.parse(http, allowingHTTP: false))
        XCTAssertNotNil(Updater.parse(http, allowingHTTP: true))
        XCTAssertNil(Updater.parse(Data("{}".utf8), allowingHTTP: true))
        XCTAssertNil(Updater.parse(Data("not json".utf8), allowingHTTP: true))
    }

    // MARK: - what is an update

    /// Since 2026-10-24 every release is the next minor, and a newer build
    /// is an update whatever its version, its age or the channel says.
    /// When a copy takes it is Settle's (below).
    func testANewerBuildIsAnUpdateWhateverItsVersion() throws {
        let now = Date()
        let hourOld = ISO8601DateFormatter().string(from: now.addingTimeInterval(-3600))
        for (version, current) in [("0.0.20", "0.0.20"), ("0.32.2", "0.32.1"), ("0.31.1", "0.0.31"),
                                   ("0.41.0", "0.40.0"), ("0.40.0", "0.39.1")] {
            let found = try XCTUnwrap(Updater.parse(appcast(["version": version, "build": 200, "published": hourOld]),
                                                    allowingHTTP: false))
            for asked in [false, true] {
                XCTAssertTrue(found.isUpdate(from: current, build: 100, asked: asked, now: now), "\(version) over \(current)")
            }
            var undated = found
            undated.published = nil
            XCTAssertTrue(undated.isUpdate(from: current, build: 100, asked: false, now: now))
            var critical = found
            critical.critical = true
            XCTAssertTrue(critical.isUpdate(from: current, build: 100, asked: false, now: now))
        }
    }

    func testOnlyAnOlderBuildThatRunsHereIsBehind() throws {
        let stable = try XCTUnwrap(Updater.parse(appcast(["version": "0.45.1", "build": 100]), allowingHTTP: false))
        XCTAssertTrue(stable.isBehind(build: 101))
        XCTAssertFalse(stable.isBehind(build: 100))
        XCTAssertFalse(stable.isBehind(build: 99))
        let later = try XCTUnwrap(Updater.parse(appcast(["version": "0.45.1", "build": 100, "minimumSystemVersion": "99.0"]),
                                                allowingHTTP: false))
        XCTAssertFalse(later.isBehind(build: 101))
    }

    func testCheckNowAndCriticalStillRequireANewerBuild() throws {
        for critical in [false, true] {
            let found = try XCTUnwrap(Updater.parse(appcast(["version": "0.0.20", "build": 200, "critical": critical]),
                                                    allowingHTTP: false))
            for asked in [false, true] {
                XCTAssertFalse(found.isUpdate(from: "0.0.20", build: 200, asked: asked))
                XCTAssertFalse(found.isUpdate(from: "0.0.20", build: 300, asked: asked))
            }
        }
    }

    // MARK: - the rollout

    private func release(critical: Bool = false, hours: Double = 10, published: Date? = nil) -> Updater.Release {
        var release = Updater.parse(appcast(), allowingHTTP: false)!
        release.critical = critical
        release.rolloutHours = hours
        release.published = published ?? at("2026-10-05T10:00:00Z")
        return release
    }

    func testAMacTakesItOnItsTurn() {
        let out = at("2026-10-05T10:00:00Z")
        let spread = release()
        XCTAssertEqual(Updater.Rollout.turn(spread, dice: 0.3), at("2026-10-05T13:00:00Z"))
        XCTAssertFalse(Updater.Rollout.due(spread, dice: 0.3, now: at("2026-10-05T12:59:59Z"), asked: false))
        XCTAssertTrue(Updater.Rollout.due(spread, dice: 0.3, now: at("2026-10-05T13:00:00Z"), asked: false))
        // Dice 0 at once, dice near 1 at the end.
        XCTAssertTrue(Updater.Rollout.due(spread, dice: 0, now: out, asked: false))
        XCTAssertFalse(Updater.Rollout.due(spread, dice: 0.999, now: at("2026-10-05T19:59:00Z"), asked: false))
        XCTAssertTrue(Updater.Rollout.due(spread, dice: 0.999, now: at("2026-10-05T20:00:00Z"), asked: false))
    }

    func testCheckNowAndCriticalNeverWait() {
        let early = at("2026-10-05T10:01:00Z")
        XCTAssertTrue(Updater.Rollout.due(release(), dice: 0.9, now: early, asked: true))
        XCTAssertTrue(Updater.Rollout.due(release(critical: true), dice: 0.9, now: early, asked: false))
        XCTAssertNil(Updater.Rollout.turn(release(critical: true), dice: 0.9))
        // No rollout, or no time it came out: everyone at once.
        XCTAssertTrue(Updater.Rollout.due(release(hours: 0), dice: 0.9, now: early, asked: false))
        var undated = release()
        undated.published = nil
        XCTAssertTrue(Updater.Rollout.due(undated, dice: 0.9, now: early, asked: false))
    }

    func testTheNumberIsRolledOnceAndKept() {
        let first = Updater.Rollout.dice(in: defaults)
        XCTAssertGreaterThanOrEqual(first, 0)
        XCTAssertLessThan(first, 1)
        XCTAssertEqual(Updater.Rollout.dice(in: defaults), first)
        XCTAssertEqual(defaults.double(forKey: Updater.Rollout.key), first)
        // Out of range is rolled again.
        defaults.set(4.2, forKey: Updater.Rollout.key)
        XCTAssertLessThan(Updater.Rollout.dice(in: defaults), 1)
    }

    /// The number stays on the Mac: no check carries it.
    func testACheckCarriesBuildMacOSAndAFailureOnly() throws {
        let feed = URL(string: "https://yetanotherbrowser.com/appcast.json?channel=beta")!
        defaults.set(0.42, forKey: Updater.Rollout.key)
        let plain = URLComponents(url: Updater.checkURL(feed: feed, build: 7, system: "15.4", failure: nil),
                                  resolvingAgainstBaseURL: false)!
        XCTAssertEqual(plain.queryItems, [
            URLQueryItem(name: "channel", value: "beta"), URLQueryItem(name: "b", value: "7"),
            URLQueryItem(name: "os", value: "15.4"),
        ])
        let failed = URLComponents(url: Updater.checkURL(feed: feed, build: 7, system: "15.4", failure: "hash"),
                                   resolvingAgainstBaseURL: false)!
        XCTAssertEqual(failed.queryItems?.map(\.name), ["channel", "b", "os", "fail"])
        XCTAssertEqual(failed.queryItems?.last?.value, "hash")
        XCTAssertFalse(failed.url!.absoluteString.contains("0.42"))
    }

    // MARK: - a day between updates on Stable

    func testTheDayCountsFromTheFirstLaunchOfABuild() {
        let updated = at("2026-10-05T09:00:00Z")
        XCTAssertEqual(Updater.Settle.since(build: 200, in: defaults, now: updated), updated)
        // Kept while the same build runs, started again by the next one.
        XCTAssertEqual(Updater.Settle.since(build: 200, in: defaults, now: at("2026-10-05T15:00:00Z")), updated)
        let next = at("2026-10-06T10:00:00Z")
        XCTAssertEqual(Updater.Settle.since(build: 201, in: defaults, now: next), next)
        // A first launch kept in the future (a clock set back) is now.
        defaults.set(at("2026-10-09T00:00:00Z"), forKey: Updater.Settle.key)
        XCTAssertEqual(Updater.Settle.since(build: 201, in: defaults, now: next), next)
    }

    func testTheDayCountsFromTheSwapWhenThisMacMadeIt() {
        // The swap at 09:00, the new build first opened at 18:00: the day
        // runs from 09:00.
        let swapped = at("2026-10-05T09:00:00Z")
        Updater.Settle.installed(build: 300, in: defaults, now: swapped)
        XCTAssertEqual(defaults.integer(forKey: Updater.Settle.installedBuildKey), 300)
        XCTAssertEqual(defaults.object(forKey: Updater.Settle.installedKey) as? Date, swapped)
        let opened = at("2026-10-05T18:00:00Z")
        XCTAssertEqual(Updater.Settle.since(build: 300, in: defaults, now: opened), swapped)
        // The old build still running before its restart doesn't clobber it.
        XCTAssertEqual(Updater.Settle.since(build: 299, in: defaults, now: at("2026-10-05T10:00:00Z")),
                       at("2026-10-05T10:00:00Z"))
        XCTAssertEqual(Updater.Settle.since(build: 300, in: defaults, now: opened), swapped)
        // A build this Mac didn't swap in (a DMG put over it): its first launch.
        XCTAssertEqual(Updater.Settle.since(build: 301, in: defaults, now: at("2026-10-07T08:00:00Z")),
                       at("2026-10-07T08:00:00Z"))
    }

    func testStableWaitsADayAfterTheLastUpdate() {
        let updated = at("2026-10-05T09:00:00Z")
        let plain = release(hours: 0)
        XCTAssertEqual(Updater.Settle.wait(plain, dice: 0.5, since: updated, now: at("2026-10-05T20:00:00Z"),
                                           asked: false, nightly: false), at("2026-10-06T09:00:00Z"))
        XCTAssertNil(Updater.Settle.wait(plain, dice: 0.5, since: updated, now: at("2026-10-06T09:00:00Z"),
                                         asked: false, nightly: false))
        // The later of the two: the rollout's turn, or the day.
        let spread = release(hours: 48)
        XCTAssertEqual(Updater.Settle.wait(spread, dice: 0.9, since: updated, now: updated, asked: false, nightly: false),
                       at("2026-10-07T05:12:00Z"))
        XCTAssertEqual(Updater.Settle.wait(spread, dice: 0, since: updated, now: updated, asked: false, nightly: false),
                       at("2026-10-06T09:00:00Z"))
    }

    func testCheckNowAndCriticalNeverWaitForTheDay() {
        let updated = at("2026-10-05T09:00:00Z")
        for nightly in [false, true] {
            XCTAssertNil(Updater.Settle.wait(release(hours: 48), dice: 0.9, since: updated, now: updated,
                                             asked: true, nightly: nightly))
            XCTAssertNil(Updater.Settle.wait(release(critical: true, hours: 48), dice: 0.9, since: updated, now: updated,
                                             asked: false, nightly: nightly))
        }
    }

    func testNightlyTakesEveryBuildOnItsTurn() {
        let updated = at("2026-10-05T09:00:00Z")
        // An hour after the last update: no day to wait out on Nightly.
        let soon = at("2026-10-05T10:00:00Z")
        XCTAssertNil(Updater.Settle.wait(release(hours: 0), dice: 0.9, since: updated, now: soon, asked: false, nightly: true))
        // The rollout dice still count: dice 0.5 of 10 hours from 10:00 is 15:00.
        let spread = release(hours: 10)
        XCTAssertEqual(Updater.Settle.wait(spread, dice: 0.5, since: updated, now: soon, asked: false, nightly: true),
                       at("2026-10-05T15:00:00Z"))
        XCTAssertNil(Updater.Settle.wait(spread, dice: 0.5, since: updated, now: at("2026-10-05T15:00:00Z"),
                                         asked: false, nightly: true))
    }

    // MARK: - when to look again

    func testAnHourOrSoonerWhenSomethingWaits() {
        let now = at("2026-10-05T12:00:00Z")
        XCTAssertTrue(Updater.due(now: now, in: defaults), "never checked")
        defaults.set(now.addingTimeInterval(-50 * 60), forKey: Updater.checkedKey)
        XCTAssertFalse(Updater.due(now: now, in: defaults))
        defaults.set(now.addingTimeInterval(60), forKey: Updater.soonerKey)
        XCTAssertFalse(Updater.due(now: now, in: defaults))
        defaults.set(now, forKey: Updater.soonerKey)
        XCTAssertTrue(Updater.due(now: now, in: defaults))
        defaults.removeObject(forKey: Updater.soonerKey)
        // The ten-minute tick finds the hour up at the latest ten minutes on.
        defaults.set(now.addingTimeInterval(-61 * 60), forKey: Updater.checkedKey)
        XCTAssertTrue(Updater.due(now: now, in: defaults))
    }

    // MARK: - counted once a day

    /// Checks every hour, counted once a UTC day, the site's: the first
    /// check of the day is plain, the rest say `again`.
    func testACopyIsCountedOnceADay() {
        let feed = URL(string: "https://yetanotherbrowser.com/appcast.json")!
        let morning = at("2026-10-09T00:30:00Z"), later = at("2026-10-09T23:30:00Z"), next = at("2026-10-10T00:10:00Z")
        XCTAssertFalse(Updater.Count.again(in: defaults, now: morning), "never counted")
        Updater.Count.counted(in: defaults, now: morning)
        XCTAssertTrue(Updater.Count.again(in: defaults, now: later))
        XCTAssertFalse(Updater.Count.again(in: defaults, now: next))
        XCTAssertEqual(Updater.Count.day(next), "2026-10-10")
        let again = URLComponents(url: Updater.checkURL(feed: feed, build: 7, system: "26.0", failure: "hash", again: true),
                                  resolvingAgainstBaseURL: false)!
        XCTAssertEqual(again.queryItems?.map(\.name), ["b", "os", "fail", "again"])
        XCTAssertEqual(again.queryItems?.last?.value, "1")
        XCTAssertFalse(Updater.checkURL(feed: feed, build: 7, system: "26.0", failure: nil).absoluteString.contains("again"))
    }

    /// Nightly asks the site's nightly channel by name; stable asks with
    /// nothing, the site's default, as every copy before the switch did.
    func testNightlyAsksItsChannel() {
        let feed = URL(string: "https://example.com/appcast.json")!
        let nightly = URLComponents(url: Updater.checkURL(feed: feed, build: 7, system: "26.0", failure: nil, nightly: true),
                                    resolvingAgainstBaseURL: false)!
        XCTAssertEqual(nightly.queryItems?.first { $0.name == "channel" }?.value, "nightly")
        XCTAssertFalse(Updater.checkURL(feed: feed, build: 7, system: "26.0", failure: nil).absoluteString.contains("channel"))
    }

    // MARK: - which Mac asks (arm64 first, docs/release.md "Intel Macs")

    /// A check says which Mac it is when it knows, after the build and macOS
    /// it always carries; one that doesn't say (a copy from before) sends
    /// nothing, which the site answers with a universal archive.
    func testACheckSaysItsArchitectureWhenItKnows() {
        let feed = URL(string: "https://example.com/appcast.json")!
        let arm = URLComponents(url: Updater.checkURL(feed: feed, build: 7, system: "26.0", failure: "hash", again: true,
                                                      nightly: true, arch: "arm64"),
                                resolvingAgainstBaseURL: false)!
        XCTAssertEqual(arm.queryItems?.map(\.name), ["b", "os", "arch", "fail", "again", "channel"])
        XCTAssertEqual(arm.queryItems?.first { $0.name == "arch" }?.value, "arm64")
        let intel = Updater.checkURL(feed: feed, build: 7, system: "15.5", failure: nil, arch: "x86_64")
        XCTAssertEqual(URLComponents(url: intel, resolvingAgainstBaseURL: false)?.queryItems?.last,
                       URLQueryItem(name: "arch", value: "x86_64"))
        XCTAssertFalse(Updater.checkURL(feed: feed, build: 7, system: "26.0", failure: nil).absoluteString.contains("arch"))
    }

    /// The running process is what says it: the slice of the build that runs.
    func testTheArchitectureIsTheRunningSlice() {
        #if arch(arm64)
        XCTAssertEqual(Update.arch, "arm64")
        #elseif arch(x86_64)
        XCTAssertEqual(Update.arch, "x86_64")
        #endif
    }

    /// The site names an arm64-only archive to a check that said arm64 only.
    /// Told otherwise, Intel has no release rather than an update that cannot
    /// open; a universal archive suits every Mac; a reader that does not say
    /// its architecture reads the file as before.
    func testAnArm64OnlyArchiveIsNeverTakenByAnotherMac() throws {
        let armOnly = appcast(["arch": "arm64", "url": "https://blob.example/yab-0.0.9-arm64.zip"])
        XCTAssertEqual(Updater.parse(armOnly, allowingHTTP: false, architecture: "arm64")?.archive.lastPathComponent,
                       "yab-0.0.9-arm64.zip")
        XCTAssertNil(Updater.parse(armOnly, allowingHTTP: false, architecture: "x86_64"))
        XCTAssertNotNil(Updater.parse(armOnly, allowingHTTP: false))
        let universal = appcast(["arch": "universal"])
        for architecture in ["arm64", "x86_64"] {
            XCTAssertNotNil(Updater.parse(universal, allowingHTTP: false, architecture: architecture), architecture)
        }
        // A file from before the site said anything about it.
        XCTAssertNotNil(Updater.parse(appcast(), allowingHTTP: false, architecture: "x86_64"))
    }

    // MARK: - a critical build restarts Yab when nobody is using it

    func testACriticalRestartWaitsForNobodyUsingYab() {
        let after = Updater.Away.after
        XCTAssertEqual(after, 10 * 60)
        // In front and in use.
        XCTAssertFalse(Updater.Away.quiet(idle: 5, behind: nil, busy: false))
        // Behind another app long enough, the person busy elsewhere.
        XCTAssertTrue(Updater.Away.quiet(idle: 5, behind: after, busy: false))
        XCTAssertFalse(Updater.Away.quiet(idle: 5, behind: after - 1, busy: false))
        // In front, the Mac left alone.
        XCTAssertTrue(Updater.Away.quiet(idle: after, behind: nil, busy: false))
        // Sound, a call, an agent, a download or a question holds it.
        XCTAssertFalse(Updater.Away.quiet(idle: after * 6, behind: after * 6, busy: true))
    }

    // MARK: - any build restarts Yab when nobody is at the Mac (Arc's way)

    private func restarts(critical: Bool = false, automatic: Bool = true, idle: TimeInterval = 0,
                          behind: TimeInterval? = nil, unattended: TimeInterval? = nil, holding: String? = nil) -> Bool {
        Updater.Away.restarts(critical: critical, automatic: automatic, idle: idle, behind: behind,
                              unattended: unattended, holding: holding)
    }

    func testAPlainBuildRestartsOnlyWhenNobodyIsAtTheMac() {
        let idle = Updater.Away.idle, unattended = Updater.Away.unattended
        XCTAssertEqual(idle, 30 * 60)
        XCTAssertEqual(unattended, 5 * 60)
        // In use.
        XCTAssertFalse(restarts(idle: 5))
        // Half an hour without input.
        XCTAssertTrue(restarts(idle: idle))
        XCTAssertFalse(restarts(idle: idle - 1))
        // Locked, the screen saver on or the display asleep for five minutes.
        XCTAssertTrue(restarts(idle: 5, unattended: unattended))
        XCTAssertFalse(restarts(idle: 5, unattended: unattended - 1))
        XCTAssertFalse(restarts(idle: 5, unattended: nil))
        // Behind another app is someone at work elsewhere: a critical build
        // restarts for it, a plain one doesn't.
        XCTAssertFalse(restarts(idle: 5, behind: idle * 2))
        XCTAssertTrue(restarts(critical: true, idle: 5, behind: Updater.Away.after))
    }

    func testTurnedOffOnlyACriticalBuildRestarts() {
        XCTAssertFalse(restarts(automatic: false, idle: 8 * 60 * 60, unattended: 8 * 60 * 60))
        XCTAssertTrue(restarts(critical: true, automatic: false, idle: 8 * 60 * 60))
        XCTAssertTrue(restarts(critical: true, automatic: false, idle: 5, unattended: Updater.Away.unattended))
    }

    func testEverythingThatWouldBeLostHoldsTheRestart() {
        typealias Going = Updater.Away.Going
        XCTAssertNil(Updater.Away.holding(Going()))
        let each: [(WritableKeyPath<Going, Bool>, String)] = [
            (\.call, "call"), (\.sharing, "sharing"), (\.download, "download"), (\.sound, "sound"),
            (\.agent, "agent"), (\.question, "question"), (\.unsent, "unsent"),
            (\.privateTab, "private"), (\.dialog, "dialog"),
        ]
        for (path, word) in each {
            var going = Going()
            going[keyPath: path] = true
            let held = Updater.Away.holding(going)
            XCTAssertEqual(held, word)
            // A whole night away, locked, critical or not: still held.
            XCTAssertFalse(restarts(idle: 8 * 60 * 60, unattended: 8 * 60 * 60, holding: held), word)
            XCTAssertFalse(restarts(critical: true, idle: 8 * 60 * 60, behind: 8 * 60 * 60, holding: held), word)
        }
    }

    func testAutomaticIsOnUnlessTurnedOff() {
        let key = Updater.Away.automaticKey
        let kept = Store.settings.object(forKey: key)
        defer { Store.settings.set(kept, forKey: key) }
        Store.settings.removeObject(forKey: key)
        XCTAssertTrue(Updater.Away.automatic)
        Store.settings.set(false, forKey: key)
        XCTAssertFalse(Updater.Away.automatic)
    }

    func testACriticalFixThatFailedIsTriedWithinTheHour() {
        let now = at("2026-10-05T12:00:00Z")
        XCTAssertEqual(Updater.Failure.retry(release(critical: true), after: "download", now: now),
                       now.addingTimeInterval(60 * 60))
        XCTAssertEqual(Updater.Failure.retry(release(critical: true), after: "network", now: now),
                       now.addingTimeInterval(60 * 60))
        // What an hour won't change, and any plain release: tomorrow.
        XCTAssertNil(Updater.Failure.retry(release(critical: true), after: "readOnly", now: now))
        XCTAssertNil(Updater.Failure.retry(release(critical: true), after: "unsignedHere", now: now))
        XCTAssertNil(Updater.Failure.retry(release(), after: "download", now: now))
    }

    // MARK: - why it failed

    func testEveryReasonHasOneWord() {
        for refused in Swap.Refused.allCases {
            XCTAssertEqual(Updater.Failure.reason(refused), refused.rawValue)
            XCTAssertTrue(refused.rawValue.allSatisfy(\.isLetter), refused.rawValue)
        }
        XCTAssertEqual(Updater.Failure.reason(URLError(.timedOut)), "network")
        XCTAssertEqual(Updater.Failure.reason(CocoaError(.fileWriteNoPermission)), "files")
        XCTAssertEqual(Updater.Failure.reason(NSError(domain: "x", code: 1)), "other")
    }

    /// Alpha chat, 0.46.25: a download cut off once sent Update to the
    /// 280 MB disk image in the browser until Yab was quit. Only a Mac where
    /// no update can go in is offered the disk image; any other failure goes
    /// back to none, so Check Now and the next check try again in place.
    func testOnlyAMacThatCanNeverSwapIsSentToTheDiskImage() {
        let next = release(202611052256, version: "0.46.25")
        XCTAssertEqual(Updater.landing(next, failure: nil), .ready(next))
        XCTAssertEqual(Updater.landing(next, failure: "readOnly"), .offered(next))
        XCTAssertEqual(Updater.landing(next, failure: "unsignedHere"), .offered(next))
        let passing = Swap.Refused.allCases.map(\.rawValue).filter { !Updater.Failure.lasting.contains($0) }
            + [Updater.Failure.reason(URLError(.networkConnectionLost)),
               Updater.Failure.reason(CocoaError(.fileWriteOutOfSpace)),
               Updater.Failure.reason(NSError(domain: "x", code: 1))]
        XCTAssertTrue(passing.contains("network") && passing.contains("download") && passing.contains("move"))
        for reason in passing {
            XCTAssertEqual(Updater.landing(next, failure: reason), .none, reason)
        }
    }

    func testAFailureIsSaidOnceThenForgotten() {
        let feed = URL(string: "https://yetanotherbrowser.com/appcast.json")!
        XCTAssertNil(Updater.Failure.pending(in: defaults))
        Updater.Failure.keep(Updater.Failure.reason(Swap.Refused.hash), in: defaults)
        let sent = Updater.Failure.pending(in: defaults)
        XCTAssertEqual(sent, "hash")
        XCTAssertTrue(Updater.checkURL(feed: feed, build: 1, system: "26.0", failure: sent).absoluteString.hasSuffix("&fail=hash"))
        // The site heard it.
        Updater.Failure.delivered("hash", in: defaults)
        XCTAssertNil(Updater.Failure.pending(in: defaults))
        XCTAssertFalse(Updater.checkURL(feed: feed, build: 1, system: "26.0",
                                        failure: Updater.Failure.pending(in: defaults)).absoluteString.contains("fail"))
        // Another failure while the check was out is kept for the next one.
        Updater.Failure.keep("readOnly", in: defaults)
        Updater.Failure.delivered("hash", in: defaults)
        XCTAssertEqual(Updater.Failure.pending(in: defaults), "readOnly")
    }

    // MARK: - a newer release while one waits for its restart (register 1365)

    private func release(_ number: Int, version: String = "0.40.0", needs system: String? = nil) -> Updater.Release {
        var json: [String: Any] = ["version": version, "build": number]
        json["minimumSystemVersion"] = system ?? "15.4"
        return Updater.parse(appcast(json), allowingHTTP: false)!
    }

    func testTheNewestReleaseTakesThePlaceOfTheOneWaiting() {
        let waiting = release(202610252100, version: "0.39.0")
        XCTAssertTrue(release(202610260758).replaces(waiting))
        XCTAssertTrue(release(202610261500, version: "0.41.0").replaces(waiting))
        XCTAssertFalse(waiting.replaces(waiting))
        XCTAssertFalse(release(202610241200, version: "0.38.0").replaces(waiting))
        // Not for a newer macOS than this one.
        XCTAssertFalse(release(202610260758, needs: "99.0").replaces(waiting))
    }

    /// Bundles as the swap sees them: a folder with an Info.plist.
    private func bundle(_ url: URL, build: Int, identifier: String = "dev.test.yab") throws {
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": identifier, "CFBundleVersion": String(build)], format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
    }

    private func buildOf(_ url: URL) -> String? {
        let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        let info = data.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        return info?["CFBundleVersion"] as? String
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("UpdaterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testTheNewerBuildGoesInPlaceAndTheRunningOneIsLeftAlone() throws {
        let root = try folder()
        let place = root.appendingPathComponent("Yab.app"), running = root.appendingPathComponent("Yab.app.old")
        let scratch = root.appendingPathComponent("scratch"), fresh = scratch.appendingPathComponent("unpacked/Yab.app")
        try bundle(running, build: 202610241200)
        try bundle(place, build: 202610252100)
        try bundle(fresh, build: 202610260758)
        var registrations: [(URL, Bool)] = []
        try Swap.replace(202610252100, with: fresh, scratch: scratch, at: place, identifier: "dev.test.yab",
                         registrationChanged: { registrations.append(($0, $1)) })
        XCTAssertEqual(registrations.map { $0.0.path }, [fresh.path, scratch.appendingPathComponent("replaced.app").path, place.path])
        XCTAssertEqual(registrations.map(\.1), [true, true, false])
        XCTAssertEqual(buildOf(place), "202610260758")
        XCTAssertEqual(buildOf(running), "202610241200")
        XCTAssertEqual(buildOf(scratch.appendingPathComponent("replaced.app")), "202610252100")
    }

    func testNothingMovesWhenTheOneInPlaceIsNotTheOneSwappedIn() throws {
        let root = try folder()
        let place = root.appendingPathComponent("Yab.app")
        let scratch = root.appendingPathComponent("scratch"), fresh = scratch.appendingPathComponent("unpacked/Yab.app")
        try bundle(place, build: 202610241200)
        try bundle(fresh, build: 202610260758)
        XCTAssertThrowsError(try Swap.replace(202610252100, with: fresh, scratch: scratch, at: place, identifier: "dev.test.yab"))
        try bundle(place, build: 202610252100, identifier: "other.app")
        XCTAssertThrowsError(try Swap.replace(202610252100, with: fresh, scratch: scratch, at: place, identifier: "dev.test.yab"))
        XCTAssertEqual(buildOf(place), "202610252100")
        XCTAssertEqual(buildOf(fresh), "202610260758")
    }

    func testFailedReplacementDoesNotUnregisterTheInstalledApp() throws {
        let root = try folder()
        let place = root.appendingPathComponent("Yab.app")
        let scratch = root.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try bundle(place, build: 202610252100)
        let missing = scratch.appendingPathComponent("missing.app")
        var registrations: [(URL, Bool)] = []
        XCTAssertThrowsError(try Swap.replace(202610252100, with: missing, scratch: scratch, at: place,
                                             identifier: "dev.test.yab",
                                             registrationChanged: { registrations.append(($0, $1)) }))
        XCTAssertEqual(buildOf(place), "202610252100")
        XCTAssertEqual(registrations.map { $0.0.path }, [missing.path])
        XCTAssertEqual(registrations.map(\.1), [true])
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("replaced.app").path))
    }

    func testTheSetAsideBundleGoesOnlyWithTheAppInPlace() throws {
        let root = try folder()
        let place = root.appendingPathComponent("Yab.app"), aside = root.appendingPathComponent("Yab.app.old")
        try bundle(aside, build: 1)
        // Nothing in place: the one set aside is all there is, and stays.
        Swap.sweep(aside, beside: place, identifier: "dev.test.yab")
        XCTAssertEqual(buildOf(aside), "1")
        try bundle(place, build: 2)
        Swap.sweep(aside, beside: place, identifier: "dev.test.yab")
        XCTAssertNil(buildOf(aside))
        XCTAssertEqual(buildOf(place), "2")
    }
}
