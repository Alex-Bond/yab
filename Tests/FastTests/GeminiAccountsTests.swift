import AppKit
import Foundation
import WebKit
import Testing
@testable import Fast

@Suite(.serialized)
@MainActor
struct GeminiAccountsTests {
    /// agy 1.4.4's own screens and Antigravity's callback markup, captured
    /// 2026-10-29 (docs/evidence/gemini-real-code-2026-10-29 has the rest).
    private static var evidence: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/gemini-agy-1.4.4")
    }

    @Test func macThenGoogleThenAnotherWithCaseInsensitiveDuplicates() {
        let space = UUID()
        let rows = GeminiChoices.rows(local: GeminiIdentity(email: "Personal@Gmail.com", plan: "Google AI Pro"), google: [
            .init(email: "personal@gmail.com", name: "Personal", photo: nil, space: space),
            .init(email: "work@example.com", name: "Work", photo: nil, space: space),
            .init(email: "WORK@example.com", name: "Same", photo: nil, space: UUID())
        ], excluding: [])
        #expect(rows.map(\.source) == [.mac, .space(space), .another])
        #expect(rows.map(\.email) == ["Personal@Gmail.com", "work@example.com", nil])
        let switching = GeminiChoices.rows(local: GeminiIdentity(email: "Personal@Gmail.com"), google: [
            .init(email: "PERSONAL@gmail.com", name: "Same", photo: nil, space: space)
        ], excluding: ["personal@gmail.com"])
        #expect(switching == [.another])
    }

    @Test func identityComesOnlyFromTheCLIHeader() {
        #expect(GeminiIdentity.read("https://accounts.google.com/o/oauth2/auth?login_hint=chosen@example.com\n") == nil)
        #expect(GeminiIdentity.read("Account: chosen@example.com\n") == nil)
        let header = "\u{1b}[32mAntigravity CLI 1.4.7\u{1b}[0m\r\n▀▀ actual@example.com\r\n/workspace\r\n? for shortcuts\n(Antigravity Starter Quota)"
        #expect(GeminiIdentity.read(header) == GeminiIdentity(email: "actual@example.com", plan: "Antigravity Starter Quota"))
    }

    @Test func planRowSaysTheTierOnly() {
        #expect(PlanAccounts.tier("gemini", "Antigravity Starter Quota") == "Starter")
        #expect(PlanAccounts.tier("gemini", "Google AI Pro") == "Google AI Pro")
    }

    @Test func quotaUsesOnlyGeminiAndNeverConfusesRemainingWithUsed() throws {
        let output = #"{"status":"SUCCESS","command":{"name":"usage","data":{"groups":[{"name":"Gemini Models","buckets":[{"id":"gemini-weekly","remaining_fraction":0.76,"reset_time":"2026-11-02T06:06:12Z"}]},{"name":"Claude and GPT models","buckets":[{"id":"3p-weekly","remaining_fraction":0}]}]}}}"#
        let quota = try #require(GeminiQuota.read(output))
        #expect(abs((quota.used ?? 0) - 0.24) < 0.0001)
        #expect(quota.out == nil && quota.windows?.count == 1)
        let fixture = IsolatedProviderConsent("gemini")
        defer { fixture.close() }
        let plans = PlanAccounts(settings: fixture.settings, consent: fixture.consent)
        plans.heard(gemini: quota)
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        #expect(abs((plans.fullest("gemini", now: now) ?? 0) - 0.24) < 0.0001)
        #expect(plans.windows("gemini", now: now).map(\.name) == ["gemini-weekly"])
        #expect(quota.resets == ISO8601DateFormatter().date(from: "2026-11-02T06:06:12Z"))
        #expect(GeminiQuota.read(output.replacingOccurrences(of: "0.76", with: "2")) == nil)
        #expect(GeminiQuota.read(output.replacingOccurrences(of: "SUCCESS", with: "ERROR")) == nil)
    }

    @Test func hintPreservesTheCLIStateAndCallback() throws {
        let url = try #require(URL(string: "https://accounts.google.com/o/oauth2/auth?state=cli-state&redirect_uri=http%3A%2F%2Flocalhost%3A1234%2Fauth%2Fcallback&login_hint=old"))
        let hinted = GeminiLogin.hinted(url, email: "name+work@example.com")
        let items = try #require(URLComponents(url: hinted, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.filter { $0.name == "login_hint" }.map(\.value) == ["name+work@example.com"])
        #expect(items.first { $0.name == "state" }?.value == "cli-state")
        #expect(items.first { $0.name == "redirect_uri" }?.value == "http://localhost:1234/auth/callback")
        let encoded = try #require(URL(string: "https://accounts.google.com/o/oauth2/auth?state=a%2Bb%2Fc%3D&scope=one+two&redirect_uri=http%3A%2F%2Flocalhost%3A1234%2Fauth%2Fcallback"))
        let query = try #require(URLComponents(url: GeminiLogin.hinted(encoded, email: "name+work@example.com"), resolvingAgainstBaseURL: false)?.percentEncodedQuery)
        #expect(query.hasPrefix("state=a%2Bb%2Fc%3D&scope=one+two&redirect_uri=http%3A%2F%2Flocalhost%3A1234%2Fauth%2Fcallback&"))
        #expect(query.hasSuffix("login_hint=name%2Bwork@example.com"))
    }

    @Test func switchingClearsOldReadinessBeforeReturningAndCancelPreventsTheLaunch() async throws {
        let fixture = IsolatedProviderConsent("gemini")
        defer { fixture.close() }
        let account = GeminiAccount(binary: "/fixture/not-a-real-agy")
        account.pretend(binary: "/fixture/not-a-real-agy", signedIn: true, models: "gemini-fixture")
        account.choice = .another
        account.signIn(permit: try #require(fixture.consent.permit("gemini")))
        #expect(!account.ready && account.waiting == .signingIn)
        account.cancel()
        await Task.yield()
        #expect(!account.ready && account.waiting == nil)
        #expect(account.trouble?.contains("canceled") == true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-retry-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Library/Keychains"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("agy-fixture")
        try "#!/bin/sh\nif [ \"$1\" = models ]; then echo 'gemini-fixture Gemini Fixture'; else echo 'Gemini quota: 90% remaining'; fi\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        await account.look(fresh: true, permit: try #require(fixture.consent.permit("gemini")),
            find: { _ in Shell.Found(claude: nil, gemini: binary.path, env: ["HOME": root.path, "PATH": "/usr/bin:/bin"]) },
            profile: root.appendingPathComponent("profile"))
        #expect(account.ready && account.trouble == nil, "A verified retry clears the old error in Plans too")
        #expect(!GeminiAccount.authenticated(Shell.Ran(code: 0, output: #"{"status":"SUCCESS","response":""}"#, late: false)))
    }

    @Test func signInKeepsTheFreshCLIReasonWhenNoBrowserPageOpens() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-reason-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Library/Keychains"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("agy-fixture")
        try "#!/bin/sh\nprintf 'Error: Please sign in to view available models.\\n'\nexit 1\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let fixture = IsolatedProviderConsent("gemini")
        defer { fixture.close() }
        let permit = try #require(fixture.consent.permit("gemini"))
        let account = GeminiAccount(binary: binary.path)
        await account.look(fresh: true, permit: permit,
            find: { _ in Shell.Found(claude: nil, gemini: binary.path, env: ["HOME": root.path, "PATH": "/usr/bin:/bin"]) },
            profile: root.appendingPathComponent("profile"))
        #expect(account.lastSaid?.contains("Please sign in") == true)
        account.signIn(permit: permit)
        #expect(account.lastSaid?.contains("Please sign in") == true)
        account.cancel()
        await Task.yield()
    }

    @Test func googleDiscoveryAlsoIncludesAccountsAlreadyConnectedToMail() async {
        let previous = MailFound.fake
        defer { MailFound.fake = previous }
        let account = MailFound.Account(email: "mail@example.com", name: "Mail", photo: nil, space: UUID())
        MailFound.fake = [account]
        let browser = Browser()
        let found = await MailFound.shared.discover(browser)
        #expect(found == [account])
    }

    @Test func nativeSwitchUsesTheCLILogoutAndCapturesItsBrowserWithoutTerminal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-login-" + UUID().uuidString)
        let loginHome = root.appendingPathComponent("login")
        try FileManager.default.createDirectory(at: loginHome.appendingPathComponent("Library/Keychains"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("agy-fixture")
        try #"""
        #!/bin/sh
        printf 'Antigravity CLI 1.4.7\r\n old@example.com\r\n? for shortcuts\r\n'
        IFS= read -r command
        [ "$command" = /logout ] || exit 7
        "$BROWSER" 'https://accounts.google.com/o/oauth2/auth?state=cli-state'
        fixture_ready="${0%/*}/authenticated"
        while [ ! -f "$fixture_ready" ]; do sleep 0.05; done
        printf 'Antigravity CLI 1.4.7\r\n actual@example.com\r\n(Antigravity Starter Quota)\r\n'
        IFS= read -r unused
        """#.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let fixture = IsolatedProviderConsent("gemini")
        defer { fixture.close() }
        let signer = GeminiLogin()
        defer { signer.stop() }
        let authenticated = root.appendingPathComponent("authenticated")
        try signer.start(binary: binary.path, profile: root.appendingPathComponent("profile"),
                         base: ["HOME": loginHome.path, "PATH": "/usr/bin:/bin"], switching: true,
                         permit: try #require(fixture.consent.permit("gemini")))
        let until = Date().addingTimeInterval(8)
        while Date() < until, signer.authorizationURL == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(signer.loggedOut && signer.identity == nil, "A browser URL cannot confirm the old header as the new login")
        try Data().write(to: authenticated)
        while Date() < until, signer.identity?.email != "actual@example.com" || signer.authorizationURL == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(signer.loggedOut)
        #expect(signer.authorizationURL?.host == "accounts.google.com")
        #expect(signer.identity?.email == "actual@example.com")
        signer.stop()
        #expect(signer.finished && signer.authorizationURL == nil)
    }

    @Test func printedSignInLinkIsTheOAuthPageWhenNoLauncherRuns() throws {
        let screen = try String(contentsOf: Self.evidence.appendingPathComponent("agy-1.4.4-tui.ansi"), encoding: .utf8)
        let url = try #require(GeminiLogin.printedURL(screen))
        #expect(url.host == "accounts.google.com" && url.path == "/o/oauth2/auth")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "redirect_uri" }?.value == "https://antigravity.google/oauth-callback")
        #expect(items.contains { $0.name == "state" } && items.contains { $0.name == "code_challenge" })
        let link = { (address: String) in "\u{1B}]8;;\(address)\u{1B}\\Click\u{1B}]8;;\u{1B}\\" }
        #expect(GeminiLogin.printedURL(link("https://evil.example/o/oauth2/auth?redirect_uri=x&state=y")) == nil)
        #expect(GeminiLogin.printedURL(link("https://accounts.google.com/o/oauth2/auth?state=y")) == nil)
        #expect(GeminiLogin.printedURL(link("https://accounts.google.com/o/oauth2/auth?redirect_uri=x&state=y")) != nil)
        #expect(GeminiLogin.printedURL("Select login method:") == nil)
    }

    @Test func loginMethodAcceptsUnnumberedSelectedGoogleRow() {
        #expect(GeminiLogin.googleSelected("Select login method:\r\n \u{276F} Google OAuth\r\n   Other sign-in options\r\n"))
        #expect(!GeminiLogin.googleSelected("Select login method:\r\n   Google OAuth\r\n \u{276F} Other sign-in options\r\n"))
    }

    @Test func loginMethodRequiresTheSelectedGoogleOAuthRow() {
        let menu = "Select login method:\r\n > 1. Google OAuth\r\n   2. Use a Google Cloud project\r\n"
        #expect(GeminiLogin.googleSelected(menu))
        #expect(!GeminiLogin.googleSelected(menu.replacingOccurrences(of: "> 1.", with: "  1.")
            .replacingOccurrences(of: "  2.", with: "> 2.")))
        #expect(!GeminiLogin.googleSelected(" > 1. Google OAuth\r\n"))
        #expect(!GeminiLogin.googleSelected("Select login method:\r\n > 1. Google"))
    }

    @Test func nativeSignInConfirmsGoogleBeforeWaitingForItsBrowserURL() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-method-" + UUID().uuidString)
        let home = root.appendingPathComponent("login")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Keychains"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("agy-fixture")
        try #"""
        #!/bin/sh
        printf 'Select login met'
        sleep 0.05
        printf 'hod:\r\n \033[32m> 1. Google OAuth\033[0m\r\n   2. Use a Google Cloud project\r\n'
        IFS= read -r method
        [ -z "$method" ] || exit 7
        "$BROWSER" 'https://accounts.google.com/o/oauth2/auth?state=fixture-method'
        IFS= read -r unused
        """#.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let fixture = IsolatedProviderConsent("gemini")
        defer { fixture.close() }
        let signer = GeminiLogin()
        defer { signer.stop() }
        try signer.start(binary: binary.path, profile: root.appendingPathComponent("profile"),
                         base: ["HOME": home.path, "PATH": "/usr/bin:/bin"], switching: false, signingIn: true,
                         permit: try #require(fixture.consent.permit("gemini")))
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, signer.authorizationURL == nil, !signer.finished {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(signer.authorizationURL?.query == "state=fixture-method",
                "The hidden CLI must confirm its Google method before a sign-in tab can open")
        #expect(!signer.finished && signer.identity == nil)
    }

    @Test func signInOwnsItsRowAndFindsATabWaitingForItsFirstFrame() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-row-" + UUID().uuidString)
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Keychains"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("agy-fixture")
        try #"""
        #!/bin/sh
        "$BROWSER" 'https://accounts.google.com/o/oauth2/auth?state=fixture-row'
        IFS= read -r unused
        """#.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let fixture = IsolatedProviderConsent("gemini")
        defer { fixture.close() }
        let signer = GeminiLogin()
        defer { signer.stop() }
        try signer.start(binary: binary.path, profile: root.appendingPathComponent("profile"),
                         base: ["HOME": home.path, "PATH": "/usr/bin:/bin"], switching: false, signingIn: true,
                         permit: try #require(fixture.consent.permit("gemini")))
        let deadline = Date().addingTimeInterval(8)
        while signer.authorizationURL == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        _ = try #require(signer.authorizationURL)
        let screen = try #require(TestScreen.screen)
        let sharing = Spaces.sharing
        let foldersBrowser = Folders.shared.browser
        defer { Spaces.sharing = sharing; Folders.shared.browser = foldersBrowser }
        let browser = Browser(windowID: UUID())
        let window = NSWindow(contentRect: NSRect(origin: screen.visibleFrame.origin, size: NSSize(width: 800, height: 600)),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        BrowserWindows.shared.register(window, for: browser)
        defer { signer.stop(); window.close() }
        signer.openPage(in: browser, choice: .another)
        let tab = try #require(browser.tabs.first { $0.address?.host == "accounts.google.com" || $0.pending?.host == "accounts.google.com" })
        #expect(signer.opened && !signer.closed)
        // Model the first-frame staging interval independently of timing.
        browser.outside.append(tab)
        browser.lay(browser.tabs.filter { $0 !== tab })
        #expect(!signer.closed, "A tab waiting outside the row is still owned by this browser")
        browser.outside.removeAll { $0 === tab }
        browser.lay(browser.tabs + [tab])
        signer.show()
        #expect(browser.activeID == tab.id)
        #expect(window.isVisible)
        browser.close(tab)
        #expect(signer.closed, "A real close must still cancel the challenge")
    }

    @Test func anUnverifiedSharedHeaderIsReplacedBeforeOAuthStarts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-stale-header-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("agy-fixture")
        try #"""
        #!/bin/sh
        printf 'Antigravity CLI 1.4.7\r\n old@example.com\r\n? for shortcuts\r\n'
        IFS= read -r command
        [ "$command" = /logout ] || exit 7
        touch "${0%/*}/replaced"
        # Stop before OAuth opens: no window, real CLI or usage query runs.
        IFS= read -r unused
        """#.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let fixture = IsolatedProviderConsent("gemini")
        defer { fixture.close() }
        let account = GeminiAccount(binary: binary.path)
        defer { account.cancel() }
        account.choice = .another
        #expect(account.signedIn != true)
        account.signIn(permit: try #require(fixture.consent.permit("gemini")),
                       profile: root.appendingPathComponent("profile"))
        let replaced = root.appendingPathComponent("replaced").path
        let deadline = Date().addingTimeInterval(8)
        while !FileManager.default.fileExists(atPath: replaced), Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(FileManager.default.fileExists(atPath: replaced),
                "Unknown readiness must not leave the existing CLI waiting forever without OAuth")
        #expect(account.waiting == .signingIn && !account.ready)
    }

    @Test func aFreshOAuthHeaderIsNotLoggedOutWhenReadinessWasUnknown() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-fresh-" + UUID().uuidString)
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Keychains"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("agy-fixture")
        try #"""
        #!/bin/sh
        "$BROWSER" 'https://accounts.google.com/o/oauth2/auth?state=fixture-fresh'
        printf 'Antigravity CLI 1.4.7\r\n actual@example.com\r\n? for shortcuts\r\n'
        IFS= read -r unused
        """#.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let fixture = IsolatedProviderConsent("gemini")
        defer { fixture.close() }
        let signer = GeminiLogin()
        defer { signer.stop() }
        try signer.start(binary: binary.path, profile: root.appendingPathComponent("profile"),
                         base: ["HOME": home.path, "PATH": "/usr/bin:/bin"], switching: true, signingIn: true,
                         permit: try #require(fixture.consent.permit("gemini")))
        let deadline = Date().addingTimeInterval(8)
        while signer.identity == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        #expect(signer.identity?.email == "actual@example.com")
        #expect(!signer.loggedOut)
    }

    @Test func identityInspectionDoesNotChooseALoginMethod() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-inspect-" + UUID().uuidString)
        let home = root.appendingPathComponent("login")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Keychains"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("agy-fixture")
        try #"""
        #!/bin/bash
        printf 'Select login method:\r\n > 1. Google OAuth\r\n'
        if IFS= read -r -t 1 method; then
            "$BROWSER" 'https://accounts.google.com/o/oauth2/auth?state=unexpected-inspection'
        fi
        """#.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let fixture = IsolatedProviderConsent("gemini")
        defer { fixture.close() }
        let inspector = GeminiLogin()
        defer { inspector.stop() }
        try inspector.start(binary: binary.path, profile: root.appendingPathComponent("profile"),
                            base: ["HOME": home.path, "PATH": "/usr/bin:/bin"], switching: false,
                            permit: try #require(fixture.consent.permit("gemini")))
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, !inspector.finished {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(inspector.finished)
        #expect(inspector.authorizationURL == nil, "Reading identity must not start a new Google sign-in")
    }
    @Test func codePageRequiresTheCLIsExactHostedRedirect() throws {
        let auth = try #require(URL(string: "https://accounts.google.com/o/oauth2/auth?state=fixture&redirect_uri=https%3A%2F%2Fantigravity.google%2Foauth-callback"))
        let callback = try #require(URL(string: "https://antigravity.google/oauth-callback?code=fixture"))
        #expect(GeminiLogin.isCodePage(callback, authorization: auth))
        for other in ["http://antigravity.google/oauth-callback", "https://antigravity.google.evil.test/oauth-callback",
                      "https://evil.test/oauth-callback", "https://antigravity.google/other", "https://antigravity.google:8443/oauth-callback",
                      "https://name@antigravity.google/oauth-callback", "https://antigravity.google/oauth-callback?error=access_denied"] {
            #expect(!GeminiLogin.isCodePage(try #require(URL(string: other)), authorization: auth))
        }
        #expect(!GeminiLogin.isCodePage(callback, authorization: nil))
        let loopback = try #require(URL(string: "https://accounts.google.com/o/oauth2/auth?redirect_uri=http%3A%2F%2Flocalhost%3A1234%2Fauth%2Fcallback"))
        #expect(!GeminiLogin.isCodePage(callback, authorization: loopback), "Loopback OAuth remains owned by the CLI")
    }

    @Test func realCLIRequestsTheCodeDespiteCaseANSIAndWrapping() throws {
        let captured = try String(contentsOf: Self.evidence.appendingPathComponent("agy-1.4.4-tui.ansi"), encoding: .utf8)
        #expect(GeminiLogin.requestsCode(captured))
        #expect(GeminiLogin.requestsCode("If you aren't automatically redirected, paste the authorization\r\n code below:"))
        #expect(GeminiLogin.requestsCode("Enter the authorization code:"))
        let turnedDown = try String(contentsOf: Self.evidence.appendingPathComponent("agy-1.4.4-rejected.ansi"), encoding: .utf8)
        #expect(GeminiLogin.rejectsCode(turnedDown))
        #expect(!GeminiLogin.rejectsCode(captured), "The prompt itself is no rejection")
        #expect(!GeminiLogin.requestsCode("Select login method:"))
    }

    @Test func manualCodeNeedsNoCallbackAndReportsRejection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-paste-" + UUID().uuidString)
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Keychains"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // The stand-in replays agy 1.4.4's own screens: the login method
        // (Yab answers Google OAuth with Return), the code prompt, and its
        // answer to a code Google turned down, after which it stays open.
        let binary = root.appendingPathComponent("agy-fixture")
        let prompt = Self.evidence.appendingPathComponent("agy-1.4.4-tui.ansi").path
        let rejected = Self.evidence.appendingPathComponent("agy-1.4.4-rejected.ansi").path
        try """
        #!/bin/sh
        cat '\(prompt)'
        IFS= read -r method
        IFS= read -r code
        [ "$code" = '4/fixture_Code-12345' ] || exit 7
        cat '\(rejected)'
        IFS= read -r key
        exit 1
        """.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let fixture = IsolatedProviderConsent("gemini")
        defer { fixture.close() }
        let signer = GeminiLogin()
        defer { signer.stop() }
        #expect(!signer.submitCode("4/fixture_Code-12345"))
        try signer.start(binary: binary.path, profile: root.appendingPathComponent("profile"),
                         base: ["HOME": home.path, "PATH": "/usr/bin:/bin"], switching: false, signingIn: true,
                         permit: try #require(fixture.consent.permit("gemini")))
        let deadline = Date().addingTimeInterval(8)
        while !signer.awaitingCode, Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        // The launcher was never called; the page is the link agy 1.4.4
        // prints on its own screen (#1829, #1884).
        #expect(signer.awaitingCode && signer.authorizationURL?.host == "accounts.google.com")
        for invalid in ["", "https://example.com", "4/fixture_Code-12345\n/logout", "4/fixture_Code-12345\u{1b}[A"] {
            #expect(!signer.submitCode(invalid))
        }
        #expect(signer.submitCode(" 4/fixture_Code-12345 "))
        #expect(!signer.awaitingCode && signer.submittedCode)
        #expect(!signer.submitCode("4/fixture_Code-12345"))
        while signer.codeError == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        #expect(signer.codeError == GeminiLogin.rejectedCode, "The real invalid_grant screen reads as a rejected code")
        #expect(!signer.finished, "agy waits on Press any key, it doesn't exit")
        #expect(!signer.awaitingCode, "The echoed old prompt doesn't reopen the field")
        #expect(signer.identity == nil)
        signer.stop()
        #expect(!signer.submitCode("4/fixture_Code-12345"))
    }

    @Test func hostedPageExtractsOnlyTheDisplayedCompletionCode() async throws {
        let web = WKWebView()
        defer { web.stopLoading() }
        let html = try String(contentsOf: Self.evidence.appendingPathComponent("callback-fixture.html"), encoding: .utf8)
        web.loadHTMLString(html, baseURL: URL(string: "https://antigravity.google/oauth-callback"))
        let deadline = Date().addingTimeInterval(5)
        while web.isLoading, Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        let result = try await web.evaluateJavaScript(GeminiLogin.codePageScript) as? [String: String]
        #expect(result?["code"] == "4/fixture_Code-12345")
        _ = try await web.evaluateJavaScript("document.querySelector('.instructions').textContent = 'Kopieren Sie diesen Code'")
        let translated = try await web.evaluateJavaScript(GeminiLogin.codePageScript) as? [String: String]
        #expect(translated?["code"] == "4/fixture_Code-12345", "The code box works in any language")
        _ = try await web.evaluateJavaScript("document.body.innerHTML = '<pre>4/fixture_Code-12345</pre>'")
        let noPrompt = try await web.evaluateJavaScript(GeminiLogin.codePageScript)
        #expect(noPrompt == nil || noPrompt is NSNull, "An unrelated page cannot supply a code")
    }

    @Test func hostedCodeReachesTheWaitingCLIExactlyOnceAndCancelRejectsIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-code-" + UUID().uuidString)
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Keychains"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("agy-fixture")
        try #"""
        #!/bin/sh
        "$BROWSER" 'https://accounts.google.com/o/oauth2/auth?state=fixture&redirect_uri=https%3A%2F%2Fantigravity.google%2Foauth-callback'
        printf "If you aren't automatically redirected, paste the authorization code below:\r\n"
        IFS= read -r code
        [ "$code" = '4/fixture_Code-12345' ] || exit 7
        printf 'Antigravity CLI 1.4.7\r\n actual@example.com\r\n(Google AI Pro)\r\n'
        IFS= read -r unused
        """#.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let fixture = IsolatedProviderConsent("gemini")
        defer { fixture.close() }
        let signer = GeminiLogin()
        defer { signer.stop() }
        let callback = try #require(URL(string: "https://antigravity.google/oauth-callback"))
        #expect(!signer.receiveCode("4/fixture_Code-12345", from: callback))
        try signer.start(binary: binary.path, profile: root.appendingPathComponent("profile"),
                         base: ["HOME": home.path, "PATH": "/usr/bin:/bin"], switching: false, signingIn: true,
                         permit: try #require(fixture.consent.permit("gemini")))
        let deadline = Date().addingTimeInterval(8)
        while signer.authorizationURL == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        #expect(!signer.receiveCode("4/fixture_Code-12345", from: try #require(URL(string: "https://evil.test/oauth-callback"))))
        #expect(!signer.receiveCode("4/fixture_Code-12345\n/logout", from: callback))
        var sent = false
        while !sent, Date() < deadline {
            sent = signer.receiveCode("4/fixture_Code-12345", from: callback)
            if !sent { try await Task.sleep(for: .milliseconds(25)) }
        }
        #expect(sent)
        #expect(!signer.receiveCode("4/fixture_Code-12345", from: callback))
        while signer.identity == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        #expect(signer.identity?.email == "actual@example.com")
        signer.stop()
        #expect(!signer.receiveCode("4/fixture_Code-12345", from: callback))
    }

    @Test func accountPickerUsesTheSettingsRouteEvenWithNoSetupFlow() {
        let choices = GeminiChoices()
        #expect(!choices.inSettings(.models))
        choices.showing = true
        #expect(choices.inSettings(.models))
        #expect(choices.inSettings(.agents))
        #expect(choices.inSettings(.ai))
        #expect(!choices.inSettings(.mail))
        #expect(!choices.inSettings(.general))
        choices.showing = false
        #expect(!choices.inSettings(.models))
    }

}
