import XCTest
@testable import Fast

/// Feedback #141: a task kept to the browser may upload a file its own
/// words name by path, however the path is spelled.
@MainActor
final class AgentUploadNamedTests: XCTestCase {
    func testPathNamedInTheTaskCounts() throws {
        let folder = URL(fileURLWithPath: "/tmp").appendingPathComponent("yab-named-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let icon = folder.appendingPathComponent("firegoat-slack-icon.png")
        try Data([1, 2, 3]).write(to: icon)
        let words = "set the app icon to \(icon.path) with + Add App Icon"
        XCTAssertTrue(AgentFiles.named(icon, in: [words]))
        // The disk's own spelling, /private/tmp, against words that say /tmp, and back.
        XCTAssertTrue(AgentFiles.named(URL(fileURLWithPath: "/private" + icon.path), in: [words]))
        XCTAssertTrue(AgentFiles.named(icon, in: ["upload /private\(icon.path)"]))
        XCTAssertFalse(AgentFiles.named(icon, in: ["set the app icon"]))
        XCTAssertFalse(AgentFiles.named(folder.appendingPathComponent("other.png"), in: [words]))
        // Named, a task kept to the browser may give it; the whole Mac may anyway.
        XCTAssertNil(AgentFiles.shared.refuse(icon, session: "test-named", full: false, told: ["icon: \(icon.path)"]))
        XCTAssertNil(AgentFiles.shared.refuse(icon, session: "test-named", full: true))
        XCTAssertNotNil(AgentFiles.shared.refuse(URL(fileURLWithPath: NSHomeDirectory() + "/.ssh/id_rsa"), session: "test-named", full: true))
    }
}
