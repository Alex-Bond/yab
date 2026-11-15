import Foundation
import JavaScriptCore
import Testing
@testable import Fast

/// While passkeys wait on Apple, pages find no PublicKeyCredential
/// (forms-without-passkeys.js). NordPass's passkeys.js, in the page's own
/// world, patched it as it started and threw on undefined (release QA
/// 0.0.20). An extension's script gets a stand-in that says no passkeys;
/// a page's own script still finds nothing. WebKit gives an extension's
/// scripts a masked address in a stack, as the source URL here.
@MainActor
struct PasskeyStandInTests {
    private func context() throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript(#"""
        var window = globalThis;
        globalThis.PublicKeyCredential = function PublicKeyCredential() { throw new TypeError('Illegal constructor'); };
        PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable = () => Promise.resolve(true);
        PublicKeyCredential.parseRequestOptionsFromJSON = function (o) { return this === realOne ? 'real' : 'wrong'; };
        var realOne = PublicKeyCredential;
        function CredentialsContainer() {}
        CredentialsContainer.prototype.get = () => Promise.resolve('native');
        CredentialsContainer.prototype.create = () => Promise.resolve('native');
        var navigator = { credentials: new CredentialsContainer() };
        function setTimeout(f) {}
        function CustomEvent() {}
        window.dispatchEvent = () => true;
        """#)
        context.evaluateScript(FormRelay.withoutPasskeys)
        try #require(context.exception == nil)
        return context
    }

    @Test func aPageFindsNothing() throws {
        let c = try context()
        #expect(c.evaluateScript("typeof PublicKeyCredential")?.toString() == "undefined")
    }

    @Test func anExtensionsScriptGetsAStandInThatSaysNo() throws {
        let c = try context()
        c.evaluateScript(#"""
        var kind = typeof PublicKeyCredential, results = {};
        PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable().then(v => results.platform = v);
        PublicKeyCredential.isConditionalMediationAvailable().then(v => results.conditional = v);
        var parsed = PublicKeyCredential.parseRequestOptionsFromJSON({});
        // What NordPass does to it as it starts.
        PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable = () => Promise.resolve(true);
        var same = PublicKeyCredential === PublicKeyCredential;
        var notReal = PublicKeyCredential !== realOne;
        var constructs; try { new PublicKeyCredential(); constructs = true; } catch (e) { constructs = false; }
        """#, withSourceURL: URL(string: "webkit-masked-url://hidden/"))
        c.evaluateScript("0")
        #expect(c.exception == nil)
        #expect(c.evaluateScript("kind")?.toString() == "function")
        #expect(c.evaluateScript("JSON.stringify(results)")?.toString() == #"{"platform":false,"conditional":false}"#)
        #expect(c.evaluateScript("parsed")?.toString() == "real")
        #expect(c.evaluateScript("same && notReal && !constructs")?.toBool() == true)
        // The page still finds nothing, and WebKit's own object is untouched.
        #expect(c.evaluateScript("typeof PublicKeyCredential")?.toString() == "undefined")
        c.evaluateScript("realOne.isUserVerifyingPlatformAuthenticatorAvailable().then(v => results.real = v)")
        c.evaluateScript("0")
        #expect(c.evaluateScript("results.real")?.toBool() == true)
    }

    /// 1Password eagerly collects the capability parent before installing
    /// its credentials hooks. Once claimed, pages must see those hooks,
    /// rather than the original browser capabilities.
    @Test func claimedProviderKeepsItsEagerCapabilityHooks() throws {
        let c = try context()
        c.evaluateScript("realOne.isUserVerifyingPlatformAuthenticatorAvailable = () => Promise.resolve(false)")
        c.evaluateScript(#"""
        var providerGet = function providerGet() { throw new Error('fixture must not request a credential'); };
        var hooks = [
          { parent: navigator.credentials, name: 'get', method: providerGet },
          { parent: PublicKeyCredential, name: 'isUserVerifyingPlatformAuthenticatorAvailable', method: () => Promise.resolve(true) },
          { parent: PublicKeyCredential, name: 'isConditionalMediationAvailable', method: () => Promise.resolve(true) },
          { parent: PublicKeyCredential, name: 'getClientCapabilities', method: () => Promise.resolve({conditionalGet: true}) }
        ];
        hooks.forEach(hook => Object.defineProperty(hook.parent, hook.name, {
          configurable: false, get: () => hook.method
        }));
        """#, withSourceURL: URL(string: "webkit-masked-url://provider/"))
        c.evaluateScript(#"""
        var results = {};
        PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable().then(v => results.platform = v);
        PublicKeyCredential.isConditionalMediationAvailable().then(v => results.conditional = v);
        PublicKeyCredential.getClientCapabilities().then(v => results.capabilities = v.conditionalGet);
        """#)
        c.evaluateScript("0")
        #expect(c.exception == nil)
        #expect(c.evaluateScript("navigator.credentials.get === providerGet")?.toBool() == true)
        #expect(c.evaluateScript("JSON.stringify(results)")?.toString() == #"{"platform":true,"conditional":true,"capabilities":true}"#)
    }

    @Test func capabilityHooksAloneDoNotExposePasskeys() throws {
        let c = try context()
        c.evaluateScript(#"""
        PublicKeyCredential.isConditionalMediationAvailable = () => Promise.resolve(true);
        """#, withSourceURL: URL(string: "webkit-masked-url://provider/"))
        #expect(c.exception == nil)
        #expect(c.evaluateScript("typeof PublicKeyCredential")?.toString() == "undefined")
        #expect(c.evaluateScript("Object.hasOwn(navigator.credentials, 'get')")?.toBool() == false)
    }


    @Test func claimingCredentialsDoesNotCopyStandInDefaults() throws {
        let c = try context()
        c.evaluateScript("var waiting = PublicKeyCredential", withSourceURL: URL(string: "webkit-masked-url://provider/"))
        c.evaluateScript(#"""
        Object.defineProperty(navigator.credentials, 'get', { value: function providerGet() {
          throw new Error('fixture must not request a credential');
        } });
        var nativeAvailable;
        PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable().then(v => nativeAvailable = v);
        """#)
        c.evaluateScript("0")
        #expect(c.exception == nil)
        #expect(c.evaluateScript("nativeAvailable")?.toBool() == true)
    }

}
