import Foundation
import JavaScriptCore
import Testing
@testable import Fast

@MainActor
struct YouTubeRecoveryTests {
    private func page(storage: String = "{}") throws -> JSContext {
        let c = try #require(JSContext())
        c.evaluateScript("""
            var window = this, heard = {}, pending = [], observers = [], reloads = 0;
            var nativeParse = JSON.parse, nativeString = Function.prototype.toString;
            var saved = \(storage), denyStorage = false;
            var sessionStorage = {
              getItem: function(k) { if (denyStorage) throw Error('denied'); return saved[k] || null; },
              setItem: function(k,v) { if (denyStorage) throw Error('denied'); saved[k] = v; }
            };
            var location = { reload: function() { reloads++; } };
            function setTimeout(f) { pending.push(f); return pending.length; }
            function flush() { var tasks = pending; pending = []; tasks.forEach(function(f) { f(); }); }
            function setInterval() { return 1; }
            function clearInterval() {}
            function CustomEvent(type, init) { this.type = type; this.detail = init.detail; }
            function EventTarget() {}
            EventTarget.prototype.dispatchEvent = function(e) { if (heard[e.type]) heard[e.type](e); };
            window.addEventListener = function(n, f) { heard[n] = f; };
            window.removeEventListener = function(n) { delete heard[n]; };
            function HTMLVideoElement() {}
            function MutationObserver(f) { this.callback = f; observers.push(this); }
            MutationObserver.prototype.observe = function() { this.active = true; };
            MutationObserver.prototype.disconnect = function() { this.active = false; };
            var document = {
              getElementById: function() { return null; },
              querySelectorAll: function() { return []; },
              addEventListener: function() {}, removeEventListener: function() {}
            };
            function getComputedStyle(e) { return { visibility: e.visible ? 'visible' : 'hidden' }; }
            function node(wall, visible) {
              return { nodeType: 1, visible: visible,
                matches: function() { return wall; }, querySelectorAll: function() { return []; },
                querySelector: function() { return null; },
                getClientRects: function() { return visible ? [{}] : []; } };
            }
            function added(n) {
              observers.filter(function(o) { return o.active; }).forEach(function(o) {
                o.callback([{ addedNodes: [n] }]);
              });
            }
            var blocked = { playabilityStatus: { status: 'UNPLAYABLE', errorScreen: {
              playerErrorMessageRenderer: { subreason: { runs: [{ navigationEndpoint: {
                urlEndpoint: { url: 'https://support.google.com/youtube/answer/3037019' }
              } }] } }
            } } };
            """)
        c.evaluateScript(YouTube.script)
        #expect(c.exception == nil)
        return c
    }

    private func yes(_ c: JSContext, _ js: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(c.evaluateScript(js)?.toBool() == true, sourceLocation: sourceLocation)
        #expect(c.exception == nil, sourceLocation: sourceLocation)
    }

    @Test func playableResponsesStillLoseAds() throws {
        let c = try page()
        yes(c, "var r = JSON.parse('{\"playabilityStatus\":{\"status\":\"OK\"},\"adPlacements\":[1],\"playerAds\":[2],\"adSlots\":[3]}'); !r.adPlacements && !r.playerAds && !r.adSlots && r.playabilityStatus.status === 'OK'")
        yes(c, "pending.length === 0 && reloads === 0")
    }

    @Test func serverWallRestoresHooksAndRetriesOnce() throws {
        let c = try page()
        yes(c, "var r = JSON.parse(JSON.stringify(blocked)); r.playabilityStatus.status === 'UNPLAYABLE' && pending.length === 1")
        c.evaluateScript("JSON.parse(JSON.stringify(blocked)); flush();")
        yes(c, "reloads === 1 && JSON.parse === nativeParse && Function.prototype.toString === nativeString")
        yes(c, "observers.every(function(o) { return !o.active; }) && Object.keys(heard).length === 0")
        c.evaluateScript(YouTube.script)
        yes(c, "JSON.parse('{\"adPlacements\":[1]}').adPlacements.length === 1 && pending.length === 0 && reloads === 1")
    }

    @Test func nestedNavigationWallAlsoRetries() throws {
        let c = try page()
        c.evaluateScript("JSON.parse(JSON.stringify([{ playerResponse: blocked }])); flush();")
        yes(c, "reloads === 1 && JSON.parse === nativeParse")
    }

    @Test func botAndOrdinaryErrorsNeverRetry() throws {
        let c = try page()
        for reason in ["Sign in to confirm you are not a bot", "Video unavailable", "This video is private"] {
            c.setObject(reason, forKeyedSubscript: "reason" as NSString)
            c.evaluateScript("JSON.parse(JSON.stringify({ playabilityStatus: {status: 'UNPLAYABLE', reason: reason} })); flush();")
            yes(c, "reloads === 0 && JSON.parse !== nativeParse")
        }
        c.evaluateScript("var ok = nativeParse(JSON.stringify(blocked)); ok.playabilityStatus.status = 'OK'; JSON.parse(JSON.stringify(ok)); flush();")
        yes(c, "reloads === 0")
        c.evaluateScript("var captcha = nativeParse(JSON.stringify(blocked)); captcha.playabilityStatus.errorScreen.playerErrorMessageRenderer.playerCaptchaViewModel = {}; JSON.parse(JSON.stringify(captcha)); flush();")
        yes(c, "reloads === 0 && JSON.parse !== nativeParse")
    }

    @Test func visibleClientWallRetriesButHiddenTemplatesDoNot() throws {
        let c = try page()
        c.evaluateScript("added(node(true, false)); added(node(false, true)); flush();")
        yes(c, "reloads === 0")
        c.evaluateScript("added(node(true, true)); added(node(true, true)); flush();")
        yes(c, "reloads === 1 && JSON.parse === nativeParse")
    }

    @Test func deniedStorageCannotCauseReloadLoop() throws {
        let c = try page()
        c.evaluateScript("denyStorage = true; added(node(true, true)); flush();")
        yes(c, "reloads === 0 && JSON.parse === nativeParse && pending.length === 0")
    }

    @Test func switchingOffCancelsPendingRetry() throws {
        let c = try page()
        c.evaluateScript("added(node(true, true));")
        c.evaluateScript(YouTube.off)
        c.evaluateScript("flush();")
        yes(c, "reloads === 0 && JSON.parse === nativeParse && !saved['yab.youtube.player-retry']")
    }

    @Test func retryMarkerLeavesNewDocumentsUntouched() throws {
        let c = try page(storage: "{'yab.youtube.player-retry':'1'}")
        yes(c, "JSON.parse === nativeParse && observers.length === 0 && Object.keys(heard).length === 0")
    }

    @Test func playerExceptionsAreScopedAndKeepPageAdHiding() throws {
        let rules = Filters.convert([Shield.base, "||youtube.com/youtubei/v1/player/ad_break"])
        let scoped = Filters.convert([YouTube.filters])
        #expect(!scoped.exceptions.isEmpty)
        #expect(scoped.exceptions.allSatisfy { $0.ifDomain == ["youtube.com"] && !$0.types.isEmpty })
        let hides = rules.blocks.compactMap { r -> String? in
            if case .hide(let selector) = r.action { return selector }
            return nil
        }
        #expect(!hides.contains(".ytp-ad-module"))
        #expect(!hides.contains(".ytp-ad-player-overlay"))
        #expect(hides.contains("ytd-display-ad-renderer"))
        #expect(hides.contains("#masthead-ad"))
        // Every network list must end with the player exceptions, including
        // a split that puts an upstream ad_break block in another list.
        let split = try #require(Filters.lists(rules, perList: 100, cap: 1000))
        #expect(split.lists.count > 1)
        for list in split.lists.prefix(split.lists.count - split.hiding) {
            let json = try #require(JSONSerialization.jsonObject(with: Data(list.utf8)) as? [[String: Any]])
            let tail = json.suffix(rules.exceptions.count)
            #expect(tail.count == rules.exceptions.count)
            #expect(tail.allSatisfy { ($0["action"] as? [String: String])?["type"] == "ignore-previous-rules" })
        }
        #expect(Shield.schema > ShieldLists.schema)
    }
}
