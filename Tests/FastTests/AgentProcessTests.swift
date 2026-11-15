import Foundation
import Testing
@testable import Fast

// Ending an agent's process ends everything it started: a real tree of
// shells and sleeps, one part of it deaf to SIGTERM, leaves nothing behind.
struct AgentProcessTests {
    /// Starts bash with this script and reads the pids it prints, one a line.
    private func tree(_ script: String, lines: Int) throws -> (Process, [pid_t]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        var text = ""
        let until = Date().addingTimeInterval(10)
        while text.split(separator: "\n").count < lines, Date() < until {
            let chunk = out.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            text += String(decoding: chunk, as: UTF8.self)
        }
        let pids = text.split(separator: "\n").compactMap { pid_t(String($0)) }
        return (process, [process.processIdentifier] + pids)
    }

    private func gone(_ pids: [pid_t], within seconds: Double) async -> [pid_t] {
        let until = Date().addingTimeInterval(seconds)
        var left = pids
        while true {
            // kill(_, 0) also finds a zombie: wait for each to be reaped.
            left = left.filter { kill($0, 0) == 0 || errno != ESRCH }
            if left.isEmpty || Date() > until { return left }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func end(_ process: Process, grace: TimeInterval) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Shell.end(process, grace: grace) { done.resume() }
        }
    }

    @Test func endingLeavesNoSurvivorEvenOneThatIgnoresTerm() async throws {
        let script = """
        sleep 300 & echo $!
        bash -c 'trap "" TERM; sleep 300 & echo $!; echo $$; wait' &
        wait
        """
        let (process, pids) = try tree(script, lines: 3)
        #expect(pids.count == 4)
        // Collected before anything is told to stop, deepest last.
        let known = Shell.descendants(of: process.processIdentifier).map(\.pid)
        #expect(known.first == process.processIdentifier)
        #expect(Set(pids).isSubset(of: Set(known)))
        await end(process, grace: 0.3)
        #expect(await gone(pids, within: 5).isEmpty)
    }

    @Test func aTreeThatListensEndsWellBeforeItsGrace() async throws {
        let script = """
        sleep 300 & echo $!
        bash -c 'sleep 300 & echo $!; echo $$; wait' &
        wait
        """
        let (process, pids) = try tree(script, lines: 3)
        let began = Date()
        await end(process, grace: 30)
        #expect(Date().timeIntervalSince(began) < 10)
        #expect(await gone(pids, within: 5).isEmpty)
    }

    @Test func aProcessThatHasGoneEndsAtOnce() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        await end(process, grace: 30)
        #expect(Shell.descendants(of: process.processIdentifier).isEmpty)
    }
}
