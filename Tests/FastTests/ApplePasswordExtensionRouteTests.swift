import AppKit
import Foundation
import Testing
import YabCoreClient
@testable import Fast

@MainActor
@Suite(.serialized)
struct ApplePasswordExtensionRouteTests {
    let apple = PasswordManagers.apple

    @Test func webKitStoreAndSettingsPreparationRefuseBeforeFetching() async throws {
        _ = NSApplication.shared
        let previous = ApplePasswordExtensionRoute.handler
        let connected = ApplePasswordExtensionRoute.isConnected
        var actions: [ApplePasswordExtensionRoute.Action] = []
        ApplePasswordExtensionRoute.handler = { actions.append($0) }
        ApplePasswordExtensionRoute.isConnected = { false }
        defer { ApplePasswordExtensionRoute.handler = previous; ApplePasswordExtensionRoute.isConnected = connected }
        let list = Extensions(signIn: UUID())
        defer { try? FileManager.default.removeItem(at: Extensions.list(of: list.signIn)) }
        for text in [apple, "https://chromewebstore.google.com/detail/icloud-passwords/" + apple] {
            list.install(from: text)
            do {
                _ = try await list.prepare(link: text)
                Issue.record("Apple extension prepared for installation")
            } catch is CancellationError { }
        }
        ManagerExtensions.shared.add(apple)
        #expect(actions == Array(repeating: .connect, count: 5))
        #expect(list.installed.isEmpty && list.contexts.isEmpty)
        #expect(list.busy == nil && list.installErrors.isEmpty)
    }

    @Test func importsAreRefusedBeforeReadingPackagesAndStagingIsDiscarded() async throws {
        _ = NSApplication.shared
        let previous = ApplePasswordExtensionRoute.handler
        var count = 0
        ApplePasswordExtensionRoute.handler = { _ in count += 1 }
        defer { ApplePasswordExtensionRoute.handler = previous }
        let list = Extensions(signIn: UUID())
        defer { try? FileManager.default.removeItem(at: Extensions.list(of: list.signIn)) }
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        let candidate = Extensions.Candidate(id: apple, fromStore: true, staged: staged, source: nil,
            name: "iCloud Passwords", version: "1", about: "", icon: nil, wants: [], extras: [], shortcuts: 0)
        #expect(!(await list.add(candidate)))
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        let item = Installed(id: apple, name: "iCloud Passwords", version: "1", enabled: true, fromStore: true, permissions: [])
        let results = try await ChromiumExtensionImport.run([item], installed: [], pending: [],
            journal: { #expect($0.isEmpty) }, install: { _ in Issue.record("Fetched Apple extension") },
            enable: { _, _ in Issue.record("Enabled Apple extension") }, remember: { _ in Issue.record("Remembered Apple extension") })
        #expect(results.map(\.state) == [.blocked])
        #expect(count == 2)
        #expect(list.installed.isEmpty)
    }

    @Test func chromiumDirectStoreReviewAndCandidateRoutesRefuseBeforeCEF() async throws {
        _ = NSApplication.shared
        let previous = ApplePasswordExtensionRoute.handler
        var count = 0
        ApplePasswordExtensionRoute.handler = { _ in count += 1 }
        defer { ApplePasswordExtensionRoute.handler = previous }
        let native = ChromiumExtensions(profile: UUID().uuidString, privateMode: false)
        do { _ = try await native.install(Data(), id: apple); Issue.record("Installed invalid Apple package") }
        catch is CancellationError { }
        do { _ = try await native.installFromStore(apple); Issue.record("Fetched Apple package") }
        catch is CancellationError { }
        try await native.setEnabled(apple, true)
        let browser = Browser(windowID: UUID())
        native.reviewInstall(apple, browser: browser)
        let list = Extensions(signIn: UUID())
        defer { try? FileManager.default.removeItem(at: Extensions.list(of: list.signIn)) }
        let candidate = Extensions.Candidate(id: apple, fromStore: true,
            staged: URL(fileURLWithPath: "/nonexistent-apple-package"), source: nil,
            name: "iCloud Passwords", version: "1", about: "", icon: nil, wants: [], extras: [], shortcuts: 0)
        do { try await native.add(candidate, into: list); Issue.record("Imported Apple package into Chromium") }
        catch is CancellationError { }
        ChromiumColumn.shared.press(apple, tab: Tab())
        #expect(count == 6)
        #expect(native.items.isEmpty && native.failure == nil && !native.busy)
        for operation in ["install", "reenable", "uninstall", "permissions"] {
            let request = ChromiumConsentRequest(request: "fixture", profile: "fixture", operation: operation,
                extensionID: apple, displayName: "iCloud Passwords", version: "1", manifestSHA256: nil, warnings: [], tab: nil)
            #expect(ChromiumConsent.redirectsToApplePasswords(request) == ["install", "reenable"].contains(operation))
        }
    }

    @Test func webKitLaunchDisablesWithoutRemovingOrPromptingAndRestartDoesNotRewrite() throws {
        _ = NSApplication.shared
        let previous = ApplePasswordExtensionRoute.handler
        ApplePasswordExtensionRoute.handler = { _ in Issue.record("Launch opened connection UI") }
        defer { ApplePasswordExtensionRoute.handler = previous }
        let signIn = UUID(), file = Extensions.list(of: signIn)
        defer { try? FileManager.default.removeItem(at: file) }
        let appleItem = Installed(id: apple, name: "iCloud Passwords", version: "1", enabled: true,
            fromStore: true, permissions: ["nativeMessaging"], pinned: true)
        let other = Installed(id: PasswordManagers.onePassword, name: "1Password", version: "1", enabled: true, fromStore: true, permissions: [])
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode([appleItem, other]).write(to: file)
        let list = Extensions(signIn: signIn)
        var disabled = appleItem; disabled.enabled = false
        #expect(list.installed == [disabled, other])
        #expect(list.contexts[apple] == nil)
        let bytes = try Data(contentsOf: file)
        let modified = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let reopened = Extensions(signIn: signIn)
        #expect(reopened.installed == list.installed)
        #expect(try Data(contentsOf: file) == bytes)
        #expect(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified)
    }

    @Test func bringInFromChromeArcAndDiaSkipsTheApplePackage() async throws {
        _ = NSApplication.shared
        let previous = ApplePasswordExtensionRoute.handler
        var count = 0
        ApplePasswordExtensionRoute.handler = { _ in count += 1 }
        defer { ApplePasswordExtensionRoute.handler = previous }
        let list = Extensions(signIn: UUID())
        defer { try? FileManager.default.removeItem(at: Extensions.list(of: list.signIn)) }
        let item = Chromium.Extension(id: apple, name: "iCloud Passwords", fromStore: true, enabled: true,
            folder: URL(fileURLWithPath: "/nonexistent-apple-package"), iconFile: nil)
        for source in ["Chrome", "Arc", "Dia"] {
            #expect(await list.bring([item], from: source, step: { _ in }).isEmpty)
        }
        #expect(count == 3 && list.installed.isEmpty && list.contexts.isEmpty)
    }

    @Test func notNowDoesNotCreateAConnectionOrInstallAnExtension() async throws {
        _ = NSApplication.shared
        let wasHandler = ApplePasswordExtensionRoute.handler
        let wasConnected = ApplePasswordExtensionRoute.isConnected
        let wasPair = ApplePasswordExtensionRoute.pair
        let before = PasswordManagers.Connections.shared.connection(apple)
        var pairs = 0
        ApplePasswordExtensionRoute.handler = nil
        ApplePasswordExtensionRoute.isConnected = { false }
        ApplePasswordExtensionRoute.pair = { pairs += 1; return false }
        defer {
            ApplePasswordExtensionRoute.handler = wasHandler
            ApplePasswordExtensionRoute.isConnected = wasConnected
            ApplePasswordExtensionRoute.pair = wasPair
        }
        let list = Extensions(signIn: UUID())
        defer { try? FileManager.default.removeItem(at: Extensions.list(of: list.signIn)) }
        list.install(from: apple)
        for _ in 0..<20 where pairs == 0 { await Task.yield() }
        #expect(pairs == 1 && list.installed.isEmpty)
        #expect(PasswordManagers.Connections.shared.connection(apple) == before)
    }

    @Test func chromiumLaunchSwitchesOnlyEnabledAppleRowsAndDoesNotRepeat() async throws {
        func row(_ id: String, _ state: String) throws -> ChromiumExtensions.Item {
            try ChromiumExtensions.Item(.object(["id": .string(id), "name": .string("Fixture"), "state": .string(state)]))
        }
        var switches: [String] = []
        let on = try row(apple, "ENABLED"), other = try row(PasswordManagers.onePassword, "ENABLED")
        #expect(try await ChromiumExtensions.quietAppleExtensions([on, other]) { switches.append($0) })
        #expect(switches == [apple])
        let off = try row(apple, "DISABLED")
        #expect(!(try await ChromiumExtensions.quietAppleExtensions([off, other]) { _ in Issue.record("Repeated disable") }))
        #expect(off.id == on.id)
    }

    @Test func toolbarAndConnectedInstallUseExistingEffectsWithoutInstalling() async throws {
        _ = NSApplication.shared
        let previous = ApplePasswordExtensionRoute.handler
        let wasConnected = ApplePasswordExtensionRoute.isConnected
        var actions: [ApplePasswordExtensionRoute.Action] = []
        ApplePasswordExtensionRoute.handler = { actions.append($0) }
        defer { ApplePasswordExtensionRoute.handler = previous; ApplePasswordExtensionRoute.isConnected = wasConnected }
        ApplePasswordExtensionRoute.isConnected = { false }
        let list = Extensions(signIn: UUID())
        defer { try? FileManager.default.removeItem(at: Extensions.list(of: list.signIn)) }
        list.takeNative(id: apple, name: "iCloud Passwords", version: "1", enabled: true)
        #expect(list.installed.first?.enabled == false)
        #expect(list.buttons.contains { $0.id == apple && $0.enabled })
        list.press(apple)
        #expect(actions == [.connect])
        ApplePasswordExtensionRoute.isConnected = { true }
        list.install(from: apple)
        #expect(actions == [.connect, .alreadyOn])
        #expect(!list.buttons.contains { $0.id == apple })
        #expect(list.installed.count == 1 && list.installed.first?.enabled == false)
        #expect(!ApplePasswordExtensionRoute.intercept(PasswordManagers.onePassword))
        let question = ApplePasswordsPairing.connectQuestion(model: ApplePasswordsPairing.CodeModel())
        #expect(question.title == "Connect Apple Passwords" && question.no == "Not Now")
        #expect(question.yes.isEmpty && question.accessory != nil)
    }
}
