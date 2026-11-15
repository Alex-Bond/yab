import WebKit

// What the page says about itself that a browser has to know: where the
// keyboard is, and whether there is a sign-in on it, and when one has just
// been sent, so the password can be
// offered a place in the keychain.
//
// Filling goes through the field's own setter and fires the events a keystroke
// would. Assigning to .value behind a framework's back leaves it thinking the
// box is still empty, which is a sign-in button that stays gray.

final class FormRelay: NSObject, PageScriptReceiving {
    static let name = "yabForms"

    weak var tab: Tab?

    func receive(_ message: PageScriptMessage) {
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        // A sign-in in a frame, App Store Connect's in Apple's: where its
        // boxes are and what was sent from it, under the frame's own site,
        // never the page's (RelayGuard). Everything else is the main frame's.
        guard message.frame.isMain else {
            let origin = message.frame.origin
            guard ["submit", "name", "settled", "focus"].contains(kind),
                  ["https", "http"].contains(origin.scheme.lowercased()), !origin.host.isEmpty
            else { return }
            let frame = (host: origin.host.lowercased(), clear: origin.scheme.lowercased() == "http")
            MainActor.assumeIsolated {
                switch kind {
                case "submit":
                    tab?.sentSignIn(user: body["user"] as? String ?? "", password: body["password"] as? String ?? "",
                                    frame: frame)
                case "name":
                    tab?.namedAccount(body["user"] as? String ?? "", on: frame.host)
                case "focus":
                    tab?.frameCaret(body, in: message.frame)
                default:
                    tab?.settleSignIn(navigated: false)
                }
            }
            return
        }
        MainActor.assumeIsolated {
            switch kind {
            case "form":
                tab?.foundSignIn()
                // A manager Yab unlocks, open by the time it's used.
                if let tab { ManagerKeep.signIn(tab, focused: false) }
            case "submit":
                tab?.sentSignIn(
                    user: body["user"] as? String ?? "",
                    password: body["password"] as? String ?? "",
                    action: body["action"] as? String ?? ""
                )
                // A new device's code or a blocked sign-in's mail comes next.
                if let tab { MailLinks.awaited(tab) }
            case "name":
                tab?.namedAccount(body["user"] as? String ?? "")
                // A name sent alone may be a sign-in by mail: its link comes soon.
                if let tab { MailLinks.awaited(tab) }
            case "codeAccepted":
                if let tab, let text = body["text"] as? String, let host = tab.address?.host() {
                    let codes = MailCodes.codes(in: MailCenter.shared.recent(minutes: MailCodes.fresh / 60), for: host)
                    if let code = codes.first(where: { $0.code == text && MailCodeState.shared.available($0) }) {
                        MailCodeState.shared.used(code, site: host)
                    }
                    CodeClip.shared.consumed(text, site: host)
                }
            case "codePasted":
                if let tab, let text = body["text"] as? String, let host = tab.address?.host() {
                    CodeClip.shared.consumed(text, site: host)
                }
            case "codeEntered":
                tab?.enteredAppleCode()
            case "settled":
                tab?.settleSignIn(navigated: false)
            case "focus":
                // The caret gone into a frame whose box has said so already:
                // the frame speaks for it (frameCaret).
                if body["inFrame"] as? Bool == true, body["rect"] is NSNull || body["rect"] == nil,
                   tab?.fieldFrame != nil { return }
                tab?.fieldFrame = nil
                (tab?.builtPage as? any PageInputContent)?.updateInputContent(body["content"] as? String)
                tab?.typing = body["typing"] as? Bool ?? false
                tab?.caretBox = (body["typing"] as? Bool ?? false)
                    ? Tab.CaretBox(password: body["password"] as? Bool ?? false, lines: body["lines"] as? Bool ?? false,
                                   label: body["label"] as? String ?? "", signIn: body["signin"] as? Bool ?? false,
                                   code: body["code"] as? Bool ?? false)
                    : nil
                tab?.fieldCode = body["code"] as? Bool ?? false
                if let tab, body["typing"] as? Bool == true, body["signin"] as? Bool == true || body["password"] as? Bool == true {
                    ManagerKeep.signIn(tab, focused: true)
                }
                let source: SentCode.Source?
                switch body["codeSource"] as? String {
                case "text": source = .text
                case "mail": source = .mail
                case "key": source = .key
                default: source = nil
                }
                let digits = body["codeDigits"] as? Int
                tab?.fieldCodeRequest = CodeRequest(source: source, digits: digits.flatMap { (4...8).contains($0) ? $0 : nil })
                // Which sign-in box the caret is in, and where it sits on the
                // page, so a list of accounts can hang from it.
                if let rect = body["rect"] as? [String: Double],
                   let x = rect["x"], let y = rect["y"], let w = rect["w"], let h = rect["h"] {
                    tab?.fieldQuery = body["typed"] as? String ?? ""
                    tab?.fieldSecret = body["secret"] as? Bool ?? false
                    tab?.fieldFresh = body["fresh"] as? Bool ?? false
                    tab?.fieldEmpty = body["empty"] as? Bool ?? true
                    tab?.fieldEmail = Tab.asksEmail(body)
                    tab?.fieldAutomatic = body["automatic"] as? Bool ?? false
                    tab?.fieldDocument = body["document"] as? String
                    tab?.fieldIdentity = body["field"] as? String
                    tab?.fieldAccount = (body["account"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    tab?.fieldDark = body["dark"] as? Bool
                    if let tab, tab.fieldCode, tab.fieldEmpty,
                       let document = tab.fieldDocument, let field = tab.fieldIdentity, let address = tab.address {
                        tab.waitingCode = Tab.WaitingCode(document: document, field: field, request: tab.fieldCodeRequest, address: address)
                    } else if tab?.fieldCode == true || body["typing"] as? Bool == true {
                        tab?.waitingCode = nil
                    }
                    tab?.fieldFocused(CGRect(x: x, y: y, width: w, height: h))
                } else {
                    tab?.fieldAutomatic = false
                    tab?.fieldFocused(nil)
                }
            case "draft":
                tab?.draft = body["on"] as? Bool ?? false
            case "busy":
                // An AI chat or a builder at work, or done (ChatBusy).
                if let tab {
                    ChatBusy.heard(tab, on: body["on"] as? Bool ?? false, word: body["word"] as? String,
                                   inFront: AgentFeed.shared.inFront(tab))
                }
            case "sent":
                // A message sent from the page's composer: its promises, and
                // whether it carried a link or a file (Promises.sent).
                if let tab, !tab.shy { Promises.shared.sent(body, in: tab) }
            case "snippet":
                if let tab { PageSnippets.shared.heard(body, in: tab) }
            case "paste":
                if let tab, let text = body["text"] as? String { SnippetOffers.shared.pasted(text, in: tab) }
            default:
                break
            }
        }
    }

    /// Whether sites are offered passkeys here (Settings › Passwords).
    ///
    /// Without Apple's browser entitlement a third-party WKWebView gets no
    /// Touch ID or iCloud passkeys, yet the API object exists, so sites offer
    /// the passkey path and strand you there. Taken away, they go straight to
    /// the password. Signed with the entitlement, as releases are, this is
    /// on, and yab carries out the sites' requests itself (Passkeys.swift).
    static var passkeysOffered: Bool {
        get { Store.settings.bool(forKey: "passkeys") }
        set { Store.settings.set(newValue, forKey: "passkeys") }
    }

    /// Only the passkey object goes. navigator.credentials itself stays: sites
    /// use it for stored passwords too, and that half still works.
    ///
    /// Unless an extension answers passkey requests itself: a password
    /// manager with your passkeys in it, as 1Password is. It puts its own get
    /// and create on navigator.credentials, and reaches for the passkey object
    /// from its own script as it does; from then on sites see the object, and
    /// the extension is the one they ask. Whatever it leaves to the browser is
    /// refused at once, as if you had said no, where WebKit would try and fail.
    static let withoutPasskeys = PageScript.load("forms-without-passkeys", vars: ["ASKED": PasskeyRelay.asked])

    /// The forms' script, and the snippets' after it on the same channel
    /// (PageSnippets).
    static let script = PageScript.load("forms", vars: ["GROUND": DropFrame.ground])
        + "\n" + PageScript.load("snippets", vars: ["GROUND": DropFrame.ground])

    /// The same script in the frames, where it only hears a sign-in sent:
    /// no lists, no snippets, nothing said about the caret.
    static let frameScript = "if (window.top !== window) {\n"
        + PageScript.load("forms", vars: ["GROUND": DropFrame.ground]) + "\n}"
}
