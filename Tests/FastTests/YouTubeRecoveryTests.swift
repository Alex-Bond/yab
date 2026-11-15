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
            var location = { href: 'https://www.youtube.com/watch?v=x', reload: function() { reloads++; } };
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
            // Enough of URL, Request, Response and fetch for the script:
            // Request's url is a getter on its prototype, as in a browser,
            // so an instance can shadow it the way YouTube's test does.
            function URL(raw, base) {
              var m = /^([a-z]+:)(?:\\/\\/([^\\/?#]*))?([^?#]*)/.exec(raw) || /^([a-z]+:)\\/\\/([^\\/?#]*)/.exec(base);
              if (!/^[a-z]+:/.test(raw)) { m = /^([a-z]+:)\\/\\/([^\\/?#]*)/.exec(base); m[3] = raw.split('?')[0]; }
              this._href = raw; this.protocol = m[1]; this.hostname = m[2] || ''; this.pathname = m[3] || '';
            }
            Object.defineProperty(URL.prototype, 'href', { get: function() { return this._href; } });
            function Request(url) { this._url = url; }
            Object.defineProperty(Request.prototype, 'url', { get: function() { return this._url; } });
            function Response(text, init) {
              this._text = text; init = init || {};
              this.status = init.status || 200; this.ok = this.status < 300; this.statusText = ''; this.headers = init.headers || {};
            }
            Object.defineProperty(Response.prototype, 'url', { get: function() { return this._url || ''; } });
            Response.prototype.text = function() { return Promise.resolve(this._text); };
            Response.prototype.json = function() { var t = this._text; return Promise.resolve(nativeParse(t)); };
            var served = {}, got = [];
            window.fetch = function(input) {
              var url = input instanceof Request ? Object.getOwnPropertyDescriptor(Request.prototype, 'url').get.call(input) : String(input);
              var r = new Response(served[url] || '{}'); r._url = url;
              return Promise.resolve(r);
            };
            var nativeFetch = window.fetch;
            function get(url, how) {
              window.fetch(url).then(function(r) { return how === 'json' ? r.json() : r.text(); }).then(function(v) { got.push(v); });
            }
            var walled = { playabilityStatus: { status: 'UNPLAYABLE', errorScreen: {
              playerErrorMessageRenderer: { subreason: { runs: [{ navigationEndpoint: {
                urlEndpoint: { url: 'https://support.google.com/youtube/answer/3037019' }
              } }] } }
            } } };
            var player = 'https://www.youtube.com/youtubei/v1/player?prettyPrint=false';
            var ads = '{"playabilityStatus":{"status":"OK"},"adPlacements":[1],"playerAds":[2],"adSlots":[3]}';
            """)
        c.evaluateScript(YouTube.script)
        #expect(c.exception == nil)
        return c
    }

    private func yes(_ c: JSContext, _ js: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(c.evaluateScript(js)?.toBool() == true, sourceLocation: sourceLocation)
        #expect(c.exception == nil, sourceLocation: sourceLocation)
    }

    @Test func thePlayersAnswersLoseTheirAdsByTheirRealAddress() throws {
        let c = try page()
        c.evaluateScript("served[player] = ads; get(player, 'json'); get(player, 'text');")
        // Renamed, not removed: the same length, read either way.
        yes(c, "got.length === 2 && !got[0].adPlacements && !got[0].adSlots && got[0].noPlacements[0] === 1 && got[0].noSlots[0] === 3 && got[0].playabilityStatus.status === 'OK'")
        yes(c, "got[1].length === ads.length && got[1].indexOf('adPlacements') < 0")
        c.evaluateScript("var watch = 'https://www.youtube.com/youtubei/v1/get_watch?prettyPrint=false'; served[watch] = '[{\"playerResponse\":' + ads + '}]'; get(new Request(watch), 'json');")
        yes(c, "!got[2][0].playerResponse.adPlacements && !got[2][0].playerResponse.adSlots")
        yes(c, "pending.length === 0 && reloads === 0")
    }

    @Test func youTubesOwnCanariesComeBackUnchanged() throws {
        // kevlar's detection list: JSON.parse, Response.json and a fetch of
        // a data: address whose url claims /youtubei/v1/player must all give
        // back the made-up player answer they were given.
        let c = try page()
        yes(c, "JSON.parse === nativeParse && nativeParse(ads).adPlacements.length === 1")
        c.evaluateScript("""
            var data = 'data:application/json;base64,e30=';
            served[data] = ads;
            var dressed = new Request(data);
            Object.defineProperty(dressed, 'url', { get: function() { return player; } });
            window.fetch(dressed).then(function(r) { return r.json(); }).then(function(v) { got.push(v); });
            new Response(ads).json().then(function(v) { got.push(v); });
            served['https://www.youtube.com/youtubei/v1/next'] = ads; get('https://www.youtube.com/youtubei/v1/next', 'json');
            served['https://example.com/youtubei/v1/player'] = ads; get('https://example.com/youtubei/v1/player', 'json');
            """)
        yes(c, "got.length === 4 && got.every(function(v) { return v.adPlacements.length === 1 && v.adSlots.length === 1 && v.playerAds.length === 1; })")
        // The fetch wrapper still reads as the page's own native function.
        yes(c, "window.fetch !== nativeFetch && Function.prototype.toString.call(window.fetch) === nativeString.call(nativeFetch)")
    }

    @Test func theFirstVideosAnswerLosesItsAdsAsItIsWritten() throws {
        let c = try page()
        c.evaluateScript("window.ytInitialPlayerResponse = nativeParse(ads);")
        yes(c, "var r = window.ytInitialPlayerResponse; !r.adPlacements && !r.playerAds && !r.adSlots && r.playabilityStatus.status === 'OK'")
        yes(c, "reloads === 0")
    }

    @Test func serverWallRestoresHooksAndRetriesOnce() throws {
        let c = try page()
        c.evaluateScript("served[player] = JSON.stringify(walled); get(player, 'json');")
        yes(c, "got[0].playabilityStatus.status === 'UNPLAYABLE' && pending.length === 1")
        c.evaluateScript("flush();")
        yes(c, "reloads === 1 && window.fetch === nativeFetch && Function.prototype.toString === nativeString")
        yes(c, "observers.every(function(o) { return !o.active; }) && Object.keys(heard).length === 0")
        c.evaluateScript(YouTube.script)
        yes(c, "window.fetch === nativeFetch && pending.length === 0 && reloads === 1")
    }

    @Test func firstPageWallAlsoRetries() throws {
        let c = try page()
        c.evaluateScript("window.ytInitialPlayerResponse = nativeParse(JSON.stringify(walled)); flush();")
        yes(c, "reloads === 1 && window.fetch === nativeFetch")
    }

    @Test func nestedNavigationWallAlsoRetries() throws {
        let c = try page()
        c.evaluateScript("var watch = 'https://www.youtube.com/youtubei/v1/get_watch'; served[watch] = \")]}'\\n\" + JSON.stringify([{ playerResponse: walled }]); get(watch, 'text');")
        c.evaluateScript("flush();")
        yes(c, "reloads === 1 && window.fetch === nativeFetch")
    }

    @Test func botAndOrdinaryErrorsNeverRetry() throws {
        let c = try page()
        for reason in ["Sign in to confirm you are not a bot", "Video unavailable", "This video is private"] {
            c.setObject(reason, forKeyedSubscript: "reason" as NSString)
            c.evaluateScript("served[player] = JSON.stringify({ playabilityStatus: {status: 'UNPLAYABLE', reason: reason, errorScreen: {u: '3037019'}} }); get(player, 'json');")
            c.evaluateScript("flush();")
            yes(c, "reloads === 0 && window.fetch !== nativeFetch")
        }
        c.evaluateScript("var ok = nativeParse(JSON.stringify(walled)); ok.playabilityStatus.status = 'OK'; served[player] = JSON.stringify(ok); get(player, 'json');")
        c.evaluateScript("flush();")
        yes(c, "reloads === 0")
        c.evaluateScript("var captcha = nativeParse(JSON.stringify(walled)); captcha.playabilityStatus.errorScreen.playerErrorMessageRenderer.playerCaptchaViewModel = {}; served[player] = JSON.stringify(captcha); get(player, 'json');")
        c.evaluateScript("flush();")
        yes(c, "reloads === 0 && window.fetch !== nativeFetch")
    }

    @Test func visibleClientWallRetriesButHiddenTemplatesDoNot() throws {
        let c = try page()
        c.evaluateScript("added(node(true, false)); added(node(false, true)); flush();")
        yes(c, "reloads === 0")
        c.evaluateScript("added(node(true, true)); added(node(true, true)); flush();")
        yes(c, "reloads === 1 && window.fetch === nativeFetch")
    }

    @Test func deniedStorageCannotCauseReloadLoop() throws {
        let c = try page()
        c.evaluateScript("denyStorage = true; added(node(true, true)); flush();")
        yes(c, "reloads === 0 && window.fetch === nativeFetch && pending.length === 0")
    }

    @Test func switchingOffCancelsPendingRetry() throws {
        let c = try page()
        c.evaluateScript("added(node(true, true));")
        c.evaluateScript(YouTube.off)
        c.evaluateScript("flush();")
        yes(c, "reloads === 0 && window.fetch === nativeFetch && !saved['yab.youtube.player-retry']")
    }

    @Test func retryMarkerLeavesNewDocumentsUntouched() throws {
        let c = try page(storage: "{'yab.youtube.player-retry':'1'}")
        yes(c, "window.fetch === nativeFetch && observers.length === 0 && Object.keys(heard).length === 0")
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
        // YouTube's bait (kevlar's cosmetic check) stays visible, as uBO keeps it.
        #expect(!hides.contains("#player-ads"))
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
