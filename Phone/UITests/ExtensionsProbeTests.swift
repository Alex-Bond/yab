import XCTest

/// The Chrome Web Store's best-known extensions, each installed, started and
/// its popup drawn by the app's own probe (Extensions/ExtensionProbe), five
/// to a launch. Their reports and popup pictures are attached; the
/// compatibility table (ExtensionCompatibility.known) is written from them.
/// Needs the browser entitlement: `remote ui ExtensionsProbeTests --sign`.
final class ExtensionsProbeTests: XCTestCase {
    static let top: [(String, String)] = [
        ("Google Translate", "aapbdbdomjkkjkaonfhkkikfgjllcleb"), ("Grammarly", "kbfnbcaeplbcioakkpcpgfkobkghlhen"),
        ("AdBlock", "gighmmpiobklfepjocnamgkkbiglidom"), ("Adblock Plus", "cfhdojbkjhnklbpkdaibdccddilifddb"),
        ("uBlock Origin Lite", "ddkjiahejlhfcafbddmgiahcphecmpfh"), ("Honey", "bmnlcjabgnpnenekpadlanbbkooimhnj"),
        ("LastPass", "hdokiejnpimakedhajhdlcegeplioahd"), ("Bitwarden", "nngceckbapebfimnlniiiahkandclblb"),
        ("1Password", "aeblfdkhhhdcdjpifhhbdiojplfjncoa"), ("Dark Reader", "eimadpbcbfnmbkopoojfekhnkhdbieeh"),
        ("MetaMask", "nkbihfbeogaeaoehlefnkodbefgpgknn"), ("Return YouTube Dislike", "gebbhagfogifgggkldgodflihgfeippi"),
        ("SponsorBlock", "mnjggcdmjocbbbhaepdhchncahnbgone"), ("Tampermonkey", "dhdgffkkebhmkfjojejmpbldmpobfkfo"),
        ("React Developer Tools", "fmkadmapgofadopljbjfkapdkoienihi"), ("ColorZilla", "bhlhnicpbhignbdhedgjhgdocnmhomnp"),
        ("Loom", "liecbddmkiiihnedobmlmillhodjkdmb"), ("Momentum", "laookkfknpbbblfpciffpaejjkokdgca"),
        ("Google Docs Offline", "ghbmnnjooekpmoecnnnilnnbdlolhkhi"), ("Privacy Badger", "pkehgijcmpdhfbdbbnkijodmdjhbjlgp"),
    ]

    /// The two content blockers people add first (request 1034): each
    /// installed from the store, started, and its declarativeNetRequest
    /// rules stopping ads and trackers on a page while plain addresses load.
    /// Yab's own blocker is off, so whatever is stopped is the extension's.
    static let blockers: [(String, String)] = [
        ("uBlock Origin Lite", "ddkjiahejlhfcafbddmgiahcphecmpfh"), ("AdGuard", "bgnkhhnnamicmpeenaelnjfhikgbkllg"),
    ]

    func testContentBlockersBlockAds() throws {
        let body = try probe(Self.blockers, blocking: true)
        let without = body["blockedWithout"] as? [String: String] ?? [:]
        XCTAssertTrue(without.filter { $0.key.hasPrefix("https") }.values.allSatisfy { $0 == "loaded" },
                      "with no extension every address loads: \(without)")
        let results = body["results"] as? [[String: Any]] ?? []
        XCTAssertEqual(results.count, Self.blockers.count)
        for (name, id) in Self.blockers {
            let result = results.first { $0["id"] as? String == id } ?? [:]
            XCTAssertNil(result["installError"], "\(name) installs: \(result)")
            let log = result["log"] as? [String] ?? []
            // Started, said by WebKit or by the worker calling the shim.
            XCTAssertTrue(log.contains("background started") || log.contains { $0.hasPrefix("api ") }, "\(name)'s worker starts: \(log)")
            let requests = (result["blocking"] as? [String: Any])?["requests"] as? [String: String] ?? [:]
            for ad in ["https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js", "https://securepubads.g.doubleclick.net/tag/js/gpt.js"] {
                XCTAssertEqual(requests[ad]?.hasPrefix("failed"), true, "\(name) stops \(ad): \(requests)")
            }
            XCTAssertEqual(requests["https://example.com/"], "loaded", "\(name) lets a plain page load: \(requests)")
        }
    }

    func testProbeFirstFive() throws { try probe(Array(Self.top[0..<5])) }
    func testProbeSecondFive() throws { try probe(Array(Self.top[5..<10])) }
    func testProbeThirdFive() throws { try probe(Array(Self.top[10..<15])) }
    func testProbeFourthFive() throws { try probe(Array(Self.top[15..<20])) }

    @discardableResult
    private func probe(_ list: [(String, String)], blocking: Bool = false) throws -> [String: Any] {
        let folder = URL(fileURLWithPath: "/private/tmp/yab-extension-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = XCUIApplication()
        app.launchEnvironment = ["YAB_TEST": "1", "YAB_HAPTICS_SILENT": "1",
                                 "YAB_EXTENSION_PROBE": list.map(\.1).joined(separator: ",")]
        if blocking { app.launchEnvironment["YAB_EXTENSION_PROBE_BLOCKING"] = "1" }
        app.launchArguments = ["-YabProfileDirectory", folder.path, "-YabURL", "https://example.com/",
                               "-YabPrivateLockTestAuthentication", "off", "-settings.welcomed", "YES"]
            + (blocking ? ["-settings.blocksAds", "NO"] : [])
        app.launch()
        if app.buttons["join.close"].waitForExistence(timeout: 8) { app.buttons["join.close"].tap() }
        app.passWelcome(timeout: 6)
        let report = folder.appendingPathComponent("extension-probe.json")
        let end = Date().addingTimeInterval(Double(list.count) * (blocking ? 150 : 75))
        var done = false
        var finished: [String: Any] = [:]
        while Date() < end {
            if let data = try? Data(contentsOf: report),
               let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any], body["done"] as? Bool == true {
                done = true; finished = body; break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(2))
        }
        if let data = try? Data(contentsOf: report) {
            let json = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            json.name = "extension-probe.json"; json.lifetime = .keepAlways; add(json)
        }
        for (name, id) in list {
            if let picture = UIImage(contentsOfFile: folder.appendingPathComponent("probe-\(id).png").path) {
                let shot = XCTAttachment(image: picture)
                shot.name = "popup " + name; shot.lifetime = .keepAlways; add(shot)
            }
        }
        XCTAssertTrue(done, "the probe finished")
        return finished
    }
}
