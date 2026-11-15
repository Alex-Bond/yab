import Foundation
import Testing
import WebKit
@testable import Fast

/// The adapters' readers held to the managers' documented JSON, and
/// Bitwarden's whole path (status, unlock, list, secret, save) run against a
/// stand-in `bw` that checks how Yab hands it secrets.
@Suite(.serialized)
struct ManagerVaultTests {
    typealias V = ManagerVault

    @Test func everyListedManagerHasAnAdapter() {
        for id in [PasswordManagers.bitwarden, PasswordManagers.onePassword, PasswordManagers.protonPass,
                   PasswordManagers.dashlane, PasswordManagers.lastPass, PasswordManagers.nordPass,
                   PasswordManagers.apple, V.keeper, V.enpass] {
            #expect(V.adapter(id) != nil, "no adapter for \(id)")
        }
        #expect(V.adapter(PasswordManagers.onePasswordBeta)?.provider == PasswordManagers.onePassword)
        #expect(V.adapter(PasswordManagers.nordPass)?.depth == .hybrid)
        // Apple Passwords uses the native helper; authorization is checked separately.
        #expect(V.adapter(PasswordManagers.apple)?.depth == .vault)
        // Read by Yab only through the tools checked against stand-ins.
        for id in [PasswordManagers.protonPass, PasswordManagers.dashlane, PasswordManagers.lastPass, V.keeper] {
            #expect(V.adapter(id)?.depth == .extensionOnly, "\(id) is read by Yab")
        }
    }

    @Test func sitesMatchByRegistrableDomain() {
        #expect(V.matches(["https://accounts.google.com/signin"], host: "mail.google.com"))
        #expect(V.matches(["github.com"], host: "github.com"))
        #expect(!V.matches(["https://a.github.io"], host: "b.github.io"))
        #expect(!V.matches(["https://evil-github.com"], host: "github.com"))
        #expect(!V.matches([], host: "github.com"))
    }

    /// Register 2492: only a real answer is kept for a site's 30 seconds.
    /// A failed tool is no answer, a change of state since drops it, and so
    /// does a manager connected or let go meanwhile.
    @MainActor
    @Test func onlyRealAnswersAreKept() {
        let bw = PasswordManagers.bitwarden, op = PasswordManagers.onePassword
        let at = Date(timeIntervalSince1970: 1000)
        #expect(!ManagerVaults.answered(.failed("bw didn't answer")))
        for state: V.State in [.open, .locked, .signedOut, .noTool, .needsApproval] { #expect(ManagerVaults.answered(state)) }
        // Every manager answered, a moment ago, nothing changed since: kept.
        #expect(ManagerVaults.stillTrue(true, at: at, states: [bw: .open], readable: [bw], now: at + 5, seen: [bw: .open]))
        // A list that timed out or failed is not.
        #expect(!ManagerVaults.stillTrue(false, at: at, states: [bw: .open], readable: [bw], now: at + 5, seen: [bw: .open]))
        // Nor anything older than 30 seconds.
        #expect(!ManagerVaults.stillTrue(true, at: at, states: [bw: .open], readable: [bw], now: at + 31, seen: [bw: .open]))
        // Locked when read, open now (unlocked, paired): read again.
        #expect(!ManagerVaults.stillTrue(true, at: at, states: [bw: .locked], readable: [bw], now: at + 5, seen: [bw: .open]))
        // Another manager connected since, or one let go: read again.
        #expect(!ManagerVaults.stillTrue(true, at: at, states: [bw: .open], readable: [bw, op], now: at + 5, seen: [bw: .open]))
        #expect(!ManagerVaults.stillTrue(true, at: at, states: [bw: .open, op: .open], readable: [bw], now: at + 5, seen: [bw: .open]))
    }

    @Test func secretsNeverPrint() {
        let secret = V.Secret(user: "me", password: "hunter2")
        #expect(!"\(secret)".contains("hunter2"))
        #expect(!String(reflecting: secret).contains("hunter2"))
    }

    @Test func bitwardenListDropsPasswords() throws {
        let json = """
        [{"id":"a1","type":1,"name":"GitHub","login":{"username":"me@x.com","password":"p","uris":[{"uri":"https://github.com"}]}},
         {"id":"n1","type":2,"name":"Note"}]
        """
        let logins = BitwardenCLI.logins(Data(json.utf8), host: "github.com")
        #expect(logins == [V.Login(provider: PasswordManagers.bitwarden, item: "a1", title: "GitHub", user: "me@x.com",
                                   urls: ["https://github.com"])])
        #expect(BitwardenCLI.state("locked") == .locked)
        #expect(BitwardenCLI.state("unauthenticated") == .signedOut)
    }

    @Test func onePasswordFiltersBySiteAndReadsPurposes() {
        let list = """
        [{"id":"x","title":"GitHub","additional_information":"me","urls":[{"href":"https://github.com/login","primary":true}]},
         {"id":"y","title":"Other","urls":[{"href":"https://example.com"}]}]
        """
        #expect(OnePasswordCLI.logins(Data(list.utf8), host: "github.com").map(\.item) == ["x"])
        let item = """
        {"id":"x","fields":[{"id":"username","purpose":"USERNAME","value":"me"},{"id":"password","purpose":"PASSWORD","value":"pw"}]}
        """
        let secret = OnePasswordCLI.secret(Data(item.utf8))
        #expect(secret?.user == "me" && secret?.password == "pw")
    }

    // MARK: the list's rules, state by state (the picked design "A")

    private func login(_ user: String, _ provider: String) -> V.Login {
        V.Login(provider: provider, item: user, title: user, user: user, urls: ["https://github.com"])
    }
    private func yab(_ user: String) -> Login {
        Login(host: "github.com", user: user, password: "p", used: Date(), clear: false)
    }
    private typealias R = SuggestRows
    private let bw = PasswordManagers.bitwarden, nord = PasswordManagers.nordPass, op = PasswordManagers.onePassword

    @Test func manySourcesGroupedAndSaidOnce() {
        let rows = R.build(.init(yab: [yab("ann.lee@hey.com")], managers: [
            .init(provider: bw, logins: [login("ann.lee@hey.com", bw)]),
            .init(provider: nord, logins: [login("ann@work.co", nord), login("annlee-bot", nord)]),
            .init(provider: op, logins: [login("ops@acme.dev", op)]),
        ], host: "github.com"))
        #expect(rows.map(\.title) == ["ann.lee@hey.com", "ann@work.co", "annlee-bot", "ops@acme.dev"])
        #expect(rows[0].detail == "Saved in Yab and Bitwarden")
        #expect(rows[1].detail == "Saved in NordPass" && rows[1].badge == nord)
        #expect(rows.map(\.group) == [0, 2, 2, 3])
    }

    @Test func oneLoginIsOneQuickRow() {
        let rows = R.build(.init(yabOn: true, managers: [.init(provider: bw, logins: [login("ann.lee@hey.com", bw)])], host: "github.com"))
        #expect(rows.count == 1 && rows[0].quick && rows[0].detail == "Saved in Bitwarden · github.com")
    }

    @Test func nothingSaysWhereItLooked() {
        let rows = R.build(.init(managers: [.init(provider: nord, logins: []), .init(provider: bw)], host: "linear.app"))
        #expect(rows.map(\.title) == ["No logins for this site", "Open NordPass"])
        #expect(rows[0].detail == "Looked in Yab, NordPass and Bitwarden" && !rows[0].pickable)
        // No manager connected and nothing kept: no list at all, as before.
        #expect(R.build(.init(host: "linear.app")).isEmpty)
    }

    @Test func anEmailBoxWithNoLoginOffersYourAddressesAlone() {
        let mails = ["sam@42nd.dev", "samcloud@mail.example"]
        let rows = R.build(.init(managers: [.init(provider: PasswordManagers.apple, logins: [])], host: "notes.example", emails: mails))
        #expect(rows.map(\.title) == mails)
        #expect(rows.allSatisfy { if case .email = $0.kind { $0.detail.isEmpty && $0.pickable } else { false } })
        // Typing narrows them; the one left is ↩.
        let typed = R.build(.init(host: "notes.example", emails: mails, typed: "samc"))
        #expect(typed.map(\.title) == ["samcloud@mail.example"] && typed[0].quick)
        // A login for the site wins: no address rows beside it.
        let login = R.build(.init(yab: [yab("ann.lee@hey.com")], host: "github.com", emails: mails))
        #expect(!login.contains { if case .email = $0.kind { true } else { false } })
        // Never in a password box.
        #expect(R.build(.init(host: "notes.example", secret: true, emails: mails)).isEmpty)
    }

    @Test func yourAddressesRankMailThenLoginsThenForms() {
        let list = ManagerLists.ranked(mail: ["Sam@42nd.dev"], logins: ["a@x.io": 2, "b@y.io": 5, "sam@42nd.dev": 9, "bot": 3],
                                       forms: ["c@z.io", ""])
        #expect(list == ["sam@42nd.dev", "b@y.io", "a@x.io", "c@z.io"])
        #expect(!ManagerLists.isEmail("sam-bot") && ManagerLists.isEmail("a@b.co"))
    }

    @Test func lockedShowsASpinnerRowAndTheRestStillPick() {
        let rows = R.build(.init(yab: [yab("ann.lee@hey.com")], managers: [.init(provider: bw, unlocking: true)], host: "github.com"))
        #expect(rows.map(\.title) == ["ann.lee@hey.com", "Unlocking Bitwarden…"])
        #expect(rows[0].pickable && !rows[1].pickable)
    }

    @Test func passwordStepOffersTheChosenAccountOnly() {
        let rows = R.build(.init(yab: [yab("ann.work@gmail.com")], managers: [.init(provider: PasswordManagers.protonPass,
            logins: [login("ann.lee@gmail.com", PasswordManagers.protonPass)])], host: "google.com", secret: true, named: "ann.lee@gmail.com"))
        #expect(rows.count == 1 && rows[0].title == "Password for ann.lee@gmail.com" && rows[0].quick)
    }

    @Test func newPasswordBoxOffersAStrongOne() {
        let made = R.strongPassword()
        #expect(made.count == 19 && made.split(separator: "-").count == 4)
        let rows = R.build(.init(managers: [.init(provider: bw)], host: "github.com", secret: true, fresh: true, generated: made, saver: bw))
        // One row: the manager's extension offers to keep it, Yab doesn't.
        #expect(rows.map(\.title) == ["Use Strong Password"])
        #expect(rows[0].shown == made && rows[0].quick && rows[0].detail == " · Bitwarden offers to save it")
        let alone = R.build(.init(host: "github.com", secret: true, fresh: true, generated: made))
        #expect(alone.first?.detail == " · saved in Yab passwords")
    }

    @Test func aManagersOwnMenuIsReadIntoRows() {
        let entries = [ManagerMenus.Entry(provider: nord, title: "ann@work.co", detail: "Work"),
                       ManagerMenus.Entry(provider: nord, title: "annlee-bot", detail: "")]
        let rows = R.build(.init(yab: [yab("ann.lee@hey.com")], managers: [.init(provider: nord, entries: entries, hybrid: true)], host: "github.com"))
        #expect(rows.map(\.title) == ["ann.lee@hey.com", "ann@work.co", "annlee-bot"])
        #expect(rows[1].badge == nord && rows[1].detail == "Saved in NordPass")
        // Its only entry: one quick row, as a login of Yab's would be.
        let one = R.build(.init(yabOn: false, managers: [.init(provider: nord, entries: [entries[0]], hybrid: true)], host: "github.com"))
        #expect(one.count == 1 && one[0].quick && one[0].detail == "Saved in NordPass · github.com")
    }

    @Test func aLockedMenuSaysSoUntilUnlocked() {
        let rows = R.build(.init(yabOn: false, managers: [.init(provider: nord, locked: true, hybrid: true)], host: "github.com"))
        #expect(rows.map(\.title) == ["NordPass is locked"])
        #expect(rows[0].pickable)
    }

    @Test func hybridManagerFillsByItself() {
        let rows = R.build(.init(yabOn: false, managers: [.init(provider: nord, hybrid: true)], host: "github.com"))
        #expect(rows.map(\.title) == ["Fill with NordPass", "Open NordPass"])
        #expect(rows[0].quick)
        let busy = R.build(.init(yabOn: false, managers: [.init(provider: nord, hybrid: true, busy: true)], host: "github.com"))
        #expect(!busy[0].pickable && busy[0].detail == "NordPass is filling…")
    }

    @Test func managerWithNothingHereHasNoRow() {
        // NordPass's own menu showed no login for the site: no "Fill with".
        let rows = R.build(.init(yabOn: true, managers: [.init(provider: nord, hybrid: true, none: true)], host: "x.com"))
        #expect(rows.first?.detail == "Looked in Yab and NordPass" && !rows.contains { if case .hybrid = $0.kind { return true }; return false })
        let mixed = R.build(.init(yab: [yab("samrivera")], managers: [.init(provider: nord, hybrid: true, none: true)], host: "x.com"))
        #expect(mixed.map(\.title) == ["samrivera"] && mixed[0].detail == "Saved in Yab")
    }

    /// 1Password's banner over the page is a frame of the same extension as
    /// its menu: never read as logins, never pressed in (Slumdog8's gif,
    /// 2026-10-19: rows "Other logins", "Dismiss banner").
    @MainActor
    @Test func aManagersBannerIsNoMenu() async throws {
        func read(_ html: String, width: CGFloat, height: CGFloat, _ script: String = ManagerMenus.readScript,
                  _ arguments: [String: Any] = [:]) async throws -> Any? {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let web = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: height), configuration: configuration)
            web.loadHTMLString(html, baseURL: URL(string: "https://example.test/"))
            // Its own document, not the blank one before it, which is
            // "complete" at once.
            for _ in 0..<200 {
                if (try? await web.evaluateJavaScript("document.readyState === 'complete' && !!document.querySelector('button')")) as? Bool == true { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            return try await web.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .page)
        }
        let banner = "<body style=margin:0><button>HC<br>GameTime</button><button>Sign in</button>"
            + "<button>Other logins</button><button aria-label=\"Dismiss banner\">×</button></body>"
        let said = try await read(banner, width: 900, height: 56) as? [String: Any]
        #expect(said?["banner"] as? Bool == true, "\(String(describing: said))")
        // A low strip saying Other logins is a banner even without its x.
        let strip = "<body style=margin:0><button>HC</button><button>Other logins</button></body>"
        #expect((try await read(strip, width: 900, height: 56) as? [String: Any])?["banner"] as? Bool == true)
        let picked = try await read(banner, width: 900, height: 56, ManagerMenus.pickScript, ["title": "HC", "detail": "GameTime"])
        #expect(picked as? Bool == false)
        let menu = "<body style=margin:0><div role=listbox><div role=option>ann@hey.com<br><small>GitHub</small></div>"
            + "<div role=option>Other logins</div></div><button>Add login</button></body>"
        let rows = try await read(menu, width: 300, height: 140) as? [String: Any]
        #expect(rows?["banner"] == nil)
        let entries = rows?["entries"] as? [[String]] ?? []
        #expect(entries.map { $0.first ?? "" } == ["ann@hey.com"], "\(entries)")
    }

    /// The stand-in only answers a session it handed out, only unlocks with
    /// the right password from its environment, and keeps what `create`
    /// got on stdin, to be read back here.
    private func standIn() throws -> (path: String, created: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-bw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let created = folder.appendingPathComponent("created.json")
        let script = """
        #!/bin/sh
        ok() { [ "$BW_SESSION" = "s3ss10n" ]; }
        for a in "$@"; do case "$a" in *right*) echo "secret in argv" >&2; exit 9;; esac; done
        case "$1" in
          status) if ok; then echo '{"status":"unlocked"}'; else echo '{"status":"locked"}'; fi ;;
          unlock) [ "$YAB_BW_UNLOCK" = "right" ] && printf 's3ss10n' || { echo "Invalid master password." >&2; exit 1; } ;;
          sync) ok && echo "Syncing complete." ;;
          list) ok || { echo "Vault is locked." >&2; exit 1; }
                echo '[{"id":"a1","type":1,"name":"Fixture","login":{"username":"fixture-user","password":"fixture-password","uris":[{"uri":"http://127.0.0.1/login"}]}}]' ;;
          get) ok || exit 1; echo '{"id":"a1","type":1,"login":{"username":"fixture-user","password":"fixture-password"}}' ;;
          create) ok || exit 1; base64 -D > "\(created.path)"; echo '{"id":"new"}' ;;
          *) exit 2 ;;
        esac
        """
        let path = folder.appendingPathComponent("bw").path
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        return (path, created)
    }

    /// 1Password's app asks the person when Yab isn't allowed yet (whoami
    /// fails until then): that get is proven, and Yab doesn't ask again.
    /// Allowed already, within its 10 minutes, nobody was asked: not proven.
    @Test func onePasswordIsProvenOnlyWhenItsAppAsked() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-op-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let allowed = folder.appendingPathComponent("allowed").path
        let asked = folder.appendingPathComponent("asked.log").path
        let script = """
        #!/bin/sh
        case "$1 $2" in
          "whoami "*) [ -e "\(allowed)" ] && echo '{"user_uuid":"u"}' || { echo "not signed in" >&2; exit 1; } ;;
          "item get") [ -e "\(allowed)" ] || { echo asked >> "\(asked)"; touch "\(allowed)"; }
                      echo '{"id":"o1","fields":[{"id":"username","purpose":"USERNAME","value":"op-user"},{"id":"password","purpose":"PASSWORD","value":"op-secret"}]}' ;;
          *) exit 2 ;;
        esac
        """
        let path = folder.appendingPathComponent("op").path
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        let op = OnePasswordCLI(tool: ManagerTool(names: ["op"], key: "OP", at: path))
        let login = V.Login(provider: PasswordManagers.onePassword, item: "o1", title: "Fixture", user: "op-user", urls: ["https://site.test"])
        let first = try await op.secret(login)
        #expect(first.password == "op-secret" && first.proven)
        let second = try await op.secret(login)
        #expect(second.password == "op-secret" && !second.proven)
        #expect(try String(contentsOfFile: asked, encoding: .utf8).split(separator: "\n").count == 1)
    }

    @Test func bitwardenEndToEndAgainstAStandIn() async throws {
        let stand = try standIn()
        let bw = BitwardenCLI(tool: ManagerTool(names: ["bw"], key: "BW", at: stand.path))
        #expect(await bw.state() == .locked)
        await #expect(throws: V.Failure.locked) { try await bw.logins(for: "127.0.0.1") }
        #expect(await bw.unlock("wrong") == false)
        #expect(await bw.unlock("right"))
        #expect(await bw.state() == .open)
        let logins = try await bw.logins(for: "127.0.0.1")
        #expect(logins.map(\.user) == ["fixture-user"])
        let secret = try await bw.secret(logins[0])
        #expect(secret.password == "fixture-password")
        // Opened with the saved unlock password: nobody was asked for it,
        // so Yab's own Touch ID still stands before it fills.
        #expect(!secret.proven)
        try await bw.save(host: "example.com", user: "new-user", password: "right-new")
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: stand.created)) as? [String: Any]
        let login = saved?["login"] as? [String: Any]
        #expect(login?["username"] as? String == "new-user" && login?["password"] as? String == "right-new")
        await bw.lock()
        #expect(await bw.state() == .locked)
    }
}
