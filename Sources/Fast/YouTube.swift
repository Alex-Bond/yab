import WebKit

// YouTube's own advertisements, which no filter list reaches: they come
// from youtube.com and googlevideo.com, the same places the video does,
// and the player is told when to play one in the same answer that tells it
// what the video is. So that answer is changed on its way in: the ad
// schedule (adPlacements, playerAds, adSlots) is taken out of the data in
// the page, out of JSON.parse and out of Response.json, and the player
// never goes into ad mode. The idea and much of the script are Lean's
// (PageScripts.swift), MIT, see THIRD_PARTY_NOTICES.md.
//
// It runs in the page's own world, at the start of the document, on
// youtube.com only: yab's world (Web.world) sees the page's DOM but not
// its fetch or its JSON, which are what the player reads. A YouTube player
// embedded in another site's page is not covered: it is a frame, and the
// script is for the main frame of youtube.com.
//
// The page can see what is done in its world, so as little as possible is
// left for it to find: JSON.parse and Response.json are the page's own
// functions behind a Proxy, which still say they are native code; what the
// script keeps is in its own closure; nothing is written on the page's
// elements or under a global name. Switching off reaches it by an event
// whose name is made fresh at each launch.
//
// If an ad plays all the same, it is muted and run at 16x, skipped when the
// skip button can really be pressed (on a live stream, where an ad can be
// part of the stream, only muted), and afterwards the sound, the speed
// and the play state are put back, a pause of yours left alone. That part
// waits on the player's class and on the video's own events; nothing ticks
// on a YouTube page while no ad is showing.

enum YouTube {
    // Keep the player's requests and skip controls usable when an ad gets
    // through. These exceptions apply only on YouTube, not on other sites.
    static let filters = """
    @@||youtube.com/api/stats/ads$domain=youtube.com
    @@||youtube.com/pagead/$domain=youtube.com
    @@||youtube.com/ptracking$domain=youtube.com
    @@||youtube.com/youtubei/v1/player$domain=youtube.com
    @@||youtube.com/get_video_info$domain=youtube.com
    @@||googlevideo.com^$domain=youtube.com
    @@||googleads.g.doubleclick.net^$domain=youtube.com
    @@||static.doubleclick.net^$domain=youtube.com
    @@||googlesyndication.com^$domain=youtube.com
    youtube.com#@#.ytp-ad-module
    youtube.com#@#.ytp-ad-player-overlay
    youtube.com#@#.ytp-ad-text
    youtube.com#@#.ytp-ad-message-container
    youtube.com#@#.ytp-ad-image-overlay
    youtube.com#@#.ytp-ad-overlay-container
    """

    static func runs(on host: String?) -> Bool {
        guard let host else { return false }
        return host == "youtube.com" || host.hasSuffix(".youtube.com")
    }

    /// The event the script answers to, new at each launch so no page can
    /// know it in advance.
    private static let name = UUID().uuidString

    static let user = WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)

    /// For a page already open when the blocker is switched off: everything
    /// put back as it was, JSON.parse and Response.json included.
    static let off = "(function(){try{EventTarget.prototype.dispatchEvent.call(window,new CustomEvent('\(name)',{detail:{off:true}}))}catch(e){}})();"

    static let script = #"""
    (function() {
        // A confirmed blocker wall gets one retry with the player left
        // alone for this tab's session. Never retry a bot or sign-in gate.
        var retryKey = 'yab.youtube.player-retry';
        try { if (sessionStorage.getItem(retryKey) === '1') return; } catch (e) {}
        var name = '\#(name)';
        var call = Reflect.apply, then = Promise.prototype.then, dispatch = EventTarget.prototype.dispatchEvent;
        // Already here, from the start of the document: it says so.
        var asked = { here: false };
        try { call(dispatch, window, [new CustomEvent(name, { detail: asked })]); } catch (e) {}
        if (asked.here) return;

        var keys = ['adPlacements', 'playerAds', 'adSlots'];
        var on = true;
        var undo = [];
        var yielding = false;

        function stop() {
            on = false;
            window.removeEventListener(name, answer);
            for (var i = undo.length - 1; i >= 0; i--) { try { undo[i](); } catch (e) {} }
        }
        function stepBack() {
            if (!on || yielding) return;
            yielding = true;
            setTimeout(function() {
                if (!on) return;
                stop();
                // If storage is unavailable, do not risk a reload loop.
                try {
                    sessionStorage.setItem(retryKey, '1');
                    if (sessionStorage.getItem(retryKey) === '1') location.reload();
                } catch (e) {}
            }, 0);
        }
        function wall(o) {
            var ps = o && o.playabilityStatus;
            if (!ps || ps.status !== 'UNPLAYABLE') return false;
            var screen = JSON.stringify(ps.errorScreen || {});
            return !/playerCaptchaViewModel|not a bot|sign in to confirm/i.test(screen + ' ' + (ps.reason || '')) &&
                /support\.google\.com\/youtube\/answer\/3037019(?:[?#"'\/]|$)/.test(screen);
        }

        function shallow(o) {
            for (var i = 0; i < keys.length; i++) {
                try { if (Object.prototype.hasOwnProperty.call(o, keys[i])) delete o[keys[i]]; } catch (e) {}
            }
        }
        // Only an answer shaped like the player's is walked, with a budget,
        // so the rest of YouTube's JSON costs a property check. Moving
        // from one video to the next, get_watch answers with a list whose
        // parts carry the player's answer.
        function playerish(o) {
            try { return !!(o && typeof o === 'object' && (o.playabilityStatus || o.streamingData || o.playerResponse || (o.responseContext && o.contents))); } catch (e) { return false; }
        }
        function strip(o) {
            if (!on || !o || typeof o !== 'object') return;
            if (wall(o)) { stepBack(); return; }
            shallow(o);
            if (!(playerish(o) || (Array.isArray(o) && o.some(playerish)))) return;
            var stack = [o], seen = new WeakSet(), budget = 20000;
            while (stack.length && budget-- > 0) {
                var n = stack.pop();
                if (!n || typeof n !== 'object' || seen.has(n)) continue;
                seen.add(n);
                if (wall(n)) { stepBack(); return; }
                shallow(n);
                if (Array.isArray(n)) { for (var a = 0; a < n.length; a++) stack.push(n[a]); }
                else { for (var k in n) { try { stack.push(n[k]); } catch (e) {} } }
            }
        }

        // The first video's data is written into the page itself, so the
        // two globals it lands in are caught as they are assigned.
        ['ytInitialPlayerResponse', 'ytInitialData'].forEach(function(key) {
            try {
                var value = window[key];
                strip(value);
                Object.defineProperty(window, key, {
                    configurable: true,
                    get: function() { return value; },
                    set: function(v) { strip(v); value = v; }
                });
                undo.push(function() {
                    Object.defineProperty(window, key, { value: value, writable: true, configurable: true, enumerable: true });
                });
            } catch (e) {}
        });

        // The page's own function behind a Proxy: called the same, and read
        // the same. WebKit prints a Proxy as "function ProxyObject()", so
        // toString is given the function behind it, and says the same of
        // itself.
        var masks = new WeakMap();
        function wrap(owner, key, trap) {
            var native = owner && owner[key];
            if (typeof native !== 'function') return;
            var proxy = new Proxy(native, { apply: trap(native) });
            masks.set(proxy, native);
            owner[key] = proxy;
            undo.push(function() { if (owner[key] === proxy) owner[key] = native; });
        }
        wrap(Function.prototype, 'toString', function(native) {
            return function(target, self, args) { return call(native, masks.get(self) || self, args); };
        });
        wrap(JSON, 'parse', function(native) {
            return function(target, self, args) {
                var value = call(native, self, args);
                if (on) { try { strip(value); } catch (e) {} }
                return value;
            };
        });
        // fetch(…).then(r => r.json()) parses natively, past JSON.parse.
        wrap(window.Response && Response.prototype, 'json', function(native) {
            return function(target, self, args) {
                var answer = call(native, self, args);
                if (!on) return answer;
                return call(then, answer, [function(value) { try { strip(value); } catch (e) {} return value; }]);
            };
        });

        // If one plays anyway. What was changed on a video is kept here,
        // not on the element.
        var player = null, watcher = null, timer = 0, ended = 0, yours = false, inAd = false, touched = 0;
        var retiredAd = false, adVideos = [];
        var kept = new WeakMap(), stopped = new WeakMap();
        function showing() { return !!(player && player.classList.contains('ad-showing')); }
        function videos() { return player ? player.querySelectorAll('video') : []; }
        // A live stream: the player says so in its class and its data, and
        // a stream with no end at all is one wherever it plays.
        function live(v) {
            try {
                if (player && (player.classList.contains('ytp-live') || player.querySelector('.ytp-live, .ytp-live-badge-is-livehead'))) return true;
                var data = player && typeof player.getVideoData === 'function' ? player.getVideoData() : null;
                if (data && data.isLive) return true;
            } catch (e) {}
            return v.duration === Infinity;
        }
        function skipper() {
            var buttons = document.querySelectorAll('.ytp-skip-ad-button,.ytp-ad-skip-button,.ytp-ad-skip-button-modern');
            for (var i = 0; i < buttons.length; i++) {
                var b = buttons[i];
                // "Skip in 5": there, and not yet pressable.
                if (!b.disabled && b.offsetParent !== null && b.clientWidth > 0) return b;
            }
            return null;
        }
        function restore(v) {
            var was = kept.get(v);
            if (!was) return;
            // The player or the person may already have chosen the content's
            // sound/speed. Only undo values this fallback still owns.
            if (was.forcedMute && v.muted === true) v.muted = was.muted;
            if (was.forcedRate && v.playbackRate === 16) v.playbackRate = was.rate;
            kept.delete(v);
        }
        function restoreAll() {
            for (var i = 0; i < adVideos.length; i++) restore(adVideos[i]);
            adVideos = [];
        }
        function retire() {
            retiredAd = true;
            restoreAll();
        }
        function tame() {
            var ad = showing();
            var list = videos();
            // A stale ad class must not enroll a replacement video on the
            // next timer beat, or through a reentrant playing event.
            if (ad && retiredAd) return;
            if (ad && adVideos.length && (adVideos.some(function(v) {
                var was = kept.get(v);
                return Array.prototype.indexOf.call(list, v) < 0 || !was || v.currentSrc !== was.src;
            }) || Array.prototype.some.call(list, function(v) { return adVideos.indexOf(v) < 0; }))) {
                retire();
                return;
            }
            for (var i = 0; i < list.length; i++) {
                var v = list[i];
                try {
                    if (ad) {
                        var was = kept.get(v);
                        if (was && v.currentSrc !== was.src) { retire(); return; }
                        if (!was) {
                            was = { muted: v.muted, rate: v.playbackRate || 1, src: v.currentSrc, forcedMute: false, forcedRate: false };
                            kept.set(v, was);
                            adVideos.push(v);
                        }
                        v.muted = true;
                        was.forcedMute = true;
                        var skip = skipper();
                        if (skip) skip.click();
                        if (retiredAd || !showing() || v.currentSrc !== was.src || Array.prototype.indexOf.call(videos(), v) < 0) {
                            retire();
                            return;
                        }
                        // On a live stream an ad can be stitched into the
                        // stream itself: run fast, or sent to its end, it
                        // would take the stream on with it, as much as an
                        // hour past the edge. Only quiet there.
                        if (!live(v)) {
                            v.playbackRate = 16;
                            was.forcedRate = true;
                            // To its end, as well as the button: a skip that
                            // doesn't take still ends the ad. Only the ad it
                            // started on: once the source changes, the class
                            // can lag behind a video that is yours.
                            if (v.currentSrc === was.src && isFinite(v.duration) && v.duration > 0 && v.duration < 180 && v.currentTime < v.duration - 0.5) {
                                v.currentTime = v.duration - 0.2;
                            }
                        }
                        if (v.paused) { var p = v.play(); if (p && p.catch) p.catch(function() {}); }
                    } else {
                        restore(v);
                        // Just after an ad the player can sit paused at 0:00;
                        // a pause of yours is left alone. Played again only
                        // once it has sat a beat: the player marks a click
                        // on its button in its class before the video's
                        // pause event says whose it was.
                        if (!yours && v.paused && !v.ended && v.readyState >= 2 && Date.now() - ended < 5000) {
                            var since = stopped.get(v);
                            if (!since) stopped.set(v, Date.now());
                            else if (Date.now() - since >= 200) {
                                stopped.delete(v);
                                var q = v.play(); if (q && q.catch) q.catch(function() {});
                            }
                        } else {
                            stopped.delete(v);
                        }
                    }
                } catch (e) {}
            }
        }
        function check() {
            if (!on) return;
            if (showing()) {
                if (!inAd) retiredAd = false;
                inAd = true;
                if (!timer) timer = setInterval(tame, 250);
                tame();
            } else if (inAd) {
                // Once, as the ad ends: the player's class changes again
                // and again after it, a pause of yours among them.
                inAd = false;
                ended = Date.now();
                yours = false;
                stopped = new WeakMap();
                restoreAll();
                retiredAd = false;
                tame();
                // A few more beats to see the video going again, then quiet.
                clearInterval(timer);
                timer = setInterval(function() {
                    tame();
                    if (Date.now() - ended > 5000 && !showing()) { clearInterval(timer); timer = 0; }
                }, 250);
            }
        }
        function find() {
            var p = document.getElementById('movie_player');
            if (!p || p === player) return;
            player = p;
            if (watcher) watcher.disconnect();
            watcher = new MutationObserver(check);
            watcher.observe(p, { attributes: true, attributeFilter: ['class'] });
            check();
        }
        function played(e) { if (!(e.target instanceof HTMLVideoElement)) return; find(); if (e.type === 'playing') yours = false; check(); }
        // A pause is yours when a key or the pointer went down just before
        // it; one the player makes by itself, at 0:00 after an ad, is not.
        function touch(e) { if (e.isTrusted) touched = Date.now(); }
        function paused(e) { if (e.target instanceof HTMLVideoElement && !showing() && Date.now() - touched < 1000) yours = true; }
        window.addEventListener('keydown', touch, true);
        window.addEventListener('pointerdown', touch, true);
        document.addEventListener('play', played, true);
        document.addEventListener('playing', played, true);
        document.addEventListener('pause', paused, true);
        document.addEventListener('yt-navigate-finish', find);
        undo.push(function() {
            window.removeEventListener('keydown', touch, true);
            window.removeEventListener('pointerdown', touch, true);
            document.removeEventListener('play', played, true);
            document.removeEventListener('playing', played, true);
            document.removeEventListener('pause', paused, true);
            document.removeEventListener('yt-navigate-finish', find);
            if (watcher) watcher.disconnect();
            if (timer) clearInterval(timer);
            restoreAll();
            var list = videos();
            for (var i = 0; i < list.length; i++) restore(list[i]);
        });

        function answer(e) {
            var d = e.detail;
            if (!d) return;
            if (!d.off) { d.here = true; return; }
            stop();
        }
        window.addEventListener(name, answer);

        // A client-side wall can arrive after a playable server answer.
        // Only inspect added wall nodes, not every mutation on the page.
        var wallSelector = 'ytd-enforcement-message-view-model, yt-playability-error-supported-renderers';
        function inspectWall(node) {
            if (!on || !node || node.nodeType !== 1) return;
            var candidates = [];
            if (node.matches(wallSelector)) candidates.push(node);
            var nested = node.querySelectorAll(wallSelector);
            for (var i = 0; i < nested.length; i++) candidates.push(nested[i]);
            for (var j = 0; j < candidates.length; j++) {
                var e = candidates[j];
                if (!e.getClientRects().length || getComputedStyle(e).visibility === 'hidden') continue;
                if (/not a bot|sign in to confirm/i.test(e.textContent || '')) continue;
                if (e.matches('ytd-enforcement-message-view-model') || e.querySelector('a[href*="support.google.com/youtube/answer/3037019"]')) {
                    stepBack(); return;
                }
            }
        }
        var walls = new MutationObserver(function(records) {
            for (var i = 0; i < records.length; i++) {
                for (var j = 0; j < records[i].addedNodes.length; j++) inspectWall(records[i].addedNodes[j]);
            }
        });
        walls.observe(document, { childList: true, subtree: true });
        inspectWall(document.documentElement);
        undo.push(function() { walls.disconnect(); });
    })();
    """#
}
