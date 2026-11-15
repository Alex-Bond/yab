import Foundation
import Darwin
import Testing
@testable import Fast

/// A native host that stops by itself is told from one Yab stopped
/// (HostPipe.exitedByItself): 1Password's host refuses a browser it doesn't
/// know and exits, and Yab says how to add it.
@Suite(.serialized)
struct ExtensionNativeTests {
    @MainActor @Test func oneShotReturnsItsFirstReplyAndStopsTheHost() async throws {
        let pipe = HostPipe(program: URL(fileURLWithPath: "/bin/cat"), origin: "-", buffersReplies: true)
        let reply = try await ExtensionNative.send(["answer": 7], using: pipe, timeout: .seconds(2)) as? [String: Int]
        #expect(reply?["answer"] == 7)
        #expect(pipe.stoppedByUs)
    }

    @MainActor @Test func silentOneShotHasAResponseDeadline() async throws {
        let pipe = HostPipe(program: URL(fileURLWithPath: "/bin/sleep"), origin: "30")
        do {
            _ = try await ExtensionNative.send(["hello": true], using: pipe, timeout: .milliseconds(25))
            Issue.record("silent host answered")
        } catch {
            #expect(error.localizedDescription == "Native host has exited.")
        }
        #expect(pipe.stoppedByUs)
    }

    @MainActor @Test func unloadingTheOwnerEndsItsPendingOneShots() async throws {
        let owner = NSObject()
        let pipe = HostPipe(program: URL(fileURLWithPath: "/bin/sleep"), origin: "30")
        let call = Task { try await ExtensionNative.send(["hello": true], using: pipe,
            owner: ObjectIdentifier(owner), timeout: .seconds(60)) }
        // Let the main actor enter the request before unloading its owner.
        while pipe.processIdentifier == 0 { await Task.yield() }
        ExtensionNative.stop(owner: ObjectIdentifier(owner))
        await #expect(throws: ExtensionNative.Refused.self) { try await call.value }
        #expect(pipe.stoppedByUs)
    }

    @MainActor @Test func cancelledOneShotStopsItsHost() async throws {
        let pipe = HostPipe(program: URL(fileURLWithPath: "/bin/sleep"), origin: "30")
        let call = Task { try await ExtensionNative.send(["hello": true], using: pipe, timeout: .seconds(60)) }
        while pipe.processIdentifier == 0 { await Task.yield() }
        call.cancel()
        do { _ = try await call.value; Issue.record("cancelled host answered") } catch {}
        #expect(pipe.stoppedByUs)
    }

    private func ended(_ pipe: HostPipe) async {
        for _ in 0..<100 where !pipe.exitedByItself {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func aHostThatExitsExitedByItself() async throws {
        let pipe = HostPipe(program: URL(fileURLWithPath: "/usr/bin/false"), origin: "chrome-extension://x/")
        try pipe.start()
        await ended(pipe)
        #expect(pipe.exitedByItself)
    }

    /// What 1Password 8.12.38's host said to Yab on adhd, word for word
    /// (docs/evidence/launch-repro-2026-10-03/extensions-followup.md).
    static let unknownBrowser: [String: Any] = [
        "type": "NotificationModern",
        "content": [
            "content": ["type": "BrowserVerificationFailed", "content": "UnknownBrowser"],
            "browser_state": ["type": "Untrusted", "content": ["id": "ZGV2LnNlcmFmaW0ueWFi"]],
            "timestamp": "2026-10-03T22:08:10.522229Z",
        ],
    ]

    @Test func onePasswordRefusingIsRefused() {
        // Its extension lets go first, so the host never stops by itself.
        #expect(Extensions.refused(.init(last: Self.unknownBrowser, after: 0.1, byItself: false)))
        #expect(Extensions.refused(.init(last: Self.unknownBrowser, after: 120, byItself: false)))
    }

    @Test func onlyTheNoIsARefusal() {
        #expect(Extensions.refusal(Self.unknownBrowser))
        #expect(!Extensions.refusal(["type": "Hello"]))
        #expect(!Extensions.refusal(nil))
    }

    /// 1Password's row in Settings says its app isn't connected from the
    /// app's no until the app's first other word.
    @MainActor @Test func theRowSaysSoUntilTheAppAnswers() {
        let id = "aeblfdkhhhdcdjpifhhbdiojplfjncoa", host = Extensions.onePasswordHost
        var now = Extensions.nextUnconnected([], id, host: host, refused: true, appHere: true)
        #expect(now == [id])
        // Refused again: still said once.
        now = Extensions.nextUnconnected(now, id, host: host, refused: true, appHere: true)
        #expect(now == [id])
        // The app answering: quiet.
        now = Extensions.nextUnconnected(now, id, host: host, refused: false, appHere: true)
        #expect(now.isEmpty)
        // No app on this Mac: nothing to connect to.
        #expect(Extensions.nextUnconnected([], id, host: host, refused: true, appHere: false).isEmpty)
        // Another app, or another extension: as it was.
        #expect(Extensions.nextUnconnected([], id, host: "com.8bit.bitwarden", refused: true, appHere: true).isEmpty)
        #expect(Extensions.nextUnconnected([id], "nngceckbapebfimnlniiiahkandclblb", host: host, refused: false, appHere: true) == [id])
    }

    @Test func aHostStoppingAtOnceIsRefused() {
        #expect(Extensions.refused(.init(last: nil, after: 0.2, byItself: true)))
        #expect(!Extensions.refused(.init(last: nil, after: 600, byItself: true)))
        // Let go of by the extension or Yab, having said something else.
        #expect(!Extensions.refused(.init(last: ["type": "Hello"], after: 0.2, byItself: false)))
        #expect(!Extensions.refused(.init(last: nil, after: 0.2, byItself: false)))
    }

    @Test func aHostYabStoppedDidNot() async throws {
        // sleep takes the origin as its seconds.
        let pipe = HostPipe(program: URL(fileURLWithPath: "/bin/sleep"), origin: "30")
        try pipe.start()
        #expect(!pipe.exitedByItself)
        pipe.stop()
        try await Task.sleep(for: .milliseconds(300))
        #expect(!pipe.exitedByItself)
    }

    /// Crash #10 (0.0.8): a host's output closing and its process exiting
    /// both end the pipe, each on a thread of its own, and the two let go
    /// of the same onExit together. Now it is heard once, whoever comes.
    @Test func bothEndsTogetherHearTheExitOnce() {
        for _ in 0..<200 {
            let pipe = HostPipe(program: URL(fileURLWithPath: "/usr/bin/true"), origin: "x")
            let count = Count()
            pipe.onExit = { count.add() }
            DispatchQueue.concurrentPerform(iterations: 8) { _ in pipe.finish() }
            #expect(count.value == 1)
        }
    }

    /// A host that ended as it started, before connect gave it onExit,
    /// still says so; and a read after the end fails instead of waiting.
    @Test func anExitBeforeTheHandlerIsHeard() async {
        let pipe = HostPipe(program: URL(fileURLWithPath: "/usr/bin/true"), origin: "x")
        pipe.finish()
        let count = Count()
        pipe.onExit = { count.add() }
        #expect(count.value == 1)
        await #expect(throws: ExtensionNative.Refused.self) { try await pipe.readOne() }
    }

    @Test func stoppingResolvesAReaderWithoutWaitingForTheHost() async throws {
        let pipe = HostPipe(program: URL(fileURLWithPath: "/bin/sleep"), origin: "30")
        try pipe.start()
        defer { pipe.stop() }
        let reader = Task { try await pipe.readOne() }
        pipe.stop()
        await #expect(throws: ExtensionNative.Refused.self) { try await reader.value }
        // Stop is safe even when the exit and output callbacks race it.
        pipe.stop()
    }

    @Test(arguments: [true, false])
    func aCompletedPipeClosesDescriptorsWhileStillRetained(observeWriters: Bool) async throws {
        // Other suites and Foundation open descriptors while this awaits a
        // host. Check its pipe ends by their behavior, not process-wide FDs
        // (or FD numbers that another thread can reuse after close).
        var pipes: [HostPipe] = []
        for _ in 0..<16 {
            let input = Pipe(), output = Pipe()
            var witnesses: [Int32] = []
            defer { for fd in witnesses { close(fd) } }
            for channel in [input, output] {
                // Keep only one end: holding both would prevent EOF/EPIPE.
                let handle = observeWriters ? channel.fileHandleForReading : channel.fileHandleForWriting
                let fd = dup(handle.fileDescriptor)
                try #require(fd >= 0)
                witnesses.append(fd)
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                _ = fcntl(fd, F_SETNOSIGPIPE, 1)
            }
            let pipe = HostPipe(program: URL(fileURLWithPath: "/usr/bin/true"), origin: "x", input: input, output: output)
            pipes.append(pipe)
            let completed = Count()
            pipe.onExit = { completed.add() }
            try pipe.start()
            await ended(pipe)
            try #require(pipe.exitedByItself)
            // isRunning can turn false before the termination callback has
            // drained stdout and closed the descriptors. Wait for cleanup.
            for _ in 0..<100 where completed.value == 0 {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(completed.value == 1)
            for fd in witnesses {
                var byte: UInt8 = 0
                if observeWriters {
                    // No writer left, including the parent's child stdout.
                    #expect(read(fd, &byte, 1) == 0)
                } else {
                    // No reader left, including the parent's child stdin.
                    let written = write(fd, &byte, 1)
                    let failure = errno
                    #expect(written == -1 && failure == EPIPE)
                }
            }
        }
        withExtendedLifetime(pipes) {}
    }

    @Test func theFinalReplyIsDrainedBeforeExitClosesThePipe() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("native-last-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("reply")
        // A nine-byte JSON string with Chrome's little-endian length.
        try "#!/bin/sh\nprintf '\\011\\000\\000\\000\"goodbye\"'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        for _ in 0..<20 {
            let pipe = HostPipe(program: script, origin: "x", buffersReplies: true)
            try pipe.start()
            defer { pipe.stop() }
            await ended(pipe)
            #expect(try await pipe.readOne() as? String == "goodbye")
        }
    }

    /// Crashes #853 (0.45.1) and #1501 (0.46.17): a browser out of file
    /// descriptors. -[NSPipe init] answers nil when pipe(2) fails, Swift
    /// keeps that nil as a Pipe, the host still started, and the first
    /// message the extension sent wrote to a nil handle (SIGSEGV at 0x64 in
    /// _NSFileHandleIsClosed). A pipe that can't be made is now an error:
    /// here pipe(2)'s EMFILE, without starving the test process.
    @Test func aHostMadeWithoutDescriptorsFailsInsteadOfCrashing() async throws {
        let pipe = HostPipe(program: URL(fileURLWithPath: "/bin/sleep"), origin: "30",
                            open: { throw POSIXError(.EMFILE) })
        defer { pipe.stop() }
        // Starting fails with why; a message after that fails, not crashes.
        let refused = #expect(throws: ExtensionNative.Refused.self) { try pipe.start() }
        #expect(refused?.why.contains("Too many open files") == true)
        #expect(throws: (any Error).self) { try pipe.write(["text": "hello"]) }
        await #expect(throws: ExtensionNative.Refused.self) { try await pipe.readOne() }
    }

    /// The pipes made for a host are as Pipe's were: a message goes in, the
    /// reply comes back, and a write after the host ends fails.
    @Test func aHostEchoesThroughItsOwnPipes() async throws {
        let pipe = HostPipe(program: URL(fileURLWithPath: "/bin/cat"), origin: "-", buffersReplies: true)
        try pipe.start()
        try pipe.write(["text": "hello"])
        let reply = try await pipe.readOne() as? [String: Any]
        #expect(reply?["text"] as? String == "hello")
        pipe.stop()
        #expect(throws: (any Error).self) { try pipe.write(["text": "again"]) }
    }

    // MARK: hosts macOS won't let run

    @Test func onlyAQuickSIGKILLNotFromYabIsMacOS() {
        #expect(HostPipe.killedByMacOS(reason: .uncaughtSignal, status: SIGKILL, after: 0.05, stoppedByYab: false))
        // Yab's stop, an exit, another signal, or a kill long after it ran.
        #expect(!HostPipe.killedByMacOS(reason: .uncaughtSignal, status: SIGKILL, after: 0.05, stoppedByYab: true))
        #expect(!HostPipe.killedByMacOS(reason: .exit, status: SIGKILL, after: 0.05, stoppedByYab: false))
        #expect(!HostPipe.killedByMacOS(reason: .uncaughtSignal, status: SIGTERM, after: 0.05, stoppedByYab: false))
        #expect(!HostPipe.killedByMacOS(reason: .uncaughtSignal, status: SIGKILL, after: 30, stoppedByYab: false))
    }

    /// A host killed as it starts, the way macOS kills one whose launch
    /// constraint its parent doesn't meet, is heard as that.
    @Test func aHostKilledAsItStartsIsHeard() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-native-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("killed")
        try "#!/bin/sh\nkill -9 $$\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let pipe = HostPipe(program: script, origin: "chrome-extension://x/")
        let count = Count()
        pipe.killedAtLaunch = { count.add() }
        try pipe.start()
        for _ in 0..<100 where count.value == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(count.value == 1)
        #expect(!pipe.exitedByItself)
    }

    @Test func hostsThatExitOrThatYabStopsAreNotMacOS() async throws {
        let exits = HostPipe(program: URL(fileURLWithPath: "/usr/bin/false"), origin: "x")
        let stopped = HostPipe(program: URL(fileURLWithPath: "/bin/sleep"), origin: "30")
        let count = Count()
        exits.killedAtLaunch = { count.add() }
        stopped.killedAtLaunch = { count.add() }
        try exits.start()
        try stopped.start()
        stopped.stop()
        try await Task.sleep(for: .milliseconds(400))
        #expect(count.value == 0)
    }

    /// Once macOS has killed a host, Yab doesn't start it again: the
    /// extension hears what it heard the first time.
    @Test func aHostMacOSKilledIsNotStartedAgain() async {
        ExtensionNative.unbarAll()
        defer { ExtensionNative.unbarAll() }
        let name = "dev.serafim.yab.test_barred"
        let first = await #expect(throws: ExtensionNative.Refused.self) {
            try await ExtensionNative.send(["x": 1], to: name, from: "x")
        }
        #expect(first?.why == "Specified native messaging host not found.")
        ExtensionNative.bar(name)
        #expect(ExtensionNative.stoppedByMacOS(name))
        let again = await #expect(throws: ExtensionNative.Refused.self) {
            try await ExtensionNative.send(["x": 1], to: name, from: "x")
        }
        #expect(again?.why == "Native host has exited.")
    }

    /// Apple's own helper, started by this test process, which is no browser
    /// Apple approved: macOS kills it as it starts, which is what happens to
    /// it in Yab without the web browser entitlement
    /// (docs/evidence/icloud-passwords-2026-10-08.md).
    @Test func applesHelperIsKilledForAnUnapprovedParent() async throws {
        let helper = URL(fileURLWithPath: "/System/Cryptexes/App/System/Library/CoreServices/PasswordManagerBrowserExtensionHelper.app/Contents/MacOS/PasswordManagerBrowserExtensionHelper")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { return }
        let pipe = HostPipe(program: helper, origin: "chrome-extension://pejdijmoenmkgeppbflobdenhhabjlaj/")
        let count = Count()
        pipe.killedAtLaunch = { count.add() }
        try pipe.start()
        for _ in 0..<150 where count.value == 0 { try await Task.sleep(for: .milliseconds(20)) }
        pipe.stop()
        #expect(count.value == 1)
    }

    @MainActor @Test func theRowSaysWhyForICloudPasswords() {
        let icloud = "pejdijmoenmkgeppbflobdenhhabjlaj", other = "nngceckbapebfimnlniiiahkandclblb"
        #expect(ExtensionDetail.stoppedLine(icloud, waitsOnApple: true).contains("Apple's approval"))
        #expect(ExtensionDetail.stoppedNote(icloud, waitsOnApple: true).contains("Passwords app"))
        // Signed with the entitlement, or another extension: only what happened.
        #expect(ExtensionDetail.stoppedLine(icloud, waitsOnApple: false) == "macOS stopped the app it talks to.")
        #expect(ExtensionDetail.stoppedLine(other, waitsOnApple: true) == "macOS stopped the app it talks to.")
        // Two lines at most in the name's column; no long dashes.
        for words in [ExtensionDetail.stoppedLine(icloud, waitsOnApple: true), ExtensionDetail.stoppedNote(icloud, waitsOnApple: true),
                      ExtensionDetail.stoppedNote(other, waitsOnApple: true)] {
            #expect(!words.contains("\u{2014}") && !words.contains("\u{2013}"))
        }
        #expect(ExtensionDetail.stoppedLine(icloud, waitsOnApple: true).split(separator: "\n").count == 2)
    }

    /// Its button, while it waits on Apple, opens a popover of Yab's own
    /// saying why instead of a popup that asks for a code no helper will
    /// show; only Apple's two extensions, and only unsigned.
    @MainActor @Test func theButtonSaysWhyInsteadOfAPopup() {
        for id in Extensions.iCloudPasswords { #expect(ExtensionDetail.iCloudWaiting(id, waitsOnApple: true)) }
        #expect(!ExtensionDetail.iCloudWaiting("pejdijmoenmkgeppbflobdenhhabjlaj", waitsOnApple: false))
        #expect(!ExtensionDetail.iCloudWaiting("nngceckbapebfimnlniiiahkandclblb", waitsOnApple: true))
        // One short line under the name, no long dashes.
        #expect(!ExtensionDetail.waitingTitle.contains("\n") && ExtensionDetail.waitingTitle.count < 32)
        #expect(!ExtensionDetail.waitingTitle.contains("\u{2014}") && !ExtensionDetail.waitingTitle.contains("\u{2013}"))
        // Nothing up until a press, and a press's second half doesn't reopen.
        #expect(!ExtensionWithheld.shared.isShown)
        #expect(!ExtensionWithheld.shared.closes("pejdijmoenmkgeppbflobdenhhabjlaj"))
    }

    private final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func add() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }
}
