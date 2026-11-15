import Foundation
import Testing
@testable import Fast
@testable import YabUpdate

struct CortexBehaviorTests {
    @Test func disabledHistoriesDoNotEvenDiscoverBrowsers() {
        for ownOnly in [false, true] {
            let sources = OtherHistory.sources(choices: ["Chrome": false], ownOnly: ownOnly) {
                Issue.record("Browser discovery ran without a history opt-in")
                return []
            }
            #expect(sources.isEmpty)
        }
        #expect(OtherHistory.sources(choices: ["Chrome": true], ownOnly: true) {
            Issue.record("Own-only world inspected another browser")
            return []
        }.isEmpty)
    }

    @Test func historyOptInSelectsOnlyTheNamedSource() {
        let chrome = Chromium.known.first { $0.name == "Chrome" }!
        let arc = Chromium.known.first { $0.name == "Arc" }!
        var discoveries = 0
        let sources = OtherHistory.sources(choices: ["Chrome": true], ownOnly: false) {
            discoveries += 1
            return [arc, chrome]
        }
        #expect(discoveries == 1)
        #expect(sources == [chrome])
        #expect(!sources[0].credentialAccess)
    }

    @Test func browserDiscoveryDoesNotRequireInspectingAProfile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cortex-discovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Even an empty container is offered without looking for profile
        // markers. Its contents are inspected only by the chosen operation.
        let source = Chromium.Source(name: "Fixture", folder: "Fixture", service: "Fixture Safe Storage",
                                     account: "Fixture", bundle: "dev.yab.tests.absent-browser", dataRoot: root)
        #expect(Chromium.installed(among: [source]) == [source])
    }

    @MainActor @Test func passiveAgentDiscoveryDoesNotRunLoginScripts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cortex-shell-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = root.appendingPathComponent("login-shell")
        let marker = root.appendingPathComponent("executed")
        try "#!/bin/sh\n/usr/bin/touch \"$MARKER\"\nprintf '__yab_agent__\\n/usr/bin:/bin\\n__yab_token__\\nfixture-token\\n__yab_token__\\n'\n"
            .write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)
        let env = ["HOME": root.path, "SHELL": shell.path, "PATH": "/usr/bin:/bin", "MARKER": marker.path]
        let passive = await Shell.discover(environment: env, resolvingLogin: false)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(!passive.late)
        let active = await Shell.discover(environment: env, resolvingLogin: true)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(active.env[Shell.claudeToken] == "fixture-token")
    }

    @Test func restartCannotRunAnArbitraryCommandOrTarget() throws {
        let request = try #require(Relaunch.Request(arguments: [Relaunch.flag, "42", "--background"]))
        #expect(request.pid == 42 && request.behind)
        for args in [[], [Relaunch.flag], [Relaunch.flag, "0"], [Relaunch.flag, "-1"],
                     [Relaunch.flag, "42", "/tmp/fake.app"], [Relaunch.flag, "42", "-c", "echo nope"]] {
            #expect(Relaunch.Request(arguments: args) == nil)
        }
        #expect(Relaunch.environment(["YAB_PROBE": "isolated", "YAB_HISTORY": "own", "DYLD_INSERT_LIBRARIES": "/tmp/injected.dylib",
                                     "ANTHROPIC_API_KEY": "fixture", "PATH": "/tmp"]) == ["YAB_PROBE": "isolated", "YAB_HISTORY": "own"])
    }

    /// The restart waits for whatever LaunchServices files under this bundle
    /// or the one a swap set aside (YabCore winding down, register 2596),
    /// never for a copy of Yab anywhere else.
    @Test func restartWaitsOnlyForThisBundleAndTheOneSetAside() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("relaunch-\(UUID().uuidString)")
        let here = folder.appendingPathComponent("yab.app"), aside = folder.appendingPathComponent("yab.app.old")
        try FileManager.default.createDirectory(at: here, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let link = folder.appendingPathComponent("link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: here)
        #expect(Relaunch.contains([here, aside], here))
        #expect(Relaunch.contains([here, aside], aside))
        #expect(Relaunch.contains([here, aside], link))
        #expect(Relaunch.contains([here, aside], URL(fileURLWithPath: here.path + "/")))
        #expect(!Relaunch.contains([here, aside], folder.appendingPathComponent("yab Dev.app")))
        #expect(!Relaunch.contains([here, aside], nil))
    }

    /// A pid already gone is exited at once; a running one is not, until it goes.
    @Test func restartSeesAnExitFromTheKernel() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        #expect(!(await Relaunch.exited(child.processIdentifier, by: Date().addingTimeInterval(0.3))))
        child.terminate()
        #expect(await Relaunch.exited(child.processIdentifier, by: Date().addingTimeInterval(5)))
        child.waitUntilExit()
        #expect(await Relaunch.exited(child.processIdentifier, by: Date().addingTimeInterval(1)))
    }
}
