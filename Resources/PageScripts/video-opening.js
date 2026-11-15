(function () {
    if (window.__yabVideoOpening) return;
    var play = HTMLMediaElement.prototype.play;
    var pause = HTMLMediaElement.prototype.pause;
    var call = Reflect.apply;
    var blocked = new WeakMap(), dismissed = new WeakSet(), touched = false, retired = false, used = false;
    var target = null, source = null, pending = null;
    var href = location.href;

    // Keep the exact element and source whose play promise WebKit refused.
    var wrappedPlay = new Proxy(play, {
        apply: function (fn, element, args) {
            dismissed.delete(element);
            var attemptedSource = element.currentSrc;
            var result = call(fn, element, args);
            if (!retired && element instanceof HTMLVideoElement && result && result.then) {
                result.then(function () { blocked.delete(element); }, function (error) {
                    if (!retired && error && error.name === 'NotAllowedError' && element.currentSrc === attemptedSource) {
                        blocked.set(element, element.currentSrc);
                    }
                });
            }
            return result;
        }
    });

    HTMLMediaElement.prototype.play = wrappedPlay;
    var wrappedPause = new Proxy(pause, {
        apply: function (fn, element, args) {
            dismissed.add(element);
            blocked.delete(element);
            return call(fn, element, args);
        }
    });
    HTMLMediaElement.prototype.pause = wrappedPause;

    function front() { return !document.hidden && document.hasFocus() && location.href === href; }
    function mainVideo() {
        var video = null;
        if (/(^|\.)youtube\.com$/.test(location.hostname)) {
            video = document.querySelector('#movie_player video');
            if (!video) return null;
            if (video.closest('ytd-video-preview, ytd-video-preview-renderer, #inline-preview-player')) return null;
        } else {
            // The main video is the largest visible video, not a smaller ad
            // whose refusal happened to arrive first.
            var area = 0;
            document.querySelectorAll('video').forEach(function (v) {
                var box = v.getBoundingClientRect(), style = getComputedStyle(v);
                var size = box.width * box.height;
                if (box.width > 0 && box.height > 0 && style.visibility === 'visible' && style.display !== 'none' && size > area) {
                    video = v; area = size;
                }
            });
        }
        return video;
    }
    function candidate() {
        if (retired || used || touched || !front()) return null;
        var video = mainVideo();
        if (!video || !blocked.has(video)) return null;
        if (dismissed.has(video) || !video.isConnected || !video.paused || video.ended || video.currentTime !== 0 || video.played.length || video.error) return null;
        if (blocked.has(video) && blocked.get(video) !== video.currentSrc) return null;
        return video;
    }
    function cancel() {
        retired = true;
        if (HTMLMediaElement.prototype.play === wrappedPlay) HTMLMediaElement.prototype.play = play;
        if (HTMLMediaElement.prototype.pause === wrappedPause) HTMLMediaElement.prototype.pause = pause;
        if (pending) call(pause, pending, []);
        pending = null;
        target = null;
    }
    window.__yabVideoOpening = {
        prevented: function (mainContent) {
            // Declarative autoplay never calls the page's play wrapper.
            // WebKit must identify the blocked media as main content too.
            if (retired || !mainContent) return;
            var video = mainVideo();
            if (video && video.autoplay && video.paused && video.currentTime === 0 && !dismissed.has(video)) {
                blocked.set(video, video.currentSrc);
            }
        },
        probe: function () {
            target = candidate();
            source = target && target.currentSrc;
            return !!target;
        },
        play: function () {
            if (!target || candidate() !== target || target.currentSrc !== source) return false;
            used = true;
            pending = target;
            var video = target, began = false;
            function playing() {
                video.removeEventListener('playing', playing);
                if (retired || !front()) call(pause, video, []); else began = true;
                pending = null;
            }
            video.addEventListener('playing', playing);
            try {
                var result = call(play, video, []);
                if (result && result.then) result.then(function () {
                    if (!began && (retired || !front())) call(pause, video, []);
                    began = true;
                    pending = null;
                }, function () { pending = null; video.removeEventListener('playing', playing); });
            } catch (e) { pending = null; video.removeEventListener('playing', playing); }
            return true;
        },
        cancel: cancel
    };
    function input(event) { if (event.isTrusted) { touched = true; cancel(); } }
    document.addEventListener('pointerdown', input, true);
    document.addEventListener('keydown', input, true);
    document.addEventListener('visibilitychange', function () { if (document.hidden && (used || target)) cancel(); });
    window.addEventListener('blur', function () { if (used || target) cancel(); });
    window.addEventListener('pagehide', cancel);
})();
