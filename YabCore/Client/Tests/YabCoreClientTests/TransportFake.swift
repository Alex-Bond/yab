import XCTest
import Darwin
@testable import YabCoreClient

/// The production transport (YabCore/src/transport.mm) in a process of its
/// own, built by YabCore/tests/transport_flow.sh, against this client.
final class TransportFake {
    let process = Process()
    let directory: URL
    let path: String
    init() throws {
        guard let executable = ProcessInfo.processInfo.environment["YAB_TRANSPORT_FAKE"] else {
            throw XCTSkip("Needs the transport fake: bash YabCore/tests/transport_flow.sh")
        }
        directory = URL(fileURLWithPath: "/tmp/yab-flow-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        path = directory.appendingPathComponent("wire").path
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [path]
        try process.run()
        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: path) { return }
            usleep(10_000)
        }
        throw YabCoreError.timeout
    }
    var alive: Bool { process.isRunning }
    deinit {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: directory)
    }
}

