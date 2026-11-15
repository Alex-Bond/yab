import Foundation
import JavaScriptCore
import Testing
@testable import Fast

/// What an extension is told as it is taken up again (ExtensionInstallWord,
/// the shim's runtime.onInstalled), and its own reloads let run only five
/// fast ones in a row (FastReloads): Surfshark, told "update" on every load,
/// reloaded itself for as long as Yab ran and filled every open page with
/// copies of its content scripts (feedback #283).
@Suite struct ExtensionInstallWordTests {
    private func word(loadedBefore: Bool = false, unpacked: Bool = false, broughtIn: Bool = false, launch: Bool = false,
                      told: String? = "5.4.0", now: String = "5.4.0") -> String? {
        ExtensionInstallWord.word(loadedBefore: loadedBefore, unpacked: unpacked, broughtIn: broughtIn,
                                  installedBeforeLaunch: launch, told: told, now: now)
    }

    @Test func aLaterLoadAtTheSameVersionIsToldNothing() {
        // Turned off and on, brought back, or its own runtime.reload().
        #expect(word(loadedBefore: true) == "same")
        // Even one brought in from another browser, after its first load.
        #expect(word(loadedBefore: true, broughtIn: true) == "same")
    }

    @Test func aNewVersionIsAnUpdateFromTheOneBefore() {
        #expect(word(loadedBefore: true, told: "5.3.0", now: "5.4.0") == "update:5.3.0")
    }

    @Test func theRestAreAsBefore() {
        #expect(word() == nil)                                      // a real install
        #expect(word(broughtIn: true) == "reload")                  // installed in Chrome long ago
        #expect(word(launch: true) == "launch")                     // a later launch: nothing
        #expect(word(loadedBefore: true, unpacked: true) == "reload") // a folder's Reload, for an unpacked extension
    }

    @Test func fiveFastReloadsInARowThenNoMore() {
        var reloads = FastReloads()
        let start = Date()
        let allowed = (0..<8).map { reloads.allow(at: start.addingTimeInterval(Double($0) * 0.15)) }
        #expect(allowed == [true, true, true, true, true, false, false, false])
        // Ten quiet seconds, and it may again.
        let later = reloads.allow(at: start.addingTimeInterval(1.05 + 10))
        #expect(later)
    }

    @Test func reloadsFarApartAreNeverStopped() {
        var reloads = FastReloads()
        let start = Date()
        let allowed = (0..<20).map { reloads.allow(at: start.addingTimeInterval(Double($0) * 11)) }
        #expect(allowed.allSatisfy { $0 })
    }

    // MARK: the shim

    private func shim(_ answer: String) throws -> JSContext {
        let script = ExtensionShims.script
        let start = try #require(script.range(of: "  // WebKit says \"install\" again whenever an extension is taken up afresh:"))
        let end = try #require(script.range(of: "  // A worker may add listeners only while it starts", range: start.upperBound..<script.endIndex))
        let context = try #require(JSContext())
        context.evaluateScript("""
        var heard = [], asked = [], reloads = 0;
        function put(o, k, v) { o[k] = v; }
        function Event() { this.l = []; }
        Event.prototype.addListener = function (f) { this.l.push(f); };
        Event.prototype.removeListener = function (f) { this.l = this.l.filter((g) => g !== f); };
        Event.prototype.fire = function (...a) { for (const f of this.l.slice()) f(...a); };
        var answers = { "background.loadedBefore": \(answer), "runtime.mayReload": true };
        function native(api) { asked.push(api); return Promise.resolve(answers[api]); }
        var runtime = { onInstalled: new Event(), getManifest: () => ({ version: "5.4.0" }), reload: function () { reloads++; } };
        var background = true;
        var menuLifetime = { stopped: false };
        function installedMenus(listener, details) { return listener(details); }
        """)
        context.evaluateScript(String(script[start.lowerBound..<end.lowerBound]))
        #expect(context.exception == nil)
        context.evaluateScript("""
        runtime.onInstalled.addListener((d) => heard.push(d.reason + (d.previousVersion ? " " + d.previousVersion : "")));
        runtime.onInstalled.fire({ reason: "install" });
        """)
        return context
    }

    @Test func theShimSaysNothingForTheSameVersionAndTheVersionBeforeForAnUpdate() throws {
        let same = try shim(#""same""#)
        #expect(same.evaluateScript("heard.join()")?.toString() == "")
        let update = try shim(#""update:5.3.0""#)
        #expect(update.evaluateScript("heard.join()")?.toString() == "update 5.3.0")
        let first = try shim("false")
        #expect(first.evaluateScript("heard.join()")?.toString() == "install")
        let brought = try shim(#""reload""#)
        #expect(brought.evaluateScript("heard.join()")?.toString() == "update 5.4.0")
    }

    @Test func theShimAsksBeforeReloading() throws {
        let c = try shim("false")
        c.evaluateScript("runtime.reload(); answers['runtime.mayReload'] = false; runtime.reload();")
        #expect(c.evaluateScript("asked.filter((a) => a === 'runtime.mayReload').length")?.toInt32() == 2)
        #expect(c.evaluateScript("reloads")?.toInt32() == 1)
    }
}
