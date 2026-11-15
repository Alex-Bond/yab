import Foundation
import XCTest
@testable import Fast

@MainActor
final class LoadFailureLogTests: XCTestCase {
    func testOnlyStructuredHostAndNetNameSurvive() throws {
        let fields = LoadFailureLog.fields(engine: .chromium, domain: "net", code: -105,
                                          host: "ACCOUNTS.GOOGLE.COM", name: "net::ERR_NAME_NOT_RESOLVED", version: "0.46.1")
        XCTAssertEqual(fields["host"] as? String, "accounts.google.com")
        XCTAssertEqual(fields["name"] as? String, "net::ERR_NAME_NOT_RESOLVED")
        XCTAssertEqual(fields["code"] as? Int, -105)
        for secret in ["https://accounts.google.com/path?code=secret", "person@example.com", "host/path", "host\nsecret"] {
            let scrubbed = LoadFailureLog.fields(engine: .chromium, domain: "net", code: -2,
                                                host: secret, name: secret, version: "0.46.1")
            XCTAssertNil(scrubbed["host"])
            XCTAssertNil(scrubbed["name"])
            let text = String(decoding: try JSONSerialization.data(withJSONObject: scrubbed), as: UTF8.self)
            XCTAssertFalse(text.contains("secret"))
        }
    }

    func testSimulatedFailuresStayInTheLocalDiagnosticsStream() throws {
        let defaults = Store.settings
        let keys = [Crashes.key, "load-failure.sent"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(true, forKey: Crashes.key)
        defaults.removeObject(forKey: "load-failure.sent")
        XCTAssertTrue(Crashes.sends)
        let file = Store.file("load-failures.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        for (engine, domain, code) in [(PageEngineKind.chromium, "net", -102),
                                       (.chromium, "net", -101),
                                       (.webKit, NSURLErrorDomain, NSURLErrorNotConnectedToInternet)] {
            LoadFailureLog.note(engine: engine, domain: domain, code: code, host: "EXAMPLE.TEST")
            let line = try XCTUnwrap(String(contentsOf: file, encoding: .utf8).split(separator: "\n").last)
            let diagnostic = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            XCTAssertEqual(diagnostic["engine"] as? String, engine.rawValue)
            XCTAssertEqual(diagnostic["code"] as? Int, code)
            XCTAssertEqual(diagnostic["host"] as? String, "example.test")
            XCTAssertNil(diagnostic["exception"])
            XCTAssertNil(diagnostic["report"])
            XCTAssertFalse(Crashes.isCrashReport(String(line), bundle: "dev.serafim.fast"))
        }
        // Recording a page diagnostic must not claim a crash upload, even
        // when automatic crash sharing is on and a test feed is configured.
        XCTAssertNil(defaults.object(forKey: "load-failure.sent"))
        XCTAssertTrue(Crashes.sends)
    }

    func testLocalFileAppendsAndRotates() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("failures.jsonl")
        try LoadFailureLog.append(Data("one".utf8), to: file)
        try LoadFailureLog.append(Data("two".utf8), to: file)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "one\ntwo\n")
        try Data(repeating: 65, count: 1_048_577).write(to: file)
        try LoadFailureLog.append(Data("three".utf8), to: file)
        let rotated = try Data(contentsOf: file)
        XCTAssertEqual(rotated.count, 6)
        XCTAssertEqual(String(decoding: rotated.prefix(6), as: UTF8.self), "three\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.appendingPathExtension("previous").path))
    }
}
