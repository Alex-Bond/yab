import Foundation
import Testing
import YabCoreClient
@testable import Fast

/// A lost YabCore helper is recorded on its own exit (Process's termination
/// handler), not by polling `isRunning` 40 times every 50 ms (#1984): a
/// crash names its signal the moment it ends, a helper still up past the
/// two seconds is the line's loss, and the order of the reasons is kept.
@Suite(.serialized)
struct ChildExitTests {
    private func shell(_ script: String) throws -> (Process, ChildExit) {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", script]
        let exit = ChildExit(watching: child)
        try child.run()
        return (child, exit)
    }

    @Test func aCrashNamesItsSignalAsItEnds() async throws {
        let (_, exit) = try shell("sleep 0.3; kill -SEGV $$")
        let asked = ContinuousClock.now
        let end = try #require(await exit.end(within: .seconds(5)))
        let waited = ContinuousClock.now - asked
        #expect(end == ChildExit.End(status: 11, reason: .uncaughtSignal))
        // On its exit, not at the next 50 ms tick or at the two seconds.
        #expect(waited < .milliseconds(1500))
        let (kind, code) = ChromiumProcess.helperEnd(endedBy: .disconnected, exit: end, starting: false)
        #expect(kind == .signal && code == 11)
    }

    @Test func anExitBeforeAnyoneWaitsIsKept() async throws {
        let (child, exit) = try shell("exit 3")
        child.waitUntilExit()
        let end = await exit.end(within: .seconds(5))
        #expect(end == ChildExit.End(status: 3, reason: .exit))
        #expect(ChromiumProcess.helperEnd(endedBy: nil, exit: end, starting: false) == (.exited, 3))
    }

    @Test func aHelperStillUpIsTheLinesLossAndItsLaterEndStillComes() async throws {
        let (child, exit) = try shell("sleep 30")
        defer { if child.isRunning { child.terminate() } }
        let asked = ContinuousClock.now
        #expect(await exit.end(within: .milliseconds(300)) == nil)
        #expect(ContinuousClock.now - asked >= .milliseconds(300))
        #expect(ChromiumProcess.helperEnd(endedBy: .transport(""), exit: nil, starting: false) == (.transport, nil))
        #expect(ChromiumProcess.helperEnd(endedBy: nil, exit: nil, starting: false) == (.disconnected, nil))
        child.terminate()
        #expect(await exit.end(within: .seconds(5)) == ChildExit.End(status: 15, reason: .uncaughtSignal))
    }

    @Test func manyWaitOnOneEnd() async throws {
        let (_, exit) = try shell("sleep 0.2; exit 0")
        let ends = await withTaskGroup(of: ChildExit.End?.self) { group in
            for _ in 0..<5 { group.addTask { await exit.end(within: .seconds(5)) } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(ends.count == 5 && ends.allSatisfy { $0 == ChildExit.End(status: 0, reason: .exit) })
    }

    @Test func theClientsRefusalComesFirstThenTheSignalThenStarting() {
        let crash = ChildExit.End(status: 9, reason: .uncaughtSignal)
        #expect(ChromiumProcess.helperEnd(endedBy: .protocolViolation("x"), exit: crash, starting: false) == (.protocolViolation, 9))
        #expect(ChromiumProcess.helperEnd(endedBy: nil, exit: crash, starting: true) == (.signal, 9))
        #expect(ChromiumProcess.helperEnd(endedBy: nil, exit: ChildExit.End(status: 1, reason: .exit), starting: true) == (.notStarted, 1))
        #expect(ChromiumProcess.helperEnd(endedBy: nil, exit: nil, starting: true) == (.notStarted, nil))
    }
}
