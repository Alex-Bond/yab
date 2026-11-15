import WebKit

// Cards and addresses on pages: which boxes ask for them, filling them, and
// noticing when a card or an address has just been sent, so it can be
// offered a place in the keychain (Wallet.swift, WalletKeep.swift).
//
// Unlike the sign-in script (Forms.swift) this one runs in every frame that
// has a box: a card's boxes are as often as not another site's, Stripe's,
// Adyen's, Braintree's, each box a frame of its own. Every frame gets a
// look for a box, and the frames that have one the whole script
// (`WalletRelay.soon`). A frame says what it has; the top page says where
// that frame sits, so a list can hang from a box inside it; and a pick
// fills every frame that has said it holds a card's boxes.
//
// A box is known by what the page says it is for (autocomplete="cc-number"),
// and failing that by its name, its label and its placeholder. Addresses
// count only where a form asks for three or more of their parts, so a lone
// email box for a newsletter is left alone.

final class WalletRelay: NSObject, PageScriptReceiving {
    static let name = "yabWallet"

    weak var tab: Tab?

    func receive(_ message: PageScriptMessage) {
        guard let body = message.body as? [String: Any],
              let kind = body["kind"] as? String
        else { return }
        let frame = message.frame
        MainActor.assumeIsolated { tab?.walletHeard(kind, body, frame) }
    }

    static let script = PageScript.load("wallet-forms", vars: ["GROUND": DropFrame.ground])

    /// What every frame gets instead: a look for a box, and on the first
    /// one, a word to yab, which puts `script` into that frame alone
    /// (Tab.walletHeard). A page's frames are mostly ads, a player, a
    /// widget, with nothing to type into; seventy kilobytes run in each of
    /// them, and a watch on every change to their pages, cost more than
    /// any other script of yab's in a page full of frames. A box that only
    /// shows up later, or inside a shadow root, sends for it when it does,
    /// or when the caret comes into it.
    static let soon = #"""
    (function () {
      if (window === window.top || window.__yabWallet || window.__yabWalletSoon) return;
      window.__yabWalletSoon = true;
      var BOX = 'input:not([type=hidden]), select, textarea';
      var asked = false, watch = null;
      function ask() {
        if (asked) return;
        asked = true;
        if (watch) watch.disconnect();
        document.removeEventListener('focusin', focused, true);
        try { window.webkit.messageHandlers.yabWallet.postMessage({ kind: 'load' }); } catch (e) {}
      }
      function focused(e) {
        var el = e.composedPath ? e.composedPath()[0] : e.target;
        if (el && el.matches && el.matches(BOX)) ask();
      }
      document.addEventListener('focusin', focused, true);
      if (document.querySelector(BOX)) return ask();
      if (!document.documentElement) return;
      // Only what was added is looked at, not the whole page again.
      watch = new MutationObserver(function (records) {
        for (var r = 0; r < records.length; r++) {
          var added = records[r].addedNodes;
          for (var i = 0; i < added.length; i++) {
            var n = added[i];
            if (n.nodeType === 1 && (n.matches(BOX) || n.querySelector(BOX))) return ask();
          }
        }
      });
      watch.observe(document.documentElement, { childList: true, subtree: true });
    })();
    """#
}

/// The field a list of cards or addresses hangs from, in the web view's
/// points, and which list.
struct WalletField: Equatable {
    /// A card's list, an address's, a whole form's row (FormFill), or the
    /// numbers for a phone box on its own (KnownPhone).
    enum Group: String { case card, address, form, phone }
    let group: Group
    let spot: CGRect
    let empty: Bool
    /// What the box itself asks, as the page's script names it: "name",
    /// "email", "line1"... An address's row says that first.
    var box = ""
    /// The page dark under the box (`DropFrame.ground`).
    var dark: Bool? = nil
    /// The box is on a page that came over https (or this Mac): no card
    /// goes into one anyone on the way could have written.
    let secure: Bool
}

/// What a tab has heard about cards and addresses on its page.
@MainActor
final class WalletWatch {
    /// A card number or security code entered in this tab may be visible in
    /// pixels even when the agent's text answers mask it. Keep screenshots
    /// unavailable for the rest of this tab's lifetime.
    var agentScreenshotBlocked = false
    /// The frames that have said they hold a card's or an address's
    /// boxes, newest last, each by the name its document gave itself.
    private var known: [(name: String, frame: PageFrame, card: Bool, address: Bool)] = []
    var frames: [PageFrame] { known.map(\.frame) }
    /// The origin of the document the caret was last in.
    var caretOrigin = ""
    /// A card's parts as its frames last said them: a number from one,
    /// the date from another, when each box is a frame of its own.
    var seen = SeenCard()
    var seenAt = Date.distantPast
    /// What was just sent, waiting on the page to show it went through.
    var sent: (card: SeenCard?, address: StreetAddress?, host: String, at: Date)?
    /// The caret's latest word, so a frame's place, found a moment later,
    /// isn't laid over a box the caret has already left.
    var beat = 0
    /// The document the caret was last said to be in: frames speak out of
    /// turn, and the page's "left" can arrive after a frame's "came in".
    var caretIn = ""
    /// The form the caret is in, as yab would fill it (FormFill).
    var form = FormWatch()
    /// The page whose list was put away with Escape (Browser.dropWallet):
    /// its other boxes don't offer the form or the addresses again while
    /// the tab is on it. A new document (Tab.navigationCommitted) or
    /// another address in the same one asks again. Not part of reset: a
    /// send that didn't move the page leaves the no standing.
    var declined: String?
    /// A form's answers just sent and not kept yet, waiting on the page to
    /// show it went through (Tab.answersSettle). Not part of reset: a card
    /// sent with them settles on its own.
    var answered: (fresh: [FormAnswers.Fresh], site: String, frame: PageFrame?, at: Date)?

    func remember(_ frame: PageFrame, as name: String, card: Bool = true, address: Bool = false) {
        guard !frame.isMain, !name.isEmpty else { return }
        let was = known.first { $0.name == name }
        known.removeAll { $0.name == name }
        known.append((name, frame, card || (was?.card ?? false), address || (was?.address ?? false)))
        if known.count > 12 { known.removeFirst(known.count - 12) }
    }

    /// The frames a card or an address may go into, on a page of `main`'s
    /// origin: the one the caret is in, those of the page's own origin or
    /// the caret frame's, and those of a payment company, Stripe's and the
    /// like. Never a frame of any other site on the page, an ad's, a chat
    /// widget's, however it names its boxes.
    func frames(for group: WalletField.Group, main: String) -> [PageFrame] {
        known.filter { holds($0, group) && trusted($0, main: main) }.map(\.frame)
    }

    /// The sites whose frames said they hold those boxes but are none of
    /// the above, "localhost:8752": left empty, and said so, since boxes
    /// left empty with nothing said read as a fill that broke.
    func passed(for group: WalletField.Group, main: String) -> [String] {
        let hosts = known.filter { holds($0, group) && !trusted($0, main: main) }.map { entry in
            let o = entry.frame.origin
            return o.port == 0 ? o.host.lowercased() : "\(o.host.lowercased()):\(o.port)"
        }
        return Array(Set(hosts.filter { !$0.isEmpty })).sorted()
    }

    private func holds(_ entry: (name: String, frame: PageFrame, card: Bool, address: Bool), _ group: WalletField.Group) -> Bool {
        group == .card ? entry.card : entry.address
    }

    private func trusted(_ entry: (name: String, frame: PageFrame, card: Bool, address: Bool), main: String) -> Bool {
        let origin = WalletWatch.origin(entry.frame)
        return entry.name == caretIn || origin == main || (!caretOrigin.isEmpty && origin == caretOrigin)
            || WalletWatch.payments(entry.frame.origin.host) || WalletWatch.sameSite(origin, main)
    }

    static func origin(_ frame: PageFrame) -> String {
        let o = frame.origin
        let port = o.port == 0 ? -1 : o.port
        return "\(o.scheme.lowercased())://\(o.host.lowercased()):\(port)"
    }

    /// The companies whose frames hold a checkout's card boxes for the shop.
    static let processors: Set<String> = [
        "stripe.com", "stripe.network", "braintreegateway.com", "braintree-api.com", "paypal.com", "paypalobjects.com",
        "adyen.com", "adyenpayments.com", "checkout.com", "squareup.com", "squarecdn.com", "recurly.com", "chargebee.com",
        "worldpay.com", "authorize.net", "cybersource.com", "spreedly.com", "verygoodvault.com", "basistheory.com",
        "evervault.com", "mollie.com", "klarna.com", "shopify.com", "shopifycs.com", "paddle.com", "razorpay.com",
        "payu.com", "gocardless.com", "bluesnap.com", "nuvei.com", "globalpayments.com", "heartlandportico.com",
        "clover.com", "mercadopago.com", "yookassa.ru", "cloudpayments.ru", "tinkoff.ru", "tbank.ru", "sber.ru",
    ]

    /// The shop's own other host, pay.shop.com beside shop.com, over https.
    /// Not on this Mac's own names, where any port is anyone's.
    static func sameSite(_ a: String, _ b: String) -> Bool {
        guard let x = URL(string: a), let y = URL(string: b), x.scheme == "https", y.scheme == "https",
              let hx = x.host(), let hy = y.host() else { return false }
        let site = Vault.registrable(hx)
        return site.contains(".") && site == Vault.registrable(hy)
    }

    static func payments(_ host: String) -> Bool {
        processors.contains(Vault.registrable(host)) || (Store.testing && testProcessors.contains(host.lowercased()))
    }

    /// Hosts a test run counts as a payment company, a local stand-in for
    /// Stripe's frames (Bench `wallet` "processor"). Test runs only.
    nonisolated(unsafe) static var testProcessors: Set<String> = []

    /// The list was put away on `address`, or on the same page with only
    /// its #fragment moved.
    func declined(on address: URL?) -> Bool {
        declined != nil && declined == Self.page(address)
    }

    static func page(_ address: URL?) -> String? {
        address.map { String($0.absoluteString.prefix { $0 != "#" }) }
    }

    func reset() {
        known = []
        seen = SeenCard()
        seenAt = .distantPast
        sent = nil
        form = FormWatch()
    }
}

/// Numbers a page sends. A page can send anything (1e300, Infinity, NaN,
/// 3.5), and Int(Double) traps on what Int can't hold, so a number is
/// taken only when it is whole and in range.
enum PageNumber {
    /// A whole number as the page sent it, or nil.
    static func int(_ any: Any?) -> Int? {
        if let number = any as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            // A double read through `as? Int` comes back rounded, 2^63 as
            // Int.max, so a double is only taken when it is exact.
            if CFNumberIsFloatType(number) { return Int(exactly: number.doubleValue) }
            return number as? Int
        }
        if let whole = any as? Int { return whole }
        guard let double = any as? Double else { return nil }
        return Int(exactly: double)
    }

    /// A whole number in the range, or nil.
    static func int(_ any: Any?, in range: ClosedRange<Int>) -> Int? {
        int(any).flatMap { range.contains($0) ? $0 : nil }
    }

    /// The four sides of a page's rect, or nil unless every one is finite.
    static func rect(_ any: Any?) -> CGRect? {
        guard let r = any as? [String: Double],
              let x = r["x"], let y = r["y"], let w = r["w"], let h = r["h"],
              [x, y, w, h].allSatisfy(\.isFinite) else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

/// A card as a page held it: the number, the name, the date. Never the
/// security code.
struct SeenCard: Equatable {
    var number = ""
    var name = ""
    var month = 0
    var year = 0
    var csc = ""

    init() {}

    init?(_ any: Any?) {
        guard let body = any as? [String: Any] else { return nil }
        number = (body["number"] as? String ?? "").filter(\.isNumber)
        name = (body["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        month = PageNumber.int(body["month"], in: 1...12) ?? 0
        year = Wallet.fullYear(PageNumber.int(body["year"], in: 0...9999) ?? 0)
        csc = (body["csc"] as? String ?? "").filter(\.isNumber)
    }

    /// What the other says, over what this one says, part by part.
    mutating func take(_ other: SeenCard) {
        if !other.number.isEmpty { number = other.number }
        if !other.name.isEmpty { name = other.name }
        if other.month > 0 { month = other.month }
        if other.year > 0 { year = other.year }
        if !other.csc.isEmpty { csc = other.csc }
    }

    /// A number with its check digit right and a date that hasn't passed.
    var keepable: Bool {
        guard Wallet.luhn(number), (1...12).contains(month), year >= 2000 else { return false }
        let now = Calendar.current.dateComponents([.year, .month], from: Date())
        return (year, month) >= (now.year ?? 0, now.month ?? 0)
    }
}

extension StreetAddress {
    /// As a page's boxes held it.
    init?(from any: Any?) {
        guard let body = any as? [String: Any] else { return nil }
        func field(_ key: String) -> String { (body[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        self.init(id: UUID().uuidString)
        name = field("name")
        organization = field("organization")
        street = field("street")
        city = field("city")
        region = field("region")
        postal = field("postal")
        country = field("country")
        phone = field("phone")
        email = field("email")
        guard whole else { return nil }
    }

    /// As the page's script takes it, to fill.
    var filling: [String: Any] {
        ["name": name, "organization": organization, "street": street, "city": city, "region": region,
         "postal": postal, "country": country, "phone": phone, "email": email]
    }
}

extension Tab {
    /// A frame's word about cards and addresses. See `WalletRelay`.
    func walletHeard(_ kind: String, _ body: [String: Any], _ frame: PageFrame) {
        // What was typed and sent, to be offered a place in the keychain or
        // the answers, is taken only from a frame that may hold it: any
        // frame can fill boxes of its own and send them (RelayGuard).
        if ["seen", "send", "answers"].contains(kind), !walletTrusts(frame) { return }
        switch kind {
        case "load":
            // A frame's first box: the rest of the script, into that frame
            // alone (WalletRelay.soon). One already holding it says no more.
            guard !frame.isMain else { return }
            builtPage?.run(WalletRelay.script, in: .yab, frame: frame)
        case "focus":
            walletCaret(body, frame)
        case "fields":
            wallet.remember(frame, as: body["frame"] as? String ?? "", card: body["card"] as? Bool ?? false, address: body["address"] as? Bool ?? false)
        case "seen":
            wallet.remember(frame, as: body["frame"] as? String ?? "")
            if let card = SeenCard(body["card"]) {
                if !card.number.isEmpty || !card.csc.isEmpty { wallet.agentScreenshotBlocked = true }
                wallet.seen.take(card)
                wallet.seenAt = Date()
            }
        case "sensitive":
            wallet.agentScreenshotBlocked = true
        case "send":
            walletSent(body, frame)
        case "answers":
            formAnswered(body["fields"] as? [[String: Any]] ?? [], frame)
        case "formTaken":
            wallet.form.filledAt = nil
        case "ghost":
            wallet.form.ghost = body["v"] as? String ?? ""
        case "formNo":
            // Escape on a box's pale value: no for the page, as Escape on
            // the list is (Browser.dropWallet). ⌥↩ still fills.
            wallet.declined = WalletWatch.page(address)
        case "fileAway":
            onFilesAway?(self)
        default:
            break
        }
    }

    /// The page's own frames, a payment company's, and the one the caret
    /// was last in: the frames a card or an answer may go into, too.
    private func walletTrusts(_ frame: PageFrame) -> Bool {
        RelayGuard.ownFrame(frame, of: self) || WalletWatch.payments(frame.origin.host)
            || (!wallet.caretOrigin.isEmpty && WalletWatch.origin(frame) == wallet.caretOrigin)
    }

    private func walletCaret(_ body: [String: Any], _ frame: PageFrame) {
        let name = body["frame"] as? String ?? ""
        guard let raw = body["group"] as? String, let group = WalletField.Group(rawValue: raw),
              let box = PageNumber.rect(body["rect"])
        else {
            // Left: only the document the caret was in can say so.
            guard name == wallet.caretIn else { return }
            wallet.beat += 1
            onWalletField?(self, nil)
            return
        }
        wallet.caretIn = name
        wallet.caretOrigin = WalletWatch.origin(frame)
        if group != .card { wallet.form.frame = frame.isMain ? nil : frame }
        wallet.beat += 1
        let beat = wallet.beat
        wallet.remember(frame, as: body["frame"] as? String ?? "", card: group == .card, address: group == .address || group == .phone)
        let empty = body["empty"] as? Bool ?? true
        // A frame's box is secure only on a secure page too.
        let secure = ((body["secure"] as? Bool ?? false) || Tab.standIn(address)) && (address?.scheme == "https" || Tab.local(address))
        let tell: (CGPoint, Bool?) -> Void = { [weak self] offset, dark in
            guard let self, self.wallet.beat == beat else { return }
            let zoom = self.builtPage?.pageZoom ?? 1
            let spot = box.offsetBy(dx: offset.x, dy: offset.y)
            self.onWalletField?(self, WalletField(
                group: group,
                spot: CGRect(x: spot.minX * zoom, y: spot.minY * zoom, width: spot.width * zoom, height: spot.height * zoom),
                empty: empty, box: body["field"] as? String ?? "", dark: dark, secure: secure
            ))
        }
        let dark = body["dark"] as? Bool
        guard !frame.isMain else { return tell(.zero, dark) }
        // Where the frame is, asked of the page around it.
        guard let web = builtPage else { return }
        web.call(
            "return window.__yabWallet ? window.__yabWallet.frameAt(href, w, h) : null",
            arguments: ["href": body["href"] as? String ?? "", "w": body["vw"] as? Double ?? 0, "h": body["vh"] as? Double ?? 0],
            in: .yab, frame: nil
        ) { result in
            MainActor.assumeIsolated {
                guard case .success(let value) = result, let at = value as? [String: Any],
                      let fx = at["x"] as? Double, let fy = at["y"] as? Double, fx.isFinite, fy.isFinite
                else { return }
                tell(CGPoint(x: fx, y: fy), dark ?? at["dark"] as? Bool)
            }
        }
    }

    /// Plain http on this Mac is as good as https: nobody is on the way.
    static func local(_ url: URL?) -> Bool {
        guard let host = url?.host()?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".localhost") || standIn(url)
    }

    /// A test world's stand-in for a real site: a name under localtest.me,
    /// public DNS that answers 127.0.0.1, served by demos/server.py or an
    /// eval in the clear. Treated as this Mac's own, there only.
    static func standIn(_ url: URL?) -> Bool {
        guard Store.testing, let host = url?.host()?.lowercased() else { return false }
        return host.hasSuffix(".localtest.me")
    }

    private func walletSent(_ body: [String: Any], _ frame: PageFrame) {
        guard let host = address?.host()?.lowercased() else { return }
        var card = SeenCard(body["card"])
        // The number from the frames the page keeps it in.
        if Date().timeIntervalSince(wallet.seenAt) < 600 {
            var joined = wallet.seen
            if let card { joined.take(card) }
            card = joined
        }
        let address = StreetAddress(from: body["address"])
        let keep = card.flatMap { $0.keepable ? $0 : nil }
        guard keep != nil || address != nil else { return }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        wallet.sent = (keep, address, bare, Date())
        let stamp = wallet.sent?.at
        // Asked a few times: a payment takes a while to go through.
        for delay in [1.2, 2.5, 6.0, 12.0, 25.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.wallet.sent?.at == stamp else { return }
                self.walletSettle(navigated: false)
            }
        }
    }

    /// The page has moved on, or a moment has passed since something was
    /// sent: if what was sent is no longer in its boxes, it went through.
    func walletSettle(navigated: Bool) {
        guard let sent = wallet.sent else { return }
        guard Date().timeIntervalSince(sent.at) < 120 else {
            wallet.sent = nil
            return
        }
        let finish = { [weak self] in
            guard let self, let sent = self.wallet.sent else { return }
            self.wallet.reset()
            self.onPaid?(self, sent.card, sent.address, sent.host)
        }
        // Even when the page moved on: a decline shown with a new address
        // (pushState) still has the card in its boxes, and is no payment.
        // Asked once the new page is there, not while the old one answers.
        if navigated {
            let stamp = sent.at
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, self.wallet.sent?.at == stamp else { return }
                self.walletSettle(navigated: false)
            }
            return
        }
        guard let web = builtPage else { return }
        let frames = wallet.frames
        var left = frames.count + 1
        var still = false
        var over = false
        let heard: (Bool) -> Void = { present in
            guard !over else { return }
            still = still || present
            left -= 1
            if left == 0 { over = true; if !still { finish() } }
        }
        // A frame of a page that has gone may never answer at all: what
        // hasn't answered by then has gone with its boxes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard !over else { return }
            over = true
            if !still { finish() }
        }
        let ask = "return window.__yabWallet ? window.__yabWallet.present() : false"
        web.call(ask, arguments: [:], in: .yab, frame: nil) { result in
            MainActor.assumeIsolated { heard((try? result.get()) as? Bool ?? false) }
        }
        // A frame that has gone answers with an error: its boxes went with it.
        for frame in frames {
            web.call(ask, arguments: [:], in: .yab, frame: frame) { result in
                MainActor.assumeIsolated { heard((try? result.get()) as? Bool ?? false) }
            }
        }
    }

    /// Puts a card or an address into the page: the top page and every
    /// frame that said it holds a card's boxes. Only into the page it was
    /// picked for. `done` hears how many boxes took something.
    func walletFill(_ data: [String: Any], what: WalletField.Group, origin: String, done: @escaping (Int) -> Void) {
        guard !gone, !asleep, let web = builtPage, Tab.originOf(address) == origin else { return done(0) }
        let frames: [PageFrame?] = [nil] + wallet.frames(for: what, main: origin).map { Optional($0) }
        // What went into a page, so no agent reads it back (Wallet.hide).
        if what == .card, let number = data["number"] as? String {
            wallet.agentScreenshotBlocked = true
            Wallet.filled.insert(number)
        }
        var left = frames.count
        var filled = 0
        var told = false
        let tell = { guard !told else { return }; told = true; done(filled) }
        // A frame gone with its page may never answer: what did answer counts.
        // A page's own menus are opened and picked one by one, so a while.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { tell() }
        for frame in frames {
            web.call(
                "return window.__yabWallet ? window.__yabWallet.fill(data, what) : 0",
                arguments: ["data": data, "what": what.rawValue],
                in: .yab, frame: frame
            ) { result in
                MainActor.assumeIsolated {
                    filled += (try? result.get()) as? Int ?? 0
                    left -= 1
                    if left == 0 { tell() }
                }
            }
        }
    }

    /// The sites whose frames hold such boxes and get nothing (WalletWatch.passed).
    func walletPassed(_ group: WalletField.Group) -> [String] {
        wallet.passed(for: group, main: Tab.originOf(address))
    }

    /// The sites besides this page's own whose frames a card would go
    /// into, for the Touch ID question to name them.
    func walletHosts(_ group: WalletField.Group) -> [String] {
        let here = address?.host()?.lowercased() ?? ""
        return Array(Set(wallet.frames(for: group, main: Tab.originOf(address)).map { $0.origin.host.lowercased() }
            .filter { !$0.isEmpty && $0 != here })).sorted()
    }

    /// Scheme, host and port.
    static func originOf(_ url: URL?) -> String {
        guard let url else { return "" }
        return "\(url.scheme?.lowercased() ?? "")://\(url.host()?.lowercased() ?? ""):\(url.port ?? -1)"
    }
}
