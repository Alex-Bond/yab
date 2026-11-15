import CryptoKit
import Network
import WebKit

// A website can't reach this Mac's own servers or the devices on its
// network: not from its scripts, its pictures, its frames or its sockets.
// Chrome's Local Network Access (142 on), as near as WebKit allows, and
// never stricter:
//
// - Only a public page is held back. A page from this Mac or the network
//   (localhost:3000, a router at 192.168.1.1, a file) reaches anything, the
//   API on another port included, and so does every frame under it.
// - A tab going somewhere is never stopped: a link to localhost, a sign-in
//   sending you back to a command line's 127.0.0.1 listener, a server's own
//   redirect. Chrome doesn't stop them either.
// - An https page that tries is asked about, once: "wants to connect to
//   apps on this Mac" or "to devices on your network", Chrome's two
//   questions. The answer is kept for the site, and Site Controls shows it.
//   A plain http page, or a letter in Mail, is never asked about. Nor is an
//   https page's plain http request: WebKit refuses that as mixed content
//   before and after, where Chrome lets local addresses through.
// - Extensions' own pages carry none of this.
//
// What Chrome reads off the connection, the address a name resolved to,
// WebKit doesn't show. A request's address is read as written: a name that
// resolves to a local address, and DNS rebinding, go through. The page's
// own address is looked up before it loads (`look`): app.lvh.me,
// 127.0.0.1.nip.io or a .test name pointing here is this Mac's page, as in
// Chrome, and reaches its frames and API on localhost (feedback #884). A
// local page has no ad blocker either (Shield.fit).
//
// One list for every page, compiled once and looked up after that in a
// millisecond. It is the same list on every page because WebKit gives a
// site's service worker the controller of whichever view was made last.

@MainActor
enum LocalNetwork {
    enum Space: Equatable { case `public`, local, loopback }

    /// Chrome's two permissions.
    enum Kind: String, CaseIterable { case local, loopback }

    static let prefix = "local-network-"

    // MARK: - addresses

    /// Where an address as written points. Chrome's ranges
    /// (services/network/public/cpp/ip_address_space_util.cc); names
    /// are read the way they nearly always resolve.
    nonisolated static func space(of rawHost: String) -> Space {
        var host = rawHost.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        if host == "localhost" || host.hasSuffix(".localhost") { return .loopback }
        if let bytes = ipv4(host) { return space(v4: bytes) }
        var six = in6_addr()
        if host.contains(":"), host.split(separator: "%").first.map({ String($0).withCString { inet_pton(AF_INET6, $0, &six) } }) == 1 {
            let b = withUnsafeBytes(of: &six) { Array($0) }
            if b.prefix(10).allSatisfy({ $0 == 0 }), b[10] == 255, b[11] == 255 { return space(v4: Array(b.suffix(4))) }
            if b.dropLast().allSatisfy({ $0 == 0 }), b[15] <= 1 { return .loopback }
            if b[0] & 0xfe == 0xfc || (b[0] == 0xfe && b[1] & 0x80 == 0x80)
                || b.prefix(4) == [0x20, 0x01, 0x0d, 0xb8] || (b[0] == 0x3f && b[1] == 0xff && b[2] & 0xf0 == 0) { return .local }
            return .public
        }
        if host.hasSuffix(".local") { return .local }
        // One word, no dots: "router", "nas". Chrome would ask where it
        // resolved; on a Mac it is a device on the network.
        if !host.isEmpty, host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) { return .local }
        return .public
    }

    nonisolated private static func ipv4(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let bytes = parts.compactMap { UInt8($0) }
        return bytes.count == 4 ? bytes : nil
    }

    nonisolated private static func space(v4 b: [UInt8]) -> Space {
        if b[0] == 127 || b == [0, 0, 0, 0] { return .loopback }
        if b[0] == 10 || b[0] == 0 || (b[0] == 172 && b[1] & 0xf0 == 16) || (b[0] == 192 && b[1] == 168)
            || (b[0] == 169 && b[1] == 254) || (b[0] == 100 && b[1] & 0xc0 == 64) { return .local }
        return .public
    }

    // MARK: - the rules

    /// The same ranges as hosts in WebKit's URL regex, which has no
    /// alternation, no counts and no \d: one rule each. WebKit matches the
    /// URL as it normalized it, so 0x7f.1 is already 127.0.0.1 here.
    nonisolated static let hosts: [Kind: [String]] = [
        .loopback: [
            #"localhost\.?"#, #"[^/:]*\.localhost\.?"#,
            #"127\.[0-9]+\.[0-9]+\.[0-9]+\.?"#, #"0\.0\.0\.0\.?"#,
            #"\[::1?\]"#, #"\[::ffff:7f[0-9a-f][0-9a-f]:[^/]+\]"#,
            #"\[::ffff:127\.[0-9]+\.[0-9]+\.[0-9]+\]"#,
            #"\[::ffff:0\.0\.0\.0\]"#,
            #"\[::ffff:0:0\]"#,
        ],
        .local: [
            #"[^/:]*\.local\.?"#, #"[a-z0-9-]+\.?"#,
            #"10\.[0-9]+\.[0-9]+\.[0-9]+\.?"#, #"0\.[0-9]+\.[0-9]+\.[0-9]+\.?"#,
            #"172\.1[6-9]\.[0-9]+\.[0-9]+\.?"#, #"172\.2[0-9]\.[0-9]+\.[0-9]+\.?"#, #"172\.3[01]\.[0-9]+\.[0-9]+\.?"#,
            #"192\.168\.[0-9]+\.[0-9]+\.?"#, #"169\.254\.[0-9]+\.[0-9]+\.?"#,
            #"100\.6[4-9]\.[0-9]+\.[0-9]+\.?"#, #"100\.[7-9][0-9]\.[0-9]+\.[0-9]+\.?"#,
            #"100\.1[01][0-9]\.[0-9]+\.[0-9]+\.?"#, #"100\.12[0-7]\.[0-9]+\.[0-9]+\.?"#,
            #"\[f[cd][0-9a-f][0-9a-f]:[^/]+\]"#, #"\[fe[89a-f][0-9a-f]:[^/]+\]"#,
            #"\[2001:db8:[^/]+\]"#, #"\[3fff::[^/]*\]"#, #"\[3fff:[0-9a-f][0-9a-f]?[0-9a-f]?:[^/]+\]"#,
            // A mapped address is local only if its embedded IPv4 is.
            // A blanket ::ffff match also exempted public pages such as
            // http://[::ffff:808:808]/ from every local-network block.
            #"\[::ffff:[0-9a-f][0-9a-f]?:[0-9a-f]+\]"#,
            #"\[::ffff:a[0-9a-f][0-9a-f]:[0-9a-f]+\]"#,
            #"\[::ffff:ac1[0-9a-f]:[0-9a-f]+\]"#,
            #"\[::ffff:c0a8:[0-9a-f]+\]"#,
            #"\[::ffff:a9fe:[0-9a-f]+\]"#,
            #"\[::ffff:64[4-7][0-9a-f]:[0-9a-f]+\]"#,
            #"\[::ffff:0\.[0-9]+\.[0-9]+\.[0-9]+\]"#,
            #"\[::ffff:10\.[0-9]+\.[0-9]+\.[0-9]+\]"#,
            #"\[::ffff:172\.1[6-9]\.[0-9]+\.[0-9]+\]"#,
            #"\[::ffff:172\.2[0-9]\.[0-9]+\.[0-9]+\]"#,
            #"\[::ffff:172\.3[01]\.[0-9]+\.[0-9]+\]"#,
            #"\[::ffff:192\.168\.[0-9]+\.[0-9]+\]"#,
            #"\[::ffff:169\.254\.[0-9]+\.[0-9]+\]"#,
            #"\[::ffff:100\.6[4-9]\.[0-9]+\.[0-9]+\]"#,
            #"\[::ffff:100\.[7-9][0-9]\.[0-9]+\.[0-9]+\]"#,
            #"\[::ffff:100\.1[01][0-9]\.[0-9]+\.[0-9]+\]"#,
            #"\[::ffff:100\.12[0-7]\.[0-9]+\.[0-9]+\]"#,
        ],
    ]

    nonisolated private static let kinds: [String] = ["image", "style-sheet", "script", "font", "media", "svg-document", "ping", "fetch", "websocket", "other"]

    nonisolated private static func authority(_ host: String) -> String { "://([^/@]*@)?" + host + "(:[0-9]+)?/" }

    /// Pages that reach anything: this Mac's and the network's, files, and
    /// extensions' and Yab's own.
    nonisolated private static var home: [String] {
        Kind.allCases.flatMap { hosts[$0]! }.map { "^https?" + authority($0) }
            + ["^file:", "^webkit-extension:", "^safari-web-extension:", "^\(DiaryPage.scheme):"]
    }

    /// `granted`: the sites allowed each kind, as "https://host:443".
    /// `homes`: names whose pages resolved to this Mac or the network.
    nonisolated static func rules(granted: [Kind: [String]] = [:], homes: [String] = []) -> String {
        var rules: [[String: Any]] = []
        let all = Kind.allCases.flatMap { kind in hosts[kind]!.map { (kind, $0) } }
        for (_, host) in all {
            let target = "^[hw][ts]t?p?s?" + authority(host)
            // A frame's own requests, held back unless it is itself home.
            rules.append(["trigger": ["url-filter": target, "resource-type": kinds, "unless-frame-url": home],
                          "action": ["type": "block"]])
            // A frame's own document. WebKit reads the frame's old document
            // here, about:blank for a new one, hence the page's below too.
            rules.append(["trigger": ["url-filter": target, "resource-type": ["document"], "load-context": ["child-frame"], "unless-frame-url": home],
                          "action": ["type": "block"]])
        }
        // Everything under a page that is itself home, about:blank frames
        // and their documents included.
        rules.append(["trigger": ["url-filter": ".*", "resource-type": kinds + ["document"], "if-top-url": home],
                      "action": ["type": "ignore-previous-rules"]])
        // And under a page whose name resolved to one of those addresses.
        if !homes.isEmpty {
            rules.append(["trigger": ["url-filter": ".*", "resource-type": kinds + ["document"], "if-top-url": homes.sorted().map(homeFilter)],
                          "action": ["type": "ignore-previous-rules"]])
        }
        for kind in Kind.allCases {
            let sites = (granted[kind] ?? []).sorted()
            guard !sites.isEmpty else { continue }
            let tops = sites.map(originFilter)
            for host in hosts[kind]! {
                rules.append(["trigger": ["url-filter": "^[hw][ts]t?p?s?" + authority(host), "resource-type": kinds + ["document"], "if-top-url": tops],
                              "action": ["type": "ignore-previous-rules"]])
            }
        }
        let data = try! JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated private static func escaped(_ host: String) -> String {
        host.reduce(into: "") { out, c in
            if ".[]\\+*?()|^$".contains(c) { out.append("\\") }
            out.append(c)
        }
    }

    /// A page on this name, any port, http or https.
    nonisolated static func homeFilter(_ host: String) -> String {
        "^https?" + authority(escaped(host.lowercased()))
    }

    /// "https://example.com:443" as the start of a page's URL.
    nonisolated static func originFilter(_ origin: String) -> String {
        guard let url = URL(string: origin), let scheme = url.scheme, let host = url.host() else { return "^$" }
        let name = escaped(host)
        let standard = scheme == "https" ? 443 : 80
        let port = url.port.map { $0 == standard ? "(:\(standard))?" : ":\($0)" } ?? "(:\(standard))?"
        return "^\(scheme)://\(name)\(port)/"
    }

    // MARK: - the page's own address

    /// Where the addresses a name resolved to point, together: a website's
    /// if any is public (the connection may go there), this Mac's if all
    /// are loopback, else the network's. Nil for none.
    nonisolated static func space(ofResolved addresses: [String]) -> Space? {
        guard !addresses.isEmpty else { return nil }
        let spaces = addresses.map { space(of: $0) }
        if spaces.contains(.public) { return .public }
        return spaces.allSatisfy { $0 == .loopback } ? .loopback : .local
    }

    /// The numeric addresses the system's resolver gives a name. Blocks:
    /// never on the main thread.
    nonisolated static func addresses(of host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return [] }
        defer { freeaddrinfo(first) }
        var out: [String] = []
        var entry: UnsafeMutablePointer<addrinfo>? = first
        while let at = entry {
            var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if let address = at.pointee.ai_addr,
               getnameinfo(address, at.pointee.ai_addrlen, &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            }
            entry = at.pointee.ai_next
        }
        return out
    }

    /// Names pages went to, by where they resolved, for a while.
    private static var looked: [String: (space: Space, until: Date)] = [:]
    private static var looking: [String: [@MainActor () -> Void]] = [:]
    /// Names whose pages resolved to this Mac or the network: the list lets
    /// everything under them through, as under localhost.
    private(set) static var homes: Set<String> = []
    nonisolated static let keepsLook: TimeInterval = 300
    /// How long a page waits for its name before it loads as a website's.
    nonisolated static let waitsForLook: TimeInterval = 0.5

    /// A page on this host is this Mac's or the network's, as far as is
    /// known now: by its address as written, or where its name resolved
    /// lately.
    static func isHome(_ host: String?) -> Bool {
        guard var host = host?.lowercased(), !host.isEmpty else { return false }
        if space(of: host) != .public { return true }
        if host.hasSuffix(".") { host.removeLast() }
        // Shield names a page's site without its www.
        for name in [host, "www." + host] {
            if let known = looked[name], known.until > Date() { return known.space != .public }
        }
        return false
    }

    /// A page going here waits for `look` first: an http or https name that
    /// reads as a website's and wasn't looked up lately.
    static func needsLook(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host()?.lowercased(), !host.isEmpty, !host.contains(":"),
              ipv4(host) == nil, space(of: host) == .public else { return false }
        if let known = looked[host], known.until > Date() { return false }
        return true
    }

    /// Looks the page's name up, for `waitsForLook` at most, and calls back
    /// once the rules on every page know the answer. The lookup warms the
    /// resolver's cache for WebKit's own a moment later.
    static func look(_ url: URL, _ done: @escaping @MainActor () -> Void) {
        guard let host = url.host()?.lowercased() else { return done() }
        if looking[host] != nil { looking[host]?.append(done); return }
        looking[host] = [done]
        var answered = false
        let answer = {
            MainActor.assumeIsolated {
                guard !answered else { return }
                answered = true
                // No answer in time: a website's, until the lookup says.
                if (looked[host]?.until ?? .distantPast) <= Date() { looked[host] = (.public, Date().addingTimeInterval(30)) }
                (looking.removeValue(forKey: host) ?? []).forEach { $0() }
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let found = space(ofResolved: addresses(of: host))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    record(host, found)
                    if let found, found != .public { whenSettled(answer) } else { answer() }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + waitsForLook) { answer() }
    }

    /// A name's answer, kept a while. A name that came home, or left,
    /// changes the list and the ad blocker on open pages.
    static func record(_ host: String, _ found: Space?) {
        let now = Date()
        looked[host] = (found ?? .public, now.addingTimeInterval(found == nil ? 30 : keepsLook))
        if looked.count > 512 { looked = looked.filter { $0.value.until > now } }
        let home = (found ?? .public) != .public
        guard home != homes.contains(host) else { return }
        if home { homes.insert(host) } else { homes.remove(host) }
        recompile()
        Shield.shared.apply()
    }

    /// Forgets every name, for tests.
    static func forgetLooks() {
        looked = [:]
        guard !homes.isEmpty else { return }
        homes = []
        recompile()
    }

    // MARK: - what was said

    private static let key = "localNetwork.allowed"

    /// "https://host:443|loopback", allowed for good.
    private static var allowed: Set<String> {
        get { Set(Store.settings.stringArray(forKey: key) ?? []) }
        set { Store.settings.set(newValue.sorted(), forKey: key) }
    }

    /// Said no to while Yab is open: not asked again until it is next
    /// opened. A card left by leaving the page says no too, and that is no
    /// one's answer to keep.
    private static var refused: Set<String> = []

    static func said(_ origin: String, _ kind: Kind) -> Bool? {
        let entry = "\(origin)|\(kind.rawValue)"
        return allowed.contains(entry) ? true : refused.contains(entry) ? false : nil
    }

    static func remember(_ origin: String, _ kind: Kind, _ yes: Bool) {
        let entry = "\(origin)|\(kind.rawValue)"
        guard yes else { refused.insert(entry); return }
        refused.remove(entry)
        allowed.insert(entry)
        recompile()
    }

    static func forget(_ origin: String, _ kind: Kind) {
        let entry = "\(origin)|\(kind.rawValue)"
        refused.remove(entry)
        guard allowed.contains(entry) else { return }
        allowed.remove(entry)
        recompile()
    }

    static var granted: [Kind: [String]] {
        var out: [Kind: [String]] = [:]
        for entry in allowed {
            let parts = entry.split(separator: "|")
            guard parts.count == 2, let kind = Kind(rawValue: String(parts[1])) else { continue }
            out[kind, default: []].append(String(parts[0]))
        }
        return out
    }

    // MARK: - on every page

    private static var list: WKContentRuleList?
    private static var compiling: String?
    private static var settled: [() -> Void] = []
    private static let controllers = NSHashTable<WKUserContentController>.weakObjects()

    /// Every page's controller as its configuration is made, before the
    /// view: the list is there for its first request.
    static func protect(_ controller: WKUserContentController) {
        controllers.add(controller)
        if let list { controller.add(list) } else { start() }
    }

    static func start() {
        if list == nil { recompile() }
    }

    /// Runs once the list on every page is the latest: at once, or when
    /// the one being compiled arrives.
    static func whenSettled(_ done: @escaping () -> Void) {
        if compiling == nil, list != nil { done() } else { settled.append(done) }
    }

    /// The list on every page, for a test to wait on.
    static func ready() async -> WKContentRuleList? {
        start()
        await withCheckedContinuation { continuation in whenSettled { continuation.resume() } }
        return list
    }

    private static func recompile() {
        let text = rules(granted: granted, homes: Array(homes))
        let name = prefix + SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        guard list?.identifier != name, compiling != name, let store = WKContentRuleListStore.default() else { return }
        compiling = name
        // Compiled once; every launch after that only looks it up.
        store.lookUpContentRuleList(forIdentifier: name) { found, _ in
            MainActor.assumeIsolated {
                if let found { return install(found) }
                store.compileContentRuleList(forIdentifier: name, encodedContentRuleList: text) { compiled, error in
                    MainActor.assumeIsolated {
                        if let error { NSLog("yab: the local network list didn't compile: \(error)") }
                        if let compiled { install(compiled) } else if compiling == name { finish() }
                    }
                }
            }
        }
    }

    private static func install(_ fresh: WKContentRuleList) {
        // A newer list was asked for meanwhile: that one goes on.
        guard compiling == fresh.identifier else { return }
        let old = list
        list = fresh
        // On before the old one comes off, so no request slips between.
        for controller in controllers.allObjects {
            controller.add(fresh)
            if let old { controller.remove(old) }
        }
        finish()
        prune()
    }

    private static func finish() {
        compiling = nil
        let waiting = settled
        settled = []
        waiting.forEach { $0() }
    }

    /// Lists of ours from before, out of WebKit's store.
    private static func prune() {
        guard let store = WKContentRuleListStore.default(), let keep = list?.identifier else { return }
        store.getAvailableContentRuleListIdentifiers { names in
            for name in names ?? [] where name.hasPrefix(prefix) && name != keep {
                store.removeContentRuleList(forIdentifier: name) { _ in }
            }
        }
    }

    // MARK: - asking

    /// Chrome asks only once the address answered: a page knocking on
    /// ports nobody listens on asks nothing. Only this Mac's are tried;
    /// a connection to the network would be macOS's question about Yab.
    static func answers(_ url: URL, _ done: @escaping @MainActor (Bool) -> Void) {
        guard var host = url.host(), let scheme = url.scheme?.lowercased() else { return done(false) }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".localhost") { host = "127.0.0.1" }
        let port = url.port ?? (["https", "wss"].contains(scheme) ? 443 : 80)
        guard let to = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return done(false) }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: to, using: .tcp)
        var told = false
        let tell = { (yes: Bool) in
            MainActor.assumeIsolated {
                guard !told else { return }
                told = true
                connection.cancel()
                done(yes)
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: DispatchQueue.main.async { tell(true) }
            case .failed, .waiting: DispatchQueue.main.async { tell(false) }
            default: break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { tell(false) }
    }
}

extension Browser {
    /// WebKit said the list held a request back on this page: an https
    /// public page is asked about it, once a page, unless the site's
    /// answer is kept.
    func localNetworkBlocked(_ url: URL, in webView: WKWebView) {
        // Only an https or wss address: an https page's plain http request
        // is WebKit's mixed content, refused whatever is said here.
        guard let tab = tab(for: webView), let page = tab.address, page.scheme == "https",
              ["https", "wss"].contains(url.scheme?.lowercased() ?? ""),
              let host = page.host(), LocalNetwork.space(of: host) == .public, !LocalNetwork.isHome(host),
              let target = url.host(), let origin = Browser.origin(of: page) else { return }
        let kind: LocalNetwork.Kind = LocalNetwork.space(of: target) == .loopback ? .loopback : .local
        guard LocalNetwork.said(origin, kind) == nil,
              tab.localAsked.insert("\(page.absoluteString)|\(kind.rawValue)").inserted else { return }
        let ask = { [weak self, weak tab] in
            guard let self, let tab, tab.address == page,
                  !tab.asks.contains(where: { $0.kind == .localNetwork(kind == .loopback) }) else { return }
            self.ask(PageAsk(kind: .localNetwork(kind == .loopback), host: host), on: tab) { [weak tab] reply, _ in
                guard case .yes = reply else { return LocalNetwork.remember(origin, kind, false) }
                LocalNetwork.remember(origin, kind, true)
                // The request is gone by now; the page asks again, allowed.
                LocalNetwork.whenSettled { [weak tab] in
                    if let tab, tab.address == page { tab.reload() }
                }
            }
        }
        if kind == .loopback {
            LocalNetwork.answers(url) { if $0 { ask() } }
        } else {
            ask()
        }
    }
}
