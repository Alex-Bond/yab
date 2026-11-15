import AppKit

/// The official CLI's own interactive sign-in, without a Terminal window.
/// The CLI owns tokens. Yab relays its hosted callback code from its own tab.
@MainActor
final class GeminiLogin {
    private var process = Process()
    private var input = Pipe()
    private var output = Pipe()
    private var errors = Pipe()
    private var text = ""
    private var ended = false
    private var tab: Tab?
    private weak var browser: Browser?
    private var folder: URL?
    private var page: URL?
    private var trusted = false
    private var choseGoogle = false
    private var signingIn = false
    private(set) var identity: GeminiIdentity?
    private(set) var opened = false
    private(set) var loggedOut = false
    private var switching = false
    private var quitting: NSObjectProtocol?
    private var codeSent = false
    private var readingCode = false
    var changed: (() -> Void)?
    private(set) var codeError: String?
    var submittedCode: Bool { codeSent }

    nonisolated static let browserScript = """
    #!/bin/sh
    for url in "$@"; do
      case "$url" in
        https://*) printf '%s\\n' "$url" > "$YAB_GEMINI_PAGE"; exit 0 ;;
      esac
    done
    exit 1

    """

    nonisolated static func hinted(_ url: URL, email: String?) -> URL {
        guard let email, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        // Keep the CLI's encoded state, scope and redirect_uri intact.
        // Rebuilding queryItems loses the distinction between %2B and +.
        var query = (parts.percentEncodedQuery ?? "").split(separator: "&").map(String.init)
        query.removeAll { item in
            let name = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            return name.removingPercentEncoding == "login_hint"
        }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+%?#")
        guard let hinted = email.addingPercentEncoding(withAllowedCharacters: allowed) else { return url }
        query.append("login_hint=" + hinted)
        parts.percentEncodedQuery = query.joined(separator: "&")
        return parts.url ?? url
    }

    func start(binary: String, profile: URL, base: [String: String], switching: Bool, signingIn: Bool = false,
               permit: ProviderLaunchPermit) throws {
        process = Process()
        input = Pipe(); output = Pipe(); errors = Pipe()
        text = ""; ended = false; trusted = false; choseGoogle = false; opened = false
        identity = nil; loggedOut = false; codeSent = false; readingCode = false; codeError = nil
        self.switching = switching
        self.signingIn = signingIn
        let config = GeminiRunner.Configuration(binary: binary, profile: profile,
            workspace: profile.appendingPathComponent("sign-in"), model: nil, conversation: nil,
            command: "", mcpArgs: nil, brief: Agents.instructions(textOnly: true, full: false, remembering: false), environment: base)
        let prepared = try config.prepare()
        let folder = profile.appendingPathComponent("sign-in-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.folder = folder
        page = folder.appendingPathComponent("page")
        for name in ["open", "browser"] {
            let file = folder.appendingPathComponent(name)
            try Self.browserScript.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        var env = prepared.env
        env["PATH"] = folder.path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        env["BROWSER"] = folder.appendingPathComponent("browser").path
        env["YAB_GEMINI_PAGE"] = page?.path
        env["TERM"] = "xterm-256color"
        env["COLUMNS"] = "160"
        env["LINES"] = "50"
        // script supplies the TTY Google's interactive sign-in requires.
        // Its stdin stays open. Never send a model prompt.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", binary, "--agent", GeminiSupport.agentName]
        process.environment = env
        process.currentDirectoryURL = prepared.cwd
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let current = process
        for pipe in [output, errors] {
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { handle.readabilityHandler = nil; return }
                let chunk = String(decoding: data, as: UTF8.self)
                Task { @MainActor [weak self] in
                    guard let self, self.process === current else { return }
                    self.heard(chunk)
                }
            }
        }
        process.terminationHandler = { [weak self] _ in Task { @MainActor in
            guard let self, self.process === current else { return }
            self.ended = true
            if self.codeSent, self.identity == nil { self.codeError = Self.rejectedCode }
            self.changed?()
        } }
        guard try permit.start(process) else { stop(); throw GeminiStream.Failure("Gemini sign-in was canceled.") }
        quitting = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop(immediately: true) }
        }
    }

    private func heard(_ chunk: String) {
        guard !ended else { return }
        if chunk.contains("\u{1b}[6n") { send("\u{1b}[1;1R") }
        text = String((text + chunk).suffix(128_000))
        let plain = GeminiIdentity.plain(text)
        // The text was emptied when the code went in: what follows is the CLI's answer.
        if codeSent, codeError == nil, Self.rejectsCode(plain) { codeError = Self.rejectedCode }
        defer { changed?() }
        // This is Yab's generated no-tools workspace, prepared above. Never
        // accept trust for a user's project or a directory printed by a page.
        if !trusted, plain.contains("Do you trust the contents of this project?") {
            trusted = true
            send("\r")
        }
        // Connect already chose Google. The CLI still asks for its login
        // method before it invokes the browser, even in an empty profile.
        if signingIn, !choseGoogle, Self.googleSelected(plain) {
            choseGoogle = true
            send("\r")
        }
        if let who = GeminiIdentity.read(text) {
            identity = who
            if switching, !loggedOut, plain.contains("? for shortcuts") {
                loggedOut = true
                identity = nil
                text = ""
                // The person's Switch Account press authorizes replacing
                // the shared Antigravity login. /logout is a TUI command,
                // unsupported by the headless CLI. Never run it with -p.
                send("/logout\r")
            }
        }
    }

    private func send(_ words: String) { try? input.fileHandleForWriting.write(contentsOf: Data(words.utf8)) }

    nonisolated static func googleSelected(_ text: String) -> Bool {
        text.contains("Select login method:")
            && text.range(of: #"(?m)^\s*>\s*1\.\s+Google OAuth\s*$"#, options: .regularExpression) != nil
    }

    /// Only a URL captured from the CLI's browser launcher opens a tab.
    /// Looking at a signed-in header never launches a browser.
    func openPage(in browser: Browser, choice: GeminiChoice) {
        guard !opened, let url = authorizationURL else { return }
        opened = true
        self.browser = browser
        if case .space(let id) = choice.source { browser.switchSpace(to: id) }
        tab = browser.open(Self.hinted(url, email: choice.email), foreground: true, shy: choice.source == .another)
        show()
    }

    var authorizationURL: URL? {
        guard let page, let data = try? Data(contentsOf: page),
              let text = String(data: data, encoding: .utf8), text.hasSuffix("\n"),
              let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", let host = url.host?.lowercased(),
              host == "accounts.google.com" || host == "antigravity.google" || host.hasSuffix(".antigravity.google") else { return nil }
        return url
    }

    /// Antigravity can use a hosted callback and ask its TUI for the code,
    /// rather than listen on loopback. Keep that redirect exactly as issued.
    /// Read only the active login's own tab, on the CLI's exact HTTPS callback.
    func completeCodePage() {
        guard !ended, !codeSent, !readingCode, awaitingCode,
              let tab, let page = tab.builtPage, let url = page.url,
              Self.isCodePage(url, authorization: authorizationURL) else { return }
        readingCode = true
        let current = process
        page.run(Self.codePageScript, in: .yab, gesture: false) { [weak self, weak tab] result in
            guard let self, self.process === current, !self.ended else { return }
            self.readingCode = false
            guard let tab, self.tab === tab, tab.builtPage === page, page.url == url,
                  let value = try? result.get() as? [String: String],
                  value["href"] == url.absoluteString, let code = value["code"] else { return }
            self.receiveCode(code, from: url)
        }
    }

    var awaitingCode: Bool {
        signingIn && !ended && !codeSent && Self.requestsCode(text)
    }

    nonisolated static func requestsCode(_ text: String) -> Bool {
        let plain = GeminiIdentity.plain(text).lowercased()
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return plain.contains("paste the authorization code below:")
            || plain.contains("enter the authorization code:")
    }

    nonisolated static let rejectedCode = "Google's codes last a few minutes. Show Sign-In for a new one and paste it again."

    /// agy 1.4.4 answers a bad or old code with
    /// `Got an error: token exchange failed: oauth2: "invalid_grant" "Bad Request"`
    /// and waits on "Press any key to go back." without exiting.
    nonisolated static func rejectsCode(_ text: String) -> Bool {
        let plain = GeminiIdentity.plain(text).lowercased()
        return ["invalid_grant", "token exchange failed", "got an error:", "invalid authorization code",
                "failed to exchange", "authentication failed", "failed to authenticate",
                "sign-in link is no longer valid"].contains(where: plain.contains)
    }

    /// Manual entry works independently of the browser callback or its page.
    @discardableResult
    func submitCode(_ text: String) -> Bool {
        guard awaitingCode, process.isRunning else { return false }
        let code = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.range(of: #"\A4/[A-Za-z0-9_-]{10,2048}\z"#, options: .regularExpression) != nil else { return false }
        do { try input.fileHandleForWriting.write(contentsOf: Data((code + "\r").utf8)) }
        catch { codeError = Self.rejectedCode; changed?(); return false }
        codeSent = true
        codeError = nil
        // Do not mistake the old prompt (or the PTY's echo) for another request.
        textAfterSubmission()
        changed?()
        return true
    }

    private func textAfterSubmission() { text = "" }

    /// No URLs, extra lines or terminal control characters reach the TUI.
    @discardableResult
    func receiveCode(_ code: String, from url: URL) -> Bool {
        guard Self.isCodePage(url, authorization: authorizationURL) else { return false }
        return submitCode(code)
    }

    nonisolated static func isCodePage(_ url: URL, authorization: URL?) -> Bool {
        guard let authorization,
              let items = URLComponents(url: authorization, resolvingAgainstBaseURL: false)?.queryItems,
              let redirect = items.first(where: { $0.name == "redirect_uri" })?.value.flatMap(URL.init(string:)),
              redirect.scheme == "https", redirect.host?.lowercased() == "antigravity.google",
              redirect.path == "/oauth-callback", redirect.user == nil, redirect.password == nil,
              redirect.port == nil || redirect.port == 443,
              url.scheme == redirect.scheme, url.host?.lowercased() == redirect.host?.lowercased(),
              url.path == redirect.path, url.port == redirect.port, url.user == nil, url.password == nil else { return false }
        return !(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).contains { $0.name == "error" }
    }

    nonisolated static let codePageScript = """
    (() => {
      const body = document.body;
      if (!body) return null;
      // Antigravity's callback writes the code into [data-code-box], in
      // any language. Older or other pages: the English sentence first.
      const box = document.querySelector('[data-code-box]');
      const candidates = box ? [box.textContent || ''] : [];
      if (!box) {
        if (!body.innerText.includes('Paste this code into your application to complete authentication')) return null;
        candidates.push(...[...document.querySelectorAll('input, textarea, pre, code')]
          .map(node => node.value || node.textContent || ''));
        candidates.push(body.innerText);
      }
      for (const text of candidates) {
        const code = text.match(/(?:^|\\s)(4\\/[A-Za-z0-9_-]{10,2048})(?=$|\\s)/);
        if (code) return {href: location.href, code: code[1]};
      }
      return null;
    })()
    """

    private var holder: Browser? {
        guard let tab else { return nil }
        var browsers = BrowserWindows.shared.browsers
        if let browser, !browsers.contains(where: { $0 === browser }) { browsers.append(browser) }
        return browsers.first { $0.everyTab.contains { $0.id == tab.id } }
    }

    var closed: Bool { tab != nil && holder == nil }
    var finished: Bool { ended }

    func show() {
        guard let tab, let browser = holder else { return }
        if !browser.tabs.contains(where: { $0.id == tab.id }), let space = browser.spaceHolding(tab.id) {
            browser.switchSpace(to: space)
        }
        browser.select(tab)
        (BrowserWindows.shared.window(for: browser) ?? Links.window)?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func stop(immediately: Bool = false) {
        ended = true
        if let quitting { NotificationCenter.default.removeObserver(quitting); self.quitting = nil }
        process.terminationHandler = nil
        for pipe in [output, errors] { pipe.fileHandleForReading.readabilityHandler = nil }
        if process.isRunning {
            if immediately {
                for member in Shell.descendants(of: process.processIdentifier).reversed() where member.alive { kill(member.pid, SIGKILL) }
            } else { Shell.end(process, grace: 1) }
        }
        if let tab, let browser = holder { browser.close(tab) }
        tab = nil
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
    }
}
