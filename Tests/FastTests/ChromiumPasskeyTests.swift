import AppKit
import JavaScriptCore
import Testing
@testable import Fast

@MainActor
struct ChromiumPasskeyTests {
    // One path: on a Chromium tab no page script stands in for
    // navigator.credentials, on or off. Chromium's own WebAuthn checks a
    // request and hands it to Yab (CEF 0113, ChromiumWebAuthn). Switched off,
    // the page still hears that none are offered, as on WebKit.
    @Test func chromiumHasNoPasskeyPageScript() {
        _ = NSApplication.shared
        let before = FormRelay.passkeysOffered
        defer { FormRelay.passkeysOffered = before }
        let tab = Tab(shy: true)
        defer { tab.close() }
        for offered in [false, true] {
            FormRelay.passkeysOffered = offered
            let scripts = PageScripts.chromium(for: tab, .init(host: "github.com", css: ""))
            #expect(!scripts.contains { $0.source == PasskeyRelay.page })
            #expect(scripts.contains { $0.source == FormRelay.withoutPasskeys } == !offered)
            #expect(scripts.contains { $0.source == PasskeyRelay.bridge && $0.world == .yab && !$0.atEnd })
        }
    }

    // What Chromium hands over becomes Yab's request, PRF salts and all.
    @Test func chromiumOptionsBecomeTheCeremonysRequest() throws {
        let create: [String: Any] = [
            "rp": ["id": "example.com", "name": "Example"], "user": ["id": "dXNlcg", "name": "a@example.com", "displayName": "A"],
            "challenge": "AAEC", "pubKeyCredParams": [["type": "public-key", "alg": -7], ["type": "public-key", "alg": -257]],
            "excludeCredentials": [["type": "public-key", "id": "AQI", "transports": ["usb"]]],
            "authenticatorSelection": ["residentKey": "required", "userVerification": "required"], "attestation": "none",
            "extensions": ["prf": ["eval": ["first": "c2FsdA"]], "credProps": true],
        ]
        let made = try #require(ChromiumWebAuthn.body(kind: "create", options: create, token: "t"))
        #expect((made["rp"] as? [String: Any])?["id"] as? String == "example.com")
        #expect(made["algorithms"] as? [Int] == [-7, -257])
        #expect(made["residentKey"] as? String == "required")
        #expect(((made["prf"] as? [String: Any])?["eval"] as? [String: Any])?["first"] as? String == "c2FsdA")
        let get: [String: Any] = [
            "challenge": "AAEC", "rpId": "vault.bitwarden.com", "allowCredentials": [], "userVerification": "preferred",
            "extensions": ["prf": ["evalByCredential": ["AQI": ["first": "c2FsdA"]]]],
        ]
        let asked = try #require(ChromiumWebAuthn.body(kind: "get", options: get, token: "t"))
        #expect(asked["rpId"] as? String == "vault.bitwarden.com")
        #expect(((asked["prf"] as? [String: Any])?["byCredential"] as? [String: Any])?["AQI"] != nil)
        #expect(ChromiumWebAuthn.body(kind: "isUvpaa", options: [:], token: "t") == nil)
    }

    // The answer is the WebAuthn JSON Chromium's parser takes: a create with
    // its attestation object, authenticator data, algorithm and DER key.
    @Test func ceremonyRepliesBecomeChromiumsJSON() throws {
        let made = Passkeys.rehearsal("create", rp: "example.com", origin: "https://example.com", challenge: Data([1, 2, 3]))
        let json = try #require(ChromiumWebAuthn.response(kind: "create", reply: made, options: ["extensions": ["credProps": true]]))
        let value = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(value["type"] as? String == "public-key")
        #expect(value["id"] as? String == value["rawId"] as? String)
        let response = try #require(value["response"] as? [String: Any])
        #expect(response["publicKeyAlgorithm"] as? Int == -7)
        #expect((response["publicKey"] as? String)?.isEmpty == false)
        #expect(response["attestationObject"] != nil && response["authenticatorData"] != nil && response["transports"] != nil)
        // Canonical CBOR, as Chromium reads it: authData's length in its
        // shortest form (0x58 and one byte below 256).
        let object = try #require(Passkeys.data(response["attestationObject"]))
        let at = try #require(object.range(of: Data("authData".utf8)))
        #expect(object[at.upperBound] == 0x58)
        #expect(((value["clientExtensionResults"] as? [String: Any])?["credProps"] as? [String: Any])?["rk"] as? Bool == true)

        let got = Passkeys.rehearsal("get", rp: "example.com", origin: "https://frame.example", challenge: Data([1]),
                                     crossOrigin: "https://top.example")
        let text = try #require(ChromiumWebAuthn.response(kind: "get", reply: got, options: [:]))
        let answer = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let fields = try #require(answer["response"] as? [String: Any])
        #expect(fields["signature"] != nil && fields["userHandle"] != nil)
        let client = try #require(Passkeys.data(fields["clientDataJSON"]))
        let data = try #require(try JSONSerialization.jsonObject(with: client) as? [String: Any])
        #expect(data["crossOrigin"] as? Bool == true)
        #expect(data["topOrigin"] as? String == "https://top.example")
        #expect(ChromiumWebAuthn.response(kind: "get", reply: ["error": "NotAllowedError"], options: [:]) == nil)
    }

    // Blink tells pages this browser takes largeBlob and appid
    // (getClientCapabilities), and Chrome on the Mac serves them, a blob
    // through iCloud Keychain's passkeys, a U2F AppID through a security key.
    // Both reach the sheet and come back as Chromium writes them, instead of
    // being dropped on the way (R2037).
    @Test func largeBlobAndAppIDGoToTheSheetAndBack() throws {
        let create: [String: Any] = [
            "rp": ["id": "example.com", "name": "Example"], "user": ["id": "dXNlcg", "name": "a@example.com", "displayName": "A"],
            "challenge": "AAEC", "pubKeyCredParams": [["type": "public-key", "alg": -7]],
            "extensions": ["largeBlob": ["support": "required"]],
        ]
        let made = try #require(ChromiumWebAuthn.body(kind: "create", options: create, token: "t"))
        #expect((made["largeBlob"] as? [String: Any])?["support"] as? String == "required")
        #expect(Passkeys.largeBlobRegistration(made["largeBlob"])?.supportRequirement == .required)
        #expect(Passkeys.largeBlobRegistration(["support": "preferred"])?.supportRequirement == .preferred)
        #expect(Passkeys.largeBlobRegistration(nil) == nil)

        let readOptions: [String: Any] = ["challenge": "AAEC", "rpId": "example.com",
                                          "extensions": ["largeBlob": ["read": true], "appid": "https://example.com/u2f"]]
        let read = try #require(ChromiumWebAuthn.body(kind: "get", options: readOptions, token: "t"))
        #expect(read["appid"] as? String == "https://example.com/u2f")
        if case .read? = Passkeys.largeBlobAssertion(read["largeBlob"])?.operation {} else { Issue.record("no read asked") }
        let writeOptions: [String: Any] = ["challenge": "AAEC", "rpId": "example.com", "extensions": ["largeBlob": ["write": "AQID"]]]
        let write = try #require(ChromiumWebAuthn.body(kind: "get", options: writeOptions, token: "t"))
        if case .write(let blob)? = Passkeys.largeBlobAssertion(write["largeBlob"])?.operation {
            #expect(blob == Data([1, 2, 3]))
        } else {
            Issue.record("no write asked")
        }

        func results(_ kind: String, _ reply: [String: Any], _ options: [String: Any]) throws -> [String: Any] {
            let json = try #require(ChromiumWebAuthn.response(kind: kind, reply: reply, options: options))
            let value = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            return try #require(value["clientExtensionResults"] as? [String: Any])
        }
        var passkey = Passkeys.rehearsal("create", rp: "example.com", origin: "https://example.com", challenge: Data([1]))
        passkey["largeBlob"] = ["supported": true]
        #expect((try results("create", passkey, create)["largeBlob"] as? [String: Any])?["supported"] as? Bool == true)
        // A security key's credential, or macOS saying nothing: not kept.
        passkey["largeBlob"] = nil
        #expect((try results("create", passkey, create)["largeBlob"] as? [String: Any])?["supported"] as? Bool == false)
        #expect(try results("create", passkey, [:])["largeBlob"] == nil)

        var got = Passkeys.rehearsal("get", rp: "example.com", origin: "https://example.com", challenge: Data([1]))
        got["largeBlob"] = ["blob": "AQID"]
        got["appid"] = true
        let readResults = try results("get", got, readOptions)
        #expect((readResults["largeBlob"] as? [String: Any])?["blob"] as? String == "AQID")
        #expect(readResults["appid"] as? Bool == true)
        got["largeBlob"] = nil
        #expect((try results("get", got, writeOptions)["largeBlob"] as? [String: Any])?["written"] as? Bool == false)
        #expect(try results("get", got, [:])["largeBlob"] == nil)
    }

    private func context(native: String) throws -> JSContext {
        let c = try #require(JSContext())
        c.evaluateScript("""
        var window = globalThis; window.top = window;
        function CredentialsContainer() {}
        CredentialsContainer.prototype.get = function () {};
        CredentialsContainer.prototype.create = function () {};
        var navigator = { credentials: new CredentialsContainer() };
        function PublicKeyCredential() {}
        window.addEventListener = function () {};
        PublicKeyCredential.getClientCapabilities = \(native);
        """)
        c.evaluateScript(PasskeyRelay.page)
        try #require(c.exception == nil)
        c.evaluateScript("var result; PublicKeyCredential.getClientCapabilities().then(v => result = v); true")
        try #require(c.exception == nil)
        return c
    }

    @Test func capabilityAnswersBelongToTheMacRelay() throws {
        let c = try context(native: "function () { return Promise.resolve({immediateGet:true, conditionalGet:true, 'extension:largeBlob':true, 'extension:credProps':true}); }")
        #expect(c.evaluateScript("result.immediateGet")?.toBool() == false)
        #expect(c.evaluateScript("result.conditionalGet")?.toBool() == false)
        #expect(c.evaluateScript("result.passkeyPlatformAuthenticator")?.toBool() == true)
        #expect(c.evaluateScript("result.userVerifyingPlatformAuthenticator")?.toBool() == true)
        #expect(c.evaluateScript("result['extension:largeBlob']")?.toBool() == false)
        #expect(c.evaluateScript("result['extension:prf']")?.toBool() == true)
        #expect(c.evaluateScript("result['extension:credProps']")?.toBool() == true)
    }

    // Chrome's immediate UI mode answers at once, NotAllowedError, when no
    // credential is at hand, and shows no sheet: nothing of the Mac's can be
    // looked at without one (#1843). Ordinary requests still ask the Mac.
    @Test func immediateMediationIsRefusedAtOnceWithoutTheSheet() throws {
        let c = try #require(JSContext())
        c.evaluateScript("""
        var window = globalThis; window.top = window;
        function CredentialsContainer() {}
        CredentialsContainer.prototype.get = function () { return Promise.resolve('native'); };
        CredentialsContainer.prototype.create = function () {};
        var navigator = { credentials: new CredentialsContainer() };
        function PublicKeyCredential() {}
        function DOMException(message, name) { this.message = message; this.name = name; }
        function CustomEvent(type, init) { this.type = type; this.detail = init && init.detail; }
        function btoa(text) { return 'AA'; }
        var asked = [];
        window.addEventListener = function () {};
        window.dispatchEvent = function (event) { asked.push(JSON.parse(event.detail).kind); };
        """)
        c.evaluateScript(PasskeyRelay.page)
        try #require(c.exception == nil)
        // Chrome 149's shape, then its trial's.
        c.evaluateScript("""
        var immediate = 'pending', trial = 'pending', ordinary = 'pending';
        navigator.credentials.get({ password: true, publicKey: { challenge: new Uint8Array(32) }, uiMode: 'immediate' })
          .then(function () { immediate = 'credential'; }, function (e) { immediate = e.name; });
        navigator.credentials.get({ mediation: 'immediate', publicKey: { challenge: new Uint8Array(32) } })
          .then(function () { trial = 'credential'; }, function (e) { trial = e.name; });
        """)
        try #require(c.exception == nil)
        #expect(c.evaluateScript("immediate")?.toString() == "NotAllowedError")
        #expect(c.evaluateScript("trial")?.toString() == "NotAllowedError")
        #expect(c.evaluateScript("asked.length")?.toInt32() == 0)
        c.evaluateScript("""
        navigator.credentials.get({ publicKey: { challenge: new Uint8Array(32) } })
          .then(function () { ordinary = 'credential'; }, function (e) { ordinary = e.name; });
        """)
        try #require(c.exception == nil)
        #expect(c.evaluateScript("asked.join()")?.toString() == "get")
        #expect(c.evaluateScript("ordinary")?.toString() == "pending")
    }

    // Another site's web frame: WebKit's own WebAuthn on a WebKit tab.
    @Test func anotherSitesFrameIsWebKitsOwn() throws {
        func heard(_ script: String) throws -> String? {
            let c = try #require(JSContext())
            c.evaluateScript("""
            var window = globalThis; window.top = {};
            var location = { hostname: 'pk.example', protocol: 'https:', ancestorOrigins: ['https://sys.example'] };
            function URL(text) { this.hostname = text.replace(/^[a-z]+:\\/\\//, '').split(/[\\/:]/)[0]; }
            function CredentialsContainer() {}
            CredentialsContainer.prototype.get = function () { return Promise.resolve('native'); };
            CredentialsContainer.prototype.create = function () { return Promise.resolve('native'); };
            var navigator = { credentials: new CredentialsContainer() };
            function PublicKeyCredential() {}
            function DOMException(message, name) { this.message = message; this.name = name; }
            function CustomEvent(type, init) { this.type = type; this.detail = init && init.detail; }
            function btoa(text) { return 'AA'; }
            var asked = [], outcome = 'pending';
            window.addEventListener = function () {};
            window.dispatchEvent = function (event) { asked.push(JSON.parse(event.detail).kind); };
            """)
            c.evaluateScript(script)
            try #require(c.exception == nil)
            c.evaluateScript("""
            navigator.credentials.get({ publicKey: { challenge: new Uint8Array(32) } })
              .then(function (value) { outcome = value; }, function (e) { outcome = e.name; });
            """)
            try #require(c.exception == nil)
            return c.evaluateScript("asked.join() + '|' + outcome")?.toString()
        }
        #expect(try heard(PasskeyRelay.page) == "|native")
    }

    @Test func olderOrFailingEngineStillAnswersCapabilities() throws {
        for native in ["undefined", "function () { return Promise.reject(new Error('unavailable')); }", "function () { throw new Error('unavailable'); }"] {
            let c = try context(native: native)
            #expect(c.evaluateScript("result.passkeyPlatformAuthenticator")?.toBool() == true)
            #expect(c.evaluateScript("result.immediateGet")?.toBool() == false)
            #expect(c.evaluateScript("result.conditionalGet")?.toBool() == false)
        }
    }

    // Passkey autofill (CEF 0127): a pick from the rows under the box asks
    // the Mac's sheet for that one passkey alone, as Chromium dispatches a
    // picked iCloud Keychain passkey, the request's extensions kept.
    @Test func aPickedPasskeyIsAskedForAloneFromTheMac() throws {
        let options: [String: Any] = [
            "challenge": "AAEC", "rpId": "example.com", "userVerification": "required",
            "allowCredentials": [["type": "public-key", "id": "AQI"], ["type": "public-key", "id": "AwQ"]],
            "extensions": ["prf": ["eval": ["first": "c2FsdA"]]],
        ]
        let body = try #require(ChromiumWebAuthn.pickedBody(options, id: "BQY", token: "chromium-7"))
        #expect(body["kind"] as? String == "get")
        #expect(body["rpId"] as? String == "example.com")
        #expect(body["token"] as? String == "chromium-7")
        #expect(body["platformOnly"] as? Bool == true)
        #expect((body["allowCredentials"] as? [[String: Any]])?.compactMap { $0["id"] as? String } == ["BQY"])
        #expect(body["userVerification"] as? String == "required")
        #expect(((body["prf"] as? [String: Any])?["eval"] as? [String: Any])?["first"] as? String == "c2FsdA")
        // A test run signs as the passkey picked, so a page can tell.
        let reply = Passkeys.rehearsal("get", rp: "example.com", origin: "https://example.com", challenge: Data([1]), id: Data([5, 6]))
        #expect(reply["id"] as? String == Passkeys.text(Data([5, 6])))
        let json = try #require(ChromiumWebAuthn.response(kind: "get", reply: reply, options: options))
        #expect(json.contains(#""id":"BQY""#))
    }

    // Chromium serializes origins without default ports; the box's page
    // has an address.
    @Test func aConditionalGetBelongsToItsOrigin() {
        #expect(ChromiumWebAuthn.sameOrigin("https://example.com", URL(string: "https://example.com/login?x=1")))
        #expect(ChromiumWebAuthn.sameOrigin("https://example.com", URL(string: "https://EXAMPLE.com:443/")))
        #expect(ChromiumWebAuthn.sameOrigin("http://localhost:8080", URL(string: "http://localhost:8080/")))
        #expect(!ChromiumWebAuthn.sameOrigin("http://localhost:8080", URL(string: "http://localhost:8081/")))
        #expect(!ChromiumWebAuthn.sameOrigin("https://example.com", URL(string: "https://login.example.com/")))
        #expect(!ChromiumWebAuthn.sameOrigin("https://example.com", URL(string: "http://example.com/")))
        #expect(!ChromiumWebAuthn.sameOrigin("https://example.com", nil))
    }

    // The site's passkeys are rows of the same list as its logins: first,
    // as Chromium lists them, "Passkey · Apple Passwords" under the name.
    @Test func passkeysAreRowsOfTheLoginList() {
        let key = ConditionalPasskey(request: "7", id: "AQI", user: "ann@example.com", provider: "Apple Passwords")
        let other = ConditionalPasskey(request: "7", id: "AwQ", user: "", provider: "1Password")
        let login = Login(host: "example.com", user: "ann@example.com", password: "pw", used: nil)

        // Alone: the one row, ↩.
        let alone = SuggestRows.build(.init(host: "example.com", passkeys: [key]))
        #expect(alone.map(\.id) == ["pk/7/AQI"])
        #expect(alone.first?.quick == true)
        #expect(alone.first?.detail == "Passkey · Apple Passwords")
        #expect(alone.first?.pickable == true)

        // Beside a password of the same name: both, the passkey first.
        let both = SuggestRows.build(.init(yab: [login], host: "example.com", passkeys: [key, other]))
        #expect(both.map(\.title) == ["ann@example.com", "No name", "ann@example.com", "All Passwords"])
        #expect(both.prefix(2).allSatisfy { if case .passkey = $0.kind { return true }; return false })
        #expect(both[1].detail == "Passkey · 1Password")
        #expect(both[0].group != both[2].group)

        // No login and an email box: passkeys, not addresses.
        let mail = SuggestRows.build(.init(host: "example.com", emails: ["ann@example.com"], passkeys: [key, other]))
        #expect(mail.count == 2 && mail.allSatisfy { if case .passkey = $0.kind { return true }; return false })

        // Password filling off: the passkeys alone, no manager.
        let only = SuggestRows.build(.init(yab: [login], managers: [.init(provider: "bitwarden")], host: "example.com",
                                           passkeys: [key], passkeysOnly: true))
        #expect(only.map(\.id) == ["pk/7/AQI"])

        // The password step of a named account is its password alone.
        let step = SuggestRows.build(.init(yab: [login], host: "example.com", secret: true, named: "ann@example.com", passkeys: [key]))
        #expect(step.map(\.title) == ["Password for ann@example.com"])

        // No request, no passkey rows.
        #expect(SuggestRows.build(.init(yab: [login], host: "example.com")).allSatisfy {
            if case .passkey = $0.kind { return false }; return true
        })
    }

    // Chrome's footer under a pending conditional get, "Use Passkey from
    // another device": after the rows, before All Passwords; alone where
    // nothing is kept; never without a request.
    @Test func anotherDevicesPasskeyIsTheFooter() throws {
        let key = ConditionalPasskey(request: "7", id: "AQI", user: "ann@example.com", provider: "Apple Passwords")
        let login = Login(host: "example.com", user: "bob@example.com", password: "pw", used: nil)

        let both = SuggestRows.build(.init(yab: [login], host: "example.com", passkeys: [key], otherPasskey: "7"))
        #expect(both.map(\.id) == ["pk/7/AQI", "yab/" + login.id, "pkother/7", "all"])
        let footer = try #require(both.first { $0.id == "pkother/7" })
        #expect(footer.title == "Use Passkey from another device")
        #expect(footer.footer && footer.pickable)
        #expect(both.filter(\.footer).map(\.id) == ["pkother/7", "all"])

        // No passkey and no login: the footer alone, as Chromium's list shows
        // it; "No logins for this site" says nothing more.
        let none = SuggestRows.build(.init(managers: [.init(provider: "bitwarden")], host: "example.com", otherPasskey: "7"))
        #expect(none.map(\.id) == ["pkother/7"])
        let off = SuggestRows.build(.init(host: "example.com", passkeysOnly: true, otherPasskey: "7"))
        #expect(off.map(\.id) == ["pkother/7"])

        #expect(!SuggestRows.build(.init(yab: [login], host: "example.com", passkeys: [key])).contains { $0.footer && $0.kind != .all })
    }

    // The footer's sheet is the modal one for the same request: no passkey
    // picked, a phone and a security key offered beside the Mac's.
    @Test func anotherDevicesSheetIsTheModalRequest() throws {
        let options: [String: Any] = ["challenge": "AAEC", "rpId": "example.com", "allowCredentials": [], "userVerification": "preferred"]
        let body = try #require(ChromiumWebAuthn.otherDeviceBody(options, token: "chromium-7"))
        #expect(body["platformOnly"] == nil)
        #expect(body["rpId"] as? String == "example.com")
        #expect((body["allowCredentials"] as? [[String: Any]])?.isEmpty == true)
        #expect(body["token"] as? String == "chromium-7")
    }

    // X's passkeys are twitter.com's and sign-in is on x.com: twitter.com's
    // /.well-known/webauthn lists both (fetched 2026-11-05).
    @Test func relatedOriginsLetXAskForTwitterPasskeys() {
        let x = ["https://twitter.com", "https://x.com"]
        #expect(RelatedOrigins.permits(x, caller: "https://x.com"))
        #expect(RelatedOrigins.permits(x, caller: "https://x.com:443"))
        #expect(!RelatedOrigins.permits(x, caller: "https://evil.com"))
        #expect(!RelatedOrigins.permits(x, caller: "http://x.com"))
        #expect(!RelatedOrigins.permits(x, caller: "https://mobile.x.com"))
        #expect(RelatedOrigins.origins(in: Data(#"{"origins":["https://twitter.com","https://x.com",3]}"#.utf8)) == x)
        #expect(RelatedOrigins.origins(in: Data("<html>".utf8)) == nil)
        #expect(RelatedOrigins.valid("twitter.com"))
        #expect(!RelatedOrigins.valid("com"))
        #expect(!RelatedOrigins.valid("127.0.0.1"))
    }

    @Test func relatedOriginsCountFiveLabelsAtMost() {
        let five = ["https://a.com", "https://b.com", "https://c.com", "https://d.com", "https://e.com"]
        // A sixth label is past the limit; another origin of a counted one is not.
        #expect(!RelatedOrigins.permits(five + ["https://f.com"], caller: "https://f.com"))
        #expect(RelatedOrigins.permits(five + ["https://a.co.uk"], caller: "https://a.co.uk"))
        #expect(RelatedOrigins.permits(five, caller: "https://e.com"))
        #expect(RelatedOrigins.label("mobile.twitter.com") == "twitter")
        #expect(RelatedOrigins.label("bbc.co.uk") == "bbc")
        #expect(RelatedOrigins.label("10.0.0.1") == nil)
    }
}
