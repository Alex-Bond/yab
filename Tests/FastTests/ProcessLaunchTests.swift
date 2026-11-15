import Foundation
import Testing
@testable import Fast
import YabStore

struct ProcessLaunchTests {
    @Test(arguments: ["", "relative-tool", "/missing-yab-launch-tool", "/tmp", "/bin/echo\0hidden"])
    func invalidBinaryReturnsFailure(_ binary: String) async {
        let ran = await Shell.timed(binary, [], env: [:])
        #expect(ran.code == -1)
        #expect(!ran.late)
        #expect(!ran.diagnostic.isEmpty)
    }

    @Test func invalidDirectoriesReturnFailure() async {
        for path in ["/missing-yab-working-directory", "/bin/echo", "/tmp/\0invalid"] {
            let ran = await Shell.timed("/bin/echo", ["should not run"], env: [:], in: URL(fileURLWithPath: path))
            #expect(ran.code == -1)
            #expect(ran.output.isEmpty)
            #expect(!ran.late)
        }
    }

    @Test func nonExecutableFileReturnsFailure() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("test".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(await Shell.timed(file.path, [], env: [:]).code == -1)
    }

    /// Out of file descriptors getcwd fails, and FileManager's
    /// currentDirectoryPath is nil: URL(fileURLWithPath:) on it raised an
    /// Objective-C exception inside the check meant to keep them out (seen
    /// while reproducing crashes #853/#1501). Now a Swift error.
    @Test func anUnreadableWorkingDirectoryIsAnError() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/echo")
        #expect(throws: ProcessLaunch.Invalid.self) { try ProcessLaunch.validate(process, cwd: { nil }) }
        #expect(ProcessLaunch.workingDirectory() != nil)
        #expect(throws: Never.self) { try ProcessLaunch.validate(process) }
    }

    @Test func validLaunchStillWorks() async {
        let ran = await Shell.timed("/bin/echo", ["hello"], env: [:], in: URL(fileURLWithPath: "/tmp"))
        #expect(ran.code == 0)
        #expect(ran.output == "hello\n")
    }

    @Test func providerPermitCannotBypassValidation() throws {
        let settings = UserDefaults(suiteName: "ProcessLaunchTests." + UUID().uuidString)!
        let permit = ProviderLaunchPermit.connection(authority: "test", cli: "codex", settings: settings)
        defer { permit.cancelConnection() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/tmp")
        #expect(throws: ProcessLaunch.Invalid.self) { try permit.start(process) }
        #expect(!process.isRunning)
    }

    @Test func staleLoginShellFallsBack() {
        for candidate in ["", "zsh", "/missing-homebrew/bin/zsh", "/tmp", "/bin/zsh\0bad"] {
            #expect(Shell.loginShell(candidate) == "/bin/zsh")
        }
        #expect(Shell.loginShell("/bin/bash") == "/bin/bash")
    }
}
