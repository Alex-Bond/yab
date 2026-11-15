import XCTest
import YabUpdate
import YabStore
@testable import Fast

/// Run the transport case through scripts/runs/manual_update_tests.py. Its
/// dedicated process supplies a test feed before Update.feed is first read.
@MainActor
final class ManualUpdateTests: XCTestCase {
    private let currentBuild = 202610231032
    private let patchBuild = 202610231500
    private let now = ISO8601DateFormatter().date(from: "2026-10-23T22:00:00Z")!

    /// A Stable copy's Check Now asks the Stable feed, as its automatic
    /// checks do: from 0.37.0 it asked Nightly whatever the channel, and a
    /// Stable Mac installed 0.43.0 while it soaked on Nightly (register 1689).
    /// With Nightly builds on, every check asks Nightly.
    func testManualCheckKeepsSavedChannel() async throws {
        guard ProcessInfo.processInfo.environment["YAB_FEED"] == ManualAppcastProtocol.feed else {
            throw XCTSkip("Run isolated transport regression with scripts/runs/manual_update_tests.py")
        }
        XCTAssertTrue(URLProtocol.registerClass(ManualAppcastProtocol.self))
        defer { URLProtocol.unregisterClass(ManualAppcastProtocol.self) }
        ManualAppcastProtocol.reset()
        let settings = Store.settings
        let prior = settings.object(forKey: Update.nightlyKey)
        defer {
            if let prior { settings.set(prior, forKey: Update.nightlyKey) }
            else { settings.removeObject(forKey: Update.nightlyKey) }
        }
        settings.set(false, forKey: Update.nightlyKey)

        // Same entry point and default argument as Settings, the menu and
        // the command bar.
        let checked = expectation(description: "manual app update callback")
        var manual: Update.Release?
        Updater.shared.check { found in manual = found; checked.fulfill() }
        await fulfillment(of: [checked], timeout: 15)
        XCTAssertEqual(ManualAppcastProtocol.requests.last?.queryItems?.filter { $0.name == "channel" }, [],
                       "a Stable copy's manual check must not ask the Nightly feed")
        XCTAssertEqual(manual?.version, "0.36.0")
        XCTAssertEqual(manual?.build, currentBuild)
        XCTAssertFalse(settings.bool(forKey: Update.nightlyKey))

        // The closed-app agent calls the same API.
        let automatic = await Update.fetch(failure: nil, again: true)
        XCTAssertTrue(automatic.reached)
        XCTAssertNil(ManualAppcastProtocol.requests.last?.queryItems?.first { $0.name == "channel" })
        XCTAssertEqual(automatic.release?.version, "0.36.0")
        XCTAssertFalse(automatic.release?.isUpdate(from: "0.36.0", build: currentBuild, asked: false, now: now) == true)

        settings.set(true, forKey: Update.nightlyKey)
        let nightly = await Update.fetch(failure: nil, again: true)
        XCTAssertEqual(nightly.release?.version, "0.36.2")
        XCTAssertEqual(ManualAppcastProtocol.requests.last?.queryItems?.filter { $0.name == "channel" },
                       [URLQueryItem(name: "channel", value: "nightly")])
        // A newer build is an update; a Nightly copy takes it without the
        // Stable day after its last update.
        let found = try XCTUnwrap(nightly.release)
        XCTAssertTrue(found.isUpdate(from: "0.36.0", build: currentBuild, asked: false, now: now))
        XCTAssertNil(Update.Settle.wait(found, dice: 0.5, since: now.addingTimeInterval(-3600), now: now,
                                        asked: false, nightly: true))
    }

    /// The URL a check asks with carries the channel the setting says, and
    /// nothing else decides it.
    func testCheckURLChannelFollowsSettingOnly() throws {
        let feed = URL(string: "https://manual-update.invalid/appcast.json")!
        let stable = try XCTUnwrap(URLComponents(url: Update.checkURL(feed: feed, build: currentBuild,
                                   system: "26.0", failure: nil, nightly: false), resolvingAgainstBaseURL: false))
        XCTAssertNil(stable.queryItems?.first { $0.name == "channel" })
        let nightly = try XCTUnwrap(URLComponents(url: Update.checkURL(feed: feed, build: currentBuild,
                                    system: "26.0", failure: nil, nightly: true), resolvingAgainstBaseURL: false))
        XCTAssertEqual(nightly.queryItems?.filter { $0.name == "channel" }, [URLQueryItem(name: "channel", value: "nightly")])
    }

    func testManualReleaseOrderingAndAutomaticNightlyPolicy() throws {
        let patch = try XCTUnwrap(Update.parse(ManualAppcastProtocol.body(nightly: true), allowingHTTP: false))
        XCTAssertTrue(patch.isUpdate(from: "0.36.0", build: currentBuild, asked: true, now: now))
        XCTAssertTrue(patch.isUpdate(from: "0.36.2", build: currentBuild, asked: true, now: now))
        for asked in [false, true] {
            // Build ordering stays authoritative even if version text differs.
            XCTAssertFalse(patch.isUpdate(from: "0.35.0", build: patchBuild, asked: asked, now: now))
            XCTAssertFalse(patch.isUpdate(from: "0.35.0", build: patchBuild + 1, asked: asked, now: now))
        }
        XCTAssertTrue(patch.isUpdate(from: "0.36.0", build: currentBuild, asked: false, now: now))
        // Taken at once on Nightly; on Stable a day after this Mac's last update.
        let lastUpdate = now.addingTimeInterval(-3600)
        XCTAssertNil(Update.Settle.wait(patch, dice: 0.5, since: lastUpdate, now: now, asked: false, nightly: true))
        XCTAssertEqual(Update.Settle.wait(patch, dice: 0.5, since: lastUpdate, now: now, asked: false, nightly: false),
                       lastUpdate.addingTimeInterval(24 * 3600))
        XCTAssertNil(Update.Settle.wait(patch, dice: 0.5, since: lastUpdate, now: now, asked: true, nightly: false))
        var critical = patch
        critical.critical = true
        XCTAssertTrue(critical.isUpdate(from: "0.36.0", build: currentBuild, asked: false, now: now))
    }

    func testForcedNightlyReplacesConflictingFeedChannel() throws {
        let feed = URL(string: "https://manual-update.invalid/appcast.json?channel=stable&fixture=kept&channel=beta")!
        let forced = try XCTUnwrap(URLComponents(url: Update.checkURL(feed: feed, build: currentBuild,
                                  system: "26.0", failure: nil, nightly: true), resolvingAgainstBaseURL: false))
        XCTAssertEqual(forced.queryItems?.filter { $0.name == "channel" }, [URLQueryItem(name: "channel", value: "nightly")])
        XCTAssertTrue(forced.queryItems?.contains(URLQueryItem(name: "fixture", value: "kept")) == true)
    }
}

private final class ManualAppcastProtocol: URLProtocol {
    static let feed = "https://manual-update.invalid/appcast.json"
    private static let lock = NSLock()
    private static var seen: [URLComponents] = []
    static var requests: [URLComponents] { lock.lock(); defer { lock.unlock() }; return seen }
    static func reset() { lock.lock(); defer { lock.unlock() }; seen = [] }

    static func body(nightly: Bool) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "version": nightly ? "0.36.2" : "0.36.0", "build": nightly ? 202610231500 : 202610231032,
            "url": "https://manual-update.invalid/never-download.zip",
            "dmg": "https://manual-update.invalid/never-open.dmg",
            "published": "2026-10-23T21:00:00Z", "critical": false, "rolloutHours": 0,
        ])
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "manual-update.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        guard url.path == "/appcast.json" else {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled)); return
        }
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        Self.lock.lock(); Self.seen.append(parts); Self.lock.unlock()
        let nightly = parts.queryItems?.first { $0.name == "channel" }?.value == "nightly"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                              headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body(nightly: nightly))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
