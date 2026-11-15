// Runs in JavaScriptCore from VideoOpeningTests, or directly with Node.
if (typeof openingScript === 'undefined') {
    var openingScript = require('fs').readFileSync(require('path').join(__dirname, '../../Resources/PageScripts/video-opening.js'), 'utf8');
}
var videoOpeningChecks = 0;
(function () {
    function check(value, message) {
        videoOpeningChecks++;
        if (!value) throw new Error(message);
    }
    function world(youtube) {
        var events = {}, focused = true;
        var location = { hostname: youtube ? 'www.youtube.com' : 'video.test', href: 'https://video.test/watch' };
        var window = { addEventListener: function (name, fn) { events[name] = fn; } };
        var document = {
            hidden: false,
            hasFocus: function () { return focused; },
            addEventListener: function (name, fn) { events[name] = fn; },
            querySelector: function () { return main; },
            querySelectorAll: function () { return videos; }
        };
        function getComputedStyle(v) { return { visibility: v.hidden ? 'hidden' : 'visible', display: 'block' }; }
        function HTMLMediaElement() {}
        function HTMLVideoElement() {}
        HTMLVideoElement.prototype = Object.create(HTMLMediaElement.prototype);
        HTMLMediaElement.prototype.play = function () {
            this.calls++;
            var v = this;
            return { then: function (resolve, reject) {
                if (v.denied) reject({ name: v.denied });
                else { v.resolve = resolve; v.reject = reject; }
            } };
        };
        HTMLMediaElement.prototype.pause = function () { this.paused = true; this.pauses++; };
        function video(size) {
            var v = new HTMLVideoElement();
            Object.assign(v, {
                currentSrc: 'blob:video', paused: true, ended: false, currentTime: 0, played: { length: 0 },
                isConnected: true, error: null, calls: 0, pauses: 0, autoplay: false, denied: 'NotAllowedError',
                getBoundingClientRect: function () { return { width: size, height: size }; },
                closest: function () { return this.preview; },
                addEventListener: function (name, fn) { this[name] = fn; },
                removeEventListener: function (name) { delete this[name]; }
            });
            return v;
        }
        var main = video(640), ad = video(160), videos = [main, ad];
        eval(openingScript);
        return {
            main: main, ad: ad, videos: videos, page: window.__yabVideoOpening, document: document, events: events,
            blur: function () { focused = false; events.blur(); },
            focus: function () { focused = true; },
            location: location, video: video,
            allow: function (v) { v.denied = null; }
        };
    }
    var w = world(false);
    check(!w.page.probe(false), 'A paused video is not evidence of blocked autoplay');
    w.ad.play();
    check(!w.page.probe(false), 'An ad refusal must not start the main video');
    w.main.play();
    check(w.page.probe(false), 'The main video remembers its own denied play');
    check(w.main.calls === 1 && w.ad.calls === 1, 'Probing has no playback side effects');
    w.allow(w.main);
    check(w.page.play(), 'A blocked main video is retried');
    check(w.main.calls === 2 && w.ad.calls === 1, 'Only one video is retried');
    check(!w.page.play(), 'A retry is consumed once');
    w.main.resolve();
    w.page.cancel();
    check(w.main.pauses === 0, 'A video already started in front keeps playing normally');

    for (var field of ['ended', 'error', 'preview', 'hidden']) {
        w = world(field === 'preview');
        w.main.play();
        w.main[field] = true;
        check(!w.page.probe(false), 'Exclude ' + field + ' video');
    }
    for (var field of ['currentTime', 'played']) {
        w = world(false); w.main.play();
        if (field === 'played') w.main.played.length = 1; else w.main.currentTime = 1;
        check(!w.page.probe(false), 'Exclude a video that already played or was seeked');
    }
    w = world(false); w.main.play(); w.main.paused = false;
    check(!w.page.probe(false), 'Leave an already playing video alone');
    w = world(false); w.main.play(); w.main.isConnected = false;
    check(!w.page.probe(false), 'Exclude detached video');
    w = world(false); w.main.play(); w.main.pause();
    check(!w.page.probe(false), 'An explicit page pause wins over a prior refusal');
    w = world(false); w.main.play(); w.page.probe(false); w.main.pause();
    check(!w.page.play(), 'An explicit pause after probing cannot be undone');
    w = world(false); w.main.denied = 'NotSupportedError'; w.main.play();
    check(!w.page.probe(false), 'A codec error is not an autoplay block');
    w = world(false); w.main.play(); w.main.currentSrc = 'blob:other';
    check(!w.page.probe(false), 'Another source does not inherit a refusal');
    w = world(false); w.main.play(); w.page.probe(false); w.main.currentSrc = 'blob:other';
    check(!w.page.play(), 'Source replacement after the probe cannot play');
    w = world(false); w.main.play(); w.page.probe(false); w.location.href += '#another';
    check(!w.page.play(), 'A same-document navigation does not inherit the retry');

    w = world(true); w.main.autoplay = true;
    check(!w.page.probe(false), 'YouTube autoplay intent alone is insufficient');
    w.page.prevented(true);
    check(w.page.probe(false), 'YouTube main autoplay intent and native main-media refusal qualify');
    w.main.currentSrc = 'blob:other';
    check(!w.page.probe(false), 'Declarative autoplay source changes do not inherit refusal');
    w = world(false); w.main.autoplay = true; w.page.prevented(false);
    check(!w.page.probe(false), 'A non-main-media block cannot qualify declarative autoplay');
    w.page.prevented(true);
    check(w.page.probe(false), 'Main declarative autoplay remembers its native refusal');
    w = world(true); w.main.play();
    check(w.page.probe(false), 'YouTube scripted autoplay remembers the exact refusal');
    w = world(true); w.ad.play();
    check(!w.page.probe(false), 'A YouTube preview does not qualify the movie player');

    w = world(false); w.main.play(); w.page.probe(false); w.document.hidden = true;
    check(!w.page.play() && w.main.calls === 1, 'Hidden after probe cannot dispatch playback');
    w = world(false); w.main.play(); w.page.probe(false); w.blur();
    check(!w.page.play() && w.main.calls === 1, 'Blur after probe cannot dispatch playback');
    w = world(false); w.main.play(); w.page.probe(false); w.events.pointerdown({ isTrusted: true });
    check(!w.page.play(), 'A real input cancels the automatic retry');
    w = world(false); w.main.play(); w.page.probe(false); w.events.keydown({ isTrusted: true });
    check(!w.page.play(), 'A key takes over playback intent');
    w = world(false); w.main.play(); w.page.probe(false); w.allow(w.main); w.page.play();
    w.document.hidden = true; w.events.visibilitychange();
    check(w.main.pauses === 1, 'Hiding cancels a play still waiting to start');
    w.main.playing();
    check(w.main.pauses === 2, 'A late playing event in a hidden tab is paused');
    w.main.resolve();
    check(w.main.pauses === 3, 'A late play completion in a hidden tab is paused');
    w = world(false); w.main.play(); w.page.probe(false); w.allow(w.main); w.page.play();
    w.blur();
    check(w.main.pauses === 1, 'Deactivation cancels a play still waiting to start');
    w.focus();
    check(!w.page.probe(false), 'Returning after cancellation cannot retry');
})();
if (typeof console !== 'undefined') console.log('Video opening checks: ' + videoOpeningChecks);
