import Foundation
import Darwin
import Testing
@testable import Fast

struct ChromiumNativeHostLauncherTests {
    let origin = "chrome-extension://pejdijmoenmkgeppbflobdenhhabjlaj/"

    @Test func terminalAndTestRunnerCannotUseThePrivilegedDoor() {
        #expect(!ChromiumNativeHostLauncher.acceptedCaller())
    }

    @Test func validatesOriginalManifestAgainBeforeLaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("apple.json")
        let manifest: [String: Any] = ["name": "com.apple.passwordmanager", "description": "Test",
            "path": "/usr/bin/true", "type": "stdio", "allowed_origins": [origin]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: source)
        #expect(try ChromiumNativeHostLauncher.program(manifestAt: source, origin: origin).path == "/usr/bin/true")
        for invalid in [origin + "extra", "https://pejdijmoenmkgeppbflobdenhhabjlaj/",
                        "chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/"] {
            #expect(throws: (any Error).self) { try ChromiumNativeHostLauncher.program(manifestAt: source, origin: invalid) }
        }
        var wrong = manifest
        wrong["name"] = "com.other.host"
        try JSONSerialization.data(withJSONObject: wrong).write(to: source)
        #expect(throws: (any Error).self) { try ChromiumNativeHostLauncher.program(manifestAt: source, origin: origin) }
    }

    @Test func appleRegistrationKeepsOriginsAndUsesTheSignedBrowserParent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original host's manifest.json")
        let original: [String: Any] = ["name": "com.apple.passwordmanager", "description": "Test",
            "path": "/usr/bin/true", "type": "stdio", "allowed_origins": [origin]]
        try JSONSerialization.data(withJSONObject: original).write(to: source)
        let launcher = URL(fileURLWithPath: "/test/browser's app/Contents/MacOS/yab")
        let result = try ChromiumNativeMessaging.register(manifestAt: source, dataRoot: root.appendingPathComponent("cef"),
            installed: ["pejdijmoenmkgeppbflobdenhhabjlaj"], launcher: launcher)
        let registered = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: result.path)) as? [String: Any])
        #expect(registered["allowed_origins"] as? [String] == [origin])
        let path = try #require(registered["path"] as? String)
        let script = try String(contentsOfFile: path, encoding: .utf8)
        #expect(script.contains("browser'\\''s app"))
        #expect(script.contains("manifest.json' \"$@\""))
        #expect(script.contains("--yab-native-messaging"))
        #expect(FileManager.default.isExecutableFile(atPath: path))
        #expect(try (JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any])?["path"] as? String == "/usr/bin/true")
    }

    @Test func acceptsOnePasswordsHostAndHearsItsRefusal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let origin = "chrome-extension://aeblfdkhhhdcdjpifhhbdiojplfjncoa/"
        let source = root.appendingPathComponent("1password.json")
        let manifest: [String: Any] = ["name": "com.1password.1password", "description": "Test",
            "path": "/usr/bin/true", "type": "stdio", "allowed_origins": [origin]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: source)
        #expect(try ChromiumNativeHostLauncher.program(manifestAt: source, origin: origin).path == "/usr/bin/true")

        func frame(_ json: String) -> Data {
            var length = UInt32(json.utf8.count).littleEndian
            return Data(bytes: &length, count: 4) + Data(json.utf8)
        }
        var frames = ChromiumNativeHostLauncher.Frames()
        let refusal = frame(#"{"type":"NmhAppResponse","error":"BrowserVerificationFailed","detail":"UnknownBrowser"}"#)
        // Split across reads: nothing until the frame is whole.
        #expect(frames.verdicts(after: refusal.prefix(10)).isEmpty)
        #expect(frames.verdicts(after: refusal.dropFirst(10) + frame(#"{"type":"NmLockState"}"#)) == [true, false])
        var oversized = ChromiumNativeHostLauncher.Frames()
        var huge = UInt32(2 << 20).littleEndian
        #expect(oversized.verdicts(after: Data(bytes: &huge, count: 4) + Data("x".utf8)).isEmpty)
        #expect(oversized.stopped)
    }

    /// Register 2598: Chromium ends a host by closing its pipes and, two
    /// seconds on, SIGKILLing the door it started, which never reached the
    /// door's child. A host that waits on after its stdin ends is now ended
    /// by the door itself once Chromium lets go.
    @Test func aHostThatOutlivesItsStdinEndsWithChromiumsEnd() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = root.appendingPathComponent("lingers")
        let pidFile = root.appendingPathComponent("pid")
        try "#!/bin/sh\necho $$ > '\(pidFile.path)'\ncat > /dev/null\nexec /bin/sleep 30\n".write(to: host, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: host.path)
        let origin = self.origin
        var chromium: [Int32] = [-1, -1]
        #expect(pipe(&chromium) == 0)
        // As in Chromium, only this end's owner holds the write end.
        chromium.forEach { _ = fcntl($0, F_SETFD, FD_CLOEXEC) }
        let started = Date()
        let done = DispatchSemaphore(value: 0)
        let status = StatusBox()
        let input = chromium[0]
        Thread.detachNewThread {
            let result = try? ChromiumNativeHostLauncher.serve(host: host, origin: origin, watched: false,
                input: input, output: .nullDevice, error: .nullDevice)
            status.set(result)
            done.signal()
        }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: pidFile.path), Date() < deadline { usleep(20_000) }
        let pid = try #require(Int32((try? String(contentsOf: pidFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""))
        close(chromium[1])
        #expect(done.wait(timeout: .now() + 5) == .success)
        close(chromium[0])
        #expect(status.get() == 128 + SIGKILL)
        #expect(Date().timeIntervalSince(started) < 4)
        #expect(kill(pid, 0) != 0)
    }

    @Test func aHostThatEndsAtEOFEndsOnItsOwn() throws {
        let origin = self.origin
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = root.appendingPathComponent("echo")
        try "#!/bin/sh\nexec /bin/cat\n".write(to: host, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: host.path)
        var chromium: [Int32] = [-1, -1], back: [Int32] = [-1, -1]
        #expect(pipe(&chromium) == 0 && pipe(&back) == 0)
        (chromium + back).forEach { _ = fcntl($0, F_SETFD, FD_CLOEXEC) }
        let done = DispatchSemaphore(value: 0)
        let status = StatusBox()
        let output = FileHandle(fileDescriptor: back[1], closeOnDealloc: false)
        let input = chromium[0]
        Thread.detachNewThread {
            status.set(try? ChromiumNativeHostLauncher.serve(host: host, origin: origin,
                watched: true, input: input, output: output, error: .nullDevice))
            done.signal()
        }
        let frame = Data([5, 0, 0, 0]) + Data("{\"a\"}".utf8)
        _ = frame.withUnsafeBytes { write(chromium[1], $0.baseAddress, $0.count) }
        var echoed = [UInt8](repeating: 0, count: frame.count)
        var got = 0
        while got < frame.count {
            let n = echoed.withUnsafeMutableBytes { read(back[0], $0.baseAddress! + got, frame.count - got) }
            guard n > 0 else { break }
            got += n
        }
        #expect(Data(echoed) == frame)
        close(chromium[1])
        #expect(done.wait(timeout: .now() + 5) == .success)
        #expect(status.get() == 0)
        [chromium[0], back[0], back[1]].forEach { close($0) }
    }
}

private final class StatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32?
    func set(_ new: Int32?) { lock.withLock { value = new } }
    func get() -> Int32? { lock.withLock { value } }
}
