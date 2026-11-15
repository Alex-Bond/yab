import JavaScriptCore
import Testing
@testable import Fast

struct FloatLandTests {
    /// Home from the floating window, the page is told its window changed
    /// size, once, so a player that laid its video out for the whole page
    /// meanwhile (YouTube, feedback #45) lays it out again for itself. A
    /// page nothing was floated from hears nothing.
    @MainActor @Test func landingSaysResize() throws {
        let context = try page()

        // Nothing out: putting it back says nothing.
        context.evaluateScript("var f = window.__yabFloat; f.off();")
        #expect(context.evaluateScript("heard.length")?.toInt32() == 0)

        context.evaluateScript("var answer; f.on().then(function (a) { answer = a; }, function (e) { answer = 'failed ' + e; });")
        #expect(context.evaluateScript("'yab-floating' in classes")?.toBool() == true)
        context.evaluateScript("f.off();")
        #expect(context.evaluateScript("'yab-floating' in classes")?.toBool() == false)
        #expect(context.evaluateScript("heard.join(',')")?.toString() == "resize")
        context.evaluateScript("f.off();")
        #expect(context.evaluateScript("heard.length")?.toInt32() == 1)
        #expect(context.exception == nil)
    }

    /// What the player wrote on its video and the boxes around it while it
    /// filled the window, the whole page's size on the next video (YouTube,
    /// #45 again on 0.0.8), is undone home, whether the player lays it out
    /// again or not; what it had not touched stays as it is.
    @MainActor @Test func landingPutsTheVideoBackWhereThePlayerHadIt() throws {
        let context = try page()
        context.evaluateScript("""
            var player = element('DIV');
            player.isConnected = true;
            video.parentNode = video.parentElement = player;
            player.style.setProperty('width', '453px');
            video.style.setProperty('width', '927px'); video.style.setProperty('height', '531px');
            video.style.setProperty('top', '0px');
            var f = window.__yabFloat; f.on();
            """)
        #expect(context.evaluateScript("player.hasAttribute('data-yab-around')")?.toBool() == true)
        context.evaluateScript("""
            player.style.setProperty('width', '944px'); player.style.setProperty('height', '531px');
            video.style.setProperty('width', '944px'); video.style.setProperty('height', '764px');
            video.style.setProperty('left', '0px');
            f.off();
            """)
        #expect(context.evaluateScript("video.style.getPropertyValue('width')")?.toString() == "927px")
        #expect(context.evaluateScript("video.style.getPropertyValue('height')")?.toString() == "531px")
        #expect(context.evaluateScript("video.style.getPropertyValue('top')")?.toString() == "0px")
        #expect(context.evaluateScript("'left' in video.style.values")?.toBool() == false)
        // The box around it too, a player that sized itself for the page.
        #expect(context.evaluateScript("player.style.getPropertyValue('width')")?.toString() == "453px")
        #expect(context.evaluateScript("'height' in player.style.values")?.toBool() == false)
        // Out again, with nothing written meanwhile: nothing changes.
        context.evaluateScript("f.on();")
        context.evaluateScript("f.off();")
        #expect(context.evaluateScript("video.style.getPropertyValue('width')")?.toString() == "927px")
        #expect(context.exception == nil)
    }

    /// Home with Yab behind another app's window, the page lands out of
    /// sight. It hears the window change size again once it is seen in its
    /// tab, and only once.
    @MainActor @Test func landingHiddenSaysResizeAgainWhenSeen() throws {
        let context = try page()
        context.evaluateScript("var f = window.__yabFloat; f.on();")
        #expect(context.evaluateScript("'yab-floating' in classes")?.toBool() == true)
        context.evaluateScript("document.visibilityState = 'hidden'; f.off(); flush();")
        #expect(context.evaluateScript("heard.join(',')")?.toString() == "resize")
        context.evaluateScript("show('visible'); flush();")
        #expect(context.evaluateScript("heard.join(',')")?.toString() == "resize,resize")
        context.evaluateScript("show('hidden'); show('visible'); flush();")
        #expect(context.evaluateScript("heard.length")?.toInt32() == 2)
        // Out in the window again before it was seen: nothing more said.
        context.evaluateScript("heard = []; f.on();")
        context.evaluateScript("document.visibilityState = 'hidden'; f.off();")
        context.evaluateScript("f.on();")
        #expect(context.evaluateScript("'yab-floating' in classes")?.toBool() == true)
        context.evaluateScript("show('visible'); flush();")
        #expect(context.evaluateScript("heard.join(',')")?.toString() == "resize")
        #expect(context.exception == nil)
    }

    /// A search for the video still going when the page goes home marks
    /// nothing: the page stays laid out for its tab, not for a window that
    /// has gone (Back to Tab while a lift was still on its way).
    @MainActor @Test func homeBeforeTheSearchEndsMarksNothing() throws {
        let context = try page()
        context.evaluateScript("""
            var f = window.__yabFloat, answer;
            f.on().then(function (a) { answer = a; });
            f.off();
            """)
        #expect(context.evaluateScript("answer")?.toString() == "none")
        #expect(context.evaluateScript("'yab-floating' in classes")?.toBool() == false)
        #expect(context.evaluateScript("video.hasAttribute('data-yab-float')")?.toBool() == false)
        // Asked again after that, it floats as ever.
        context.evaluateScript("f.on().then(function (a) { answer = a; });")
        #expect(context.evaluateScript("answer && answer[0]")?.toString() == "floating")
        #expect(context.exception == nil)
    }

    /// The actual find() captures a playing candidate before Promise.all
    /// completes. A hover preview can change while that search is pending.
    @MainActor @Test(arguments: ["removed", "paused", "not-ready", "zero-area"])
    func aPreviewThatStopsDuringDiscoveryIsNotFloated(change: String) throws {
        let context = try page()
        let mutation: String
        switch change {
        case "removed": mutation = "video.isConnected = false;"
        case "paused": mutation = "video.paused = true;"
        case "not-ready": mutation = "video.readyState = 0;"
        default: mutation = "video.getBoundingClientRect = function () { return { width: 0, height: 0 }; };"
        }
        context.evaluateScript("""
            var f = window.__yabFloat, answer;
            f.on().then(function (a) { answer = a; });
            \(mutation)
            """)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("answer")?.toString() == "none")
        #expect(context.evaluateScript("video.hasAttribute('data-yab-float')")?.toBool() == false)
        #expect(context.evaluateScript("'yab-floating' in classes")?.toBool() == false)
        // A newly valid candidate still floats through the same public verb.
        context.evaluateScript("""
            video.isConnected = true; video.paused = false; video.readyState = 4;
            video.getBoundingClientRect = function () { return { width: 640, height: 360 }; };
            f.on().then(function (a) { answer = a; });
            """)
        #expect(context.evaluateScript("answer && answer[0]")?.toString() == "floating")
        #expect(context.exception == nil)
    }

    @MainActor @Test(arguments: ["element", "webkit-element", "video"])
    func automaticLiftKeepsFullscreenAndPiPAsksForTheVideoAlone(kind: String) throws {
        for verb in ["on", "pip"] {
            let context = try page()
            let mutation = kind == "element" ? "document.fullscreenElement = video;" :
                kind == "webkit-element" ? "document.webkitFullscreenElement = video;" : "video.webkitDisplayingFullscreen = true;"
            context.evaluateScript("""
                \(mutation)
                var exits = 0;
                document.exitFullscreen = function () { exits++; return Promise.resolve(); };
                document.webkitExitFullscreen = function () { exits++; };
                var answer, f = window.__yabFloat;
                f.\(verb)(1).then(function (a) { answer = a; });
                """)
            #expect(context.exception == nil)
            // The page never leaves WebKit's full-screen window on its own;
            // the video alone may, as ⇧⌘P puts it out.
            #expect(context.evaluateScript("answer")?.toString() == (verb == "on" ? "none" : "pip"))
            #expect(context.evaluateScript("exits")?.toInt32() == 0)
            #expect(context.evaluateScript("pipRequests")?.toInt32() == (verb == "on" ? 0 : 1))
            #expect(context.evaluateScript("video.hasAttribute('data-yab-float')")?.toBool() == false)
            context.evaluateScript("f.\(verb)(0).then(function (a) { answer = a; });")
            #expect(context.evaluateScript("typeof answer === 'string' ? answer : answer[0]")?.toString() == (verb == "on" ? "floating" : "pip"))
            #expect(context.exception == nil)
        }
    }

    @MainActor @Test(arguments: ["muted", "zero-volume", "hover", "inline", "secondary", "short", "seeked"])
    func automaticPiPIgnoresPreviewsButManualPiPStillWorks(kind: String) throws {
        let mutation: String
        switch kind {
        case "muted": mutation = "video.muted = true;"
        case "zero-volume": mutation = "video.volume = 0;"
        case "hover": mutation = "video.preview = 'ytd-video-preview';"
        case "inline": mutation = "video.preview = '#inline-preview-player';"
        case "secondary": mutation = "video.main = false;"
        case "short": mutation = "video.playedSeconds = 0.999;"
        default: mutation = "video.currentTime = 120; video.playedSeconds = 0;"
        }
        for verb in ["on", "pip"] {
            let context = try page()
            context.evaluateScript("""
                \(mutation)
                var answer, f = window.__yabFloat;
                f.\(verb)(1).then(function (a) { answer = a; });
                """)
            #expect(context.exception == nil)
            #expect(context.evaluateScript("answer")?.toString() == "none")
            #expect(context.evaluateScript("pipRequests")?.toInt32() == 0)
            #expect(context.evaluateScript("video.hasAttribute('data-yab-float')")?.toBool() == false)
            context.evaluateScript("f.\(verb)(0).then(function (a) { answer = a; });")
            #expect(context.evaluateScript("typeof answer === 'string' ? answer : answer[0]")?.toString() == (verb == "on" ? "floating" : "pip"))
            #expect(context.exception == nil)
        }
    }

    @MainActor @Test(arguments: ["www.youtube.com", "www.youtube-nocookie.com", "player.vimeo.com", "player.example", "notyoutube.com"])
    func automaticPiPKeepsTheRealPlayingVideo(host: String) throws {
        for verb in ["on", "pip"] {
            let context = try page()
            context.evaluateScript("""
                location.hostname = '\(host)';
                if (location.hostname.indexOf('youtube') < 0 || location.hostname === 'notyoutube.com') video.main = false;
                var answer;
                window.__yabFloat.\(verb)(1).then(function (a) { answer = a; });
                """)
            #expect(context.evaluateScript("typeof answer === 'string' ? answer : answer[0]")?.toString() == (verb == "on" ? "floating" : "pip"))
            #expect(context.evaluateScript("pipRequests")?.toInt32() == (verb == "pip" ? 1 : 0))
            #expect(context.exception == nil)
        }
    }

    @MainActor @Test(arguments: [1, 2]) func playedRangesCountPlaybackAcrossSeeks(policy: Int) throws {
        let context = try page()
        let length = policy == 2 ? 1.5 : 0.5
        context.evaluateScript("""
            video.playedSeconds = 0;
            mediaEvent('click', video); mediaEvent('play', video);
            video.played = { length: 2,
              start: function (i) { return i ? 20 : 0; },
              end: function (i) { return i ? 20 + \(length) : \(length); }
            };
            var answer;
            window.__yabFloat.pip(\(policy)).then(function (a) { answer = a; });
            """)
        #expect(context.evaluateScript("answer")?.toString() == "pip")
        #expect(context.exception == nil)
    }

    @MainActor @Test(arguments: ["muted", "preview", "short", "removed", "landed", "fullscreen"])
    func automaticPiPRechecksTheVideoAfterDiscovery(change: String) throws {
        let mutation: String
        switch change {
        case "muted": mutation = "video.muted = true;"
        case "preview": mutation = "video.preview = 'ytd-video-preview';"
        case "short": mutation = "video.playedSeconds = 0;"
        case "removed": mutation = "video.isConnected = false;"
        case "fullscreen": mutation = "document.fullscreenElement = video;"
        default: mutation = "f.off();"
        }
        for verb in change == "fullscreen" ? ["on"] : ["on", "pip"] {
            let context = try page()
            context.evaluateScript("""
                var answer, f = window.__yabFloat;
                f.\(verb)(1).then(function (a) { answer = a; });
                \(mutation)
                """)
            #expect(context.evaluateScript("answer")?.toString() == "none")
            #expect(context.evaluateScript("pipRequests")?.toInt32() == 0)
            #expect(context.evaluateScript("video.hasAttribute('data-yab-float')")?.toBool() == false)
            #expect(context.exception == nil)
        }
    }

    @MainActor @Test(arguments: ["entry", "returned"])
    func chromiumAutomaticPiPCannotOutliveAFullscreenTransition(phase: String) throws {
        let context = try page()
        context.evaluateScript("""
            var answer;
            window.__yabFloat.pip(1, true).then(function (a) { answer = a; });
            document.fullscreenElement = video;
            mediaEvent('fullscreenchange', document);
            \(phase == "returned" ? "document.fullscreenElement = null; mediaEvent('fullscreenchange', document);" : "")
            """)
        #expect(context.evaluateScript("answer")?.toString() == "none")
        #expect(context.evaluateScript("pipRequests")?.toInt32() == 0)
        #expect(context.exception == nil)
    }

    @MainActor @Test(arguments: ["manual", "webkit"])
    func fullscreenDiscoveryCancellationKeepsExistingPiPRoutes(route: String) throws {
        let context = try page()
        context.evaluateScript("""
            var answer;
            window.__yabFloat.pip(\(route == "manual" ? "0, true" : "1")).then(function (a) { answer = a; });
            document.fullscreenElement = video;
            mediaEvent('fullscreenchange', document);
            """)
        #expect(context.evaluateScript("answer")?.toString() == "pip")
        #expect(context.evaluateScript("pipRequests")?.toInt32() == 1)
        #expect(context.exception == nil)
    }

    @MainActor @Test func automaticSelectionSkipsALargerPreview() throws {
        let context = try page()
        context.evaluateScript("""
            var preview = playingVideo();
            preview.preview = 'ytd-video-preview';
            preview.getBoundingClientRect = function () { return { width: 1920, height: 1080 }; };
            videos = [preview, video];
            var answer;
            window.__yabFloat.on(1).then(function (a) { answer = a; });
            """)
        #expect(context.evaluateScript("answer && answer[0]")?.toString() == "floating")
        #expect(context.evaluateScript("document.querySelectorAll('video')[1].hasAttribute('data-yab-float')")?.toBool() == true)
        #expect(context.evaluateScript("preview.hasAttribute('data-yab-float')")?.toBool() == false)
        #expect(context.exception == nil)
    }

    @MainActor @Test func automaticReplacementDoesNotAdoptAPreview() throws {
        let context = try page()
        context.evaluateScript("""
            var f = window.__yabFloat;
            f.on(1);
            """)
        #expect(context.evaluateScript("video.hasAttribute('data-yab-float')")?.toBool() == true)
        context.evaluateScript("""
            video.isConnected = false;
            var replacement = playingVideo();
            replacement.isConnected = true; replacement.muted = true;
            videos = [replacement];
            watches[watches.length - 1]();
            """)
        #expect(context.evaluateScript("video.hasAttribute('data-yab-float')")?.toBool() == true)
        #expect(context.evaluateScript("replacement.hasAttribute('data-yab-float')")?.toBool() == false)
        #expect(context.exception == nil)
    }

    @MainActor @Test(arguments: ["on", "pip", "size"], [1, 2])
    func automaticDiscoveryPassesItsPolicyIntoFrames(verb: String, policy: Int) throws {
        let context = try page()
        context.evaluateScript("""
            video.paused = true;
            var requests = [], frame = element('IFRAME');
            frame.contentWindow = { postMessage: function (data) {
              requests.push([data.verb, data.argument]);
              Promise.resolve().then(function () {
                floatMessage({ data: { yabFloat: data.yabFloat, reply: true, id: data.id,
                  value: data.verb === 'size' ? 640 * 360 : data.verb === 'pip' ? 'pip' : ['floating', 640, 360] },
                  stopImmediatePropagation: function () {} });
              });
            } };
            framesInPage = [frame];
            var answer;
            window.__yabFloat.\(verb)(\(policy)).then(function (a) { answer = a; });
            """)
        let expected = verb == "size" ? "[[\"size\",\(policy)]]" : "[[\"size\",\(policy)],[\"\(verb)\",\(policy)]]"
        #expect(context.evaluateScript("JSON.stringify(requests)")?.toString() == expected)
        if verb == "pip" { #expect(context.evaluateScript("answer")?.toString() == "pip") }
        #expect(context.evaluateScript("answer != null")?.toBool() == true)
        #expect(context.exception == nil)
    }

    @MainActor @Test(arguments: [0, 1, 2], [false, true])
    func fullscreenWhileAChildLiftAnswersRestoresTheChildUnlessManual(policy: Int, manualOwner: Bool) throws {
        let context = try page()
        context.evaluateScript("""
            video.paused = true;
            var frame = element('IFRAME'), heldOn, childIsolated = false, childOff = 0;
            frame.isConnected = true;
            function reply(data, value) {
              floatMessage({ data: { yabFloat: data.yabFloat, reply: true, id: data.id, value: value },
                stopImmediatePropagation: function () {} });
            }
            frame.contentWindow = { postMessage: function (data) {
              if (data.verb === 'on') {
                childIsolated = true;
                heldOn = data;
                return;
              }
              if (data.verb === 'off') { childOff++; childIsolated = false; }
              Promise.resolve().then(function () {
                reply(data, data.verb === 'size' ? 640 * 360 : [0, false, 1, 60, 1, 640, 360]);
              });
            } };
            framesInPage = [frame];
            var answer;
            window.__yabFloat.on(\(policy)).then(function (a) { answer = a; });
            """)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("heldOn != null && childIsolated && answer == null")?.toBool() == true,
                "Fullscreen must begin after the child isolated its video, before its reply")
        context.evaluateScript("var oldRequest = heldOn; document.fullscreenElement = frame;")
        if manualOwner {
            context.evaluateScript("var manualAnswer; window.__yabFloat.on(0).then(function (a) { manualAnswer = a; });")
            #expect(context.evaluateScript("heldOn !== oldRequest")?.toBool() == true)
            context.evaluateScript("reply(heldOn, ['floating', 640, 360]);")
            #expect(context.evaluateScript("manualAnswer && manualAnswer[0]")?.toString() == "floating")
        }
        context.evaluateScript("reply(oldRequest, ['floating', 640, 360]);")
        #expect(context.exception == nil)
        #expect(context.evaluateScript("typeof answer === 'string' ? answer : answer[0]")?.toString() == (policy == 0 ? "floating" : "none"))
        #expect(context.evaluateScript("childIsolated")?.toBool() == (policy == 0 || manualOwner))
        #expect(context.evaluateScript("childOff")?.toInt32() == (policy == 0 || manualOwner ? 0 : 1))
        #expect(context.evaluateScript("'yab-floating' in classes")?.toBool() == (policy == 0 || manualOwner))
    }

    @MainActor @Test(arguments: ["user-five", "autoplay-ten", "user-one", "user-three", "listed"])
    func automaticPiPRequiresAUserStartAndThreeSecondsOnUnlistedSites(_ scenario: String) throws {
        let listed = scenario == "listed"
        let policy = Players.automaticPolicy(URL(string: listed ? "https://youtube.com/watch?v=1" : "https://studio.example/film"))
        let seconds = scenario == "autoplay-ten" ? 10 : scenario == "user-five" ? 5 : scenario == "user-three" ? 3 : 1
        let expected = listed || scenario == "user-five" || scenario == "user-three"
        for verb in ["on", "pip"] {
            let context = try page()
            context.evaluateScript("""
                location.hostname = '\(listed ? "youtube.com" : "studio.example")';
                video.playedSeconds = 0;
                if ('\(scenario)'.indexOf('user-') === 0) mediaEvent('click', video);
                mediaEvent('play', video);
                now += \(seconds * 1000); video.playedSeconds = \(seconds);
                var answer;
                window.__yabFloat.\(verb)(\(policy)).then(function (a) { answer = a; });
                """)
            #expect(context.exception == nil)
            #expect(context.evaluateScript("typeof answer === 'string' ? answer : answer[0]")?.toString() == (expected ? (verb == "on" ? "floating" : "pip") : "none"))
            #expect(context.evaluateScript("pipRequests")?.toInt32() == (expected && verb == "pip" ? 1 : 0))
        }
    }

    @MainActor @Test(arguments: ["keydown", "activation", "sticky-activation", "late-click", "stale-click", "synthetic-click", "new-source", "ended", "other-video", "old-playback"])
    func automaticPiPRemembersOnlyTheVideoStartedByRealInput(_ scenario: String) throws {
        let context = try page()
        context.evaluateScript("""
            location.hostname = 'studio.example'; video.playedSeconds = 0;
            switch ('\(scenario)') {
              case 'keydown': mediaEvent('keydown', video); break;
              case 'activation': window.navigator = { userActivation: { isActive: true } }; break;
              case 'sticky-activation': window.navigator = { userActivation: { isActive: false, hasBeenActive: true } }; break;
              case 'late-click': break;
              case 'synthetic-click': mediaEvent('click', video, false); break;
              default: mediaEvent('click', video);
            }
            if ('\(scenario)' === 'stale-click') now += 1001;
            if ('\(scenario)' === 'old-playback') video.playedSeconds = 10;
            mediaEvent('play', video);
            if ('\(scenario)' === 'activation') window.navigator.userActivation.isActive = false;
            now += 5000; video.playedSeconds = 5;
            if ('\(scenario)' === 'late-click') mediaEvent('click', video);
            if ('\(scenario)' === 'new-source' || '\(scenario)' === 'ended') {
              mediaEvent('\(scenario == "ended" ? "ended" : "loadstart")', video);
              mediaEvent('play', video);
              video.playedSeconds = 10;
            }
            if ('\(scenario)' === 'other-video') videos = [playingVideo()];
            if ('\(scenario)' === 'old-playback') video.playedSeconds = 11;
            var answer;
            window.__yabFloat.pip(2).then(function (a) { answer = a; });
            """)
        #expect(context.evaluateScript("answer")?.toString() == (scenario == "keydown" || scenario == "activation" ? "pip" : "none"))
        #expect(context.exception == nil)
        context.evaluateScript("window.__yabFloat.pip(0).then(function (a) { answer = a; });")
        #expect(context.evaluateScript("answer")?.toString() == "pip")
    }

    @MainActor @Test func automaticPiPTracksInputInsideAnOpenShadowRoot() throws {
        let context = try page()
        context.evaluateScript("""
            location.hostname = 'studio.example'; video.playedSeconds = 0;
            var shadowListeners = {}, shadow = { nodeType: 11, addEventListener: function (type, f) {
              (shadowListeners[type] || (shadowListeners[type] = [])).push(f);
            } };
            mediaListeners.pointerdown[0]({ isTrusted: true, composedPath: function () { return [video, shadow, document]; } });
            shadowListeners.play[0]({ type: 'play', target: video, isTrusted: true });
            now += 5000; video.playedSeconds = 5;
            var answer;
            window.__yabFloat.pip(2).then(function (a) { answer = a; });
            """)
        #expect(context.evaluateScript("answer")?.toString() == "pip")
        #expect(context.exception == nil)
    }

    @MainActor @Test(arguments: ["loadstart", "emptied", "ended"])
    func automaticPiPRechecksTheUserStartAfterDiscovery(_ event: String) throws {
        for verb in ["on", "pip"] {
            let context = try page()
            context.evaluateScript("""
                video.playedSeconds = 0;
                mediaEvent('click', video); mediaEvent('play', video);
                video.playedSeconds = 5;
                var answer;
                window.__yabFloat.\(verb)(2).then(function (a) { answer = a; });
                mediaEvent('\(event)', video);
                """)
            #expect(context.evaluateScript("answer")?.toString() == "none")
            #expect(context.evaluateScript("pipRequests")?.toInt32() == 0)
            #expect(context.evaluateScript("video.hasAttribute('data-yab-float')")?.toBool() == false)
            #expect(context.exception == nil)
        }
    }

    /// A page with one playing video, and the float script in it. Timers
    /// and animation frames run only when the test calls `flush()`.
    @MainActor private func page() throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript("""
            var heard = [], now = 10000, mediaListeners = {};
            Date.now = function () { return now; };
            function mediaEvent(type, target, trusted) {
              var event = { type: type, target: target, isTrusted: trusted !== false };
              (mediaListeners[type] || []).forEach(function (f) { f(event); });
            }
            function Event(type) { this.type = type; }
            function dispatchEvent(event) { heard.push(event.type); return true; }
            var watches = [];
            function setInterval(f) { watches.push(f); return watches.length; }
            function clearInterval() {}
            var timers = [], frames = [];
            function setTimeout(f) { timers.push(f); return 1; }
            function clearTimeout() {}
            function requestAnimationFrame(f) { frames.push(f); return 1; }
            function flush() {
              for (var n = 0; n < 20 && (frames.length || timers.length); n++) {
                frames.splice(0).concat(timers.splice(0)).forEach(function (f) { f(); });
              }
            }
            function element(tag) {
              var attributes = {};
              return {
                tagName: tag, parentNode: null, parentElement: null,
                setAttribute: function (k, v) { attributes[k] = v; },
                removeAttribute: function (k) { delete attributes[k]; },
                hasAttribute: function (k) { return k in attributes; },
                getAttribute: function (k) { return k in attributes ? attributes[k] : null; },
                appendChild: function () {}, remove: function () {},
                style: {
                  values: {},
                  getPropertyValue: function (p) { return this.values[p] || ''; },
                  setProperty: function (p, v) { this.values[p] = v; },
                  removeProperty: function (p) { delete this.values[p]; }
                },
                getBoundingClientRect: function () { return { width: 640, height: 360 }; }
              };
            }
            var pipRequests = 0;
            function playingVideo() {
              var v = element('VIDEO');
              v.paused = false; v.ended = false; v.readyState = 4; v.isConnected = true;
              v.currentTime = 1; v.duration = 60; v.videoWidth = 1280; v.videoHeight = 720;
              v.muted = false; v.volume = 1; v.main = true; v.playedSeconds = 1;
              v.played = { length: 1, start: function () { return 0; }, end: function () { return v.playedSeconds; } };
              v.closest = function (selector) {
                if (selector === '#movie_player') return this.main ? mainPlayer : null;
                return this.preview && selector.split(', ').indexOf(this.preview) >= 0 ? {} : null;
              };
              v.requestPictureInPicture = function () { pipRequests++; return Promise.resolve(); };
              return v;
            }
            var video = playingVideo();
            var mainPlayer = { querySelector: function () { return video; } };
            var videos = [video], framesInPage = [], location = { hostname: 'www.youtube.com' };
            var classes = {};
            var document = {
              head: element('HEAD'),
              documentElement: { classList: { add: function (c) { classes[c] = 1; }, remove: function (c) { delete classes[c]; } } },
              createElement: function (tag) { return element(tag.toUpperCase()); },
              getElementById: function () { return null; },
              querySelectorAll: function (selector) { return selector === 'video' ? videos : selector === 'iframe, frame' ? framesInPage : []; },
              visibilityState: 'visible', listeners: [],
              addEventListener: function (type, f) {
                if (type === 'visibilitychange') this.listeners.push(f);
                else (mediaListeners[type] || (mediaListeners[type] = [])).push(f);
              },
              removeEventListener: function (type, f) { this.listeners = this.listeners.filter(function (g) { return g !== f; }); }
            };
            function show(state) {
              document.visibilityState = state;
              document.listeners.slice().forEach(function (f) { f(); });
            }
            var floatMessage;
            var window = { addEventListener: function (type, f) { if (type === 'message') floatMessage = f; } };
            """)
        context.evaluateScript(Isolate.script.source)
        #expect(context.exception == nil)
        return context
    }
}
