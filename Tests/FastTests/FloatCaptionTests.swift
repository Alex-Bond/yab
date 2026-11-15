import JavaScriptCore
import Testing
@testable import Fast

struct FloatCaptionTests {
    @MainActor private func page() throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript("""
            var window = { addEventListener: function () {} };
            function setInterval() { return 1; }
            function clearInterval() {}
            // A style as the script reads and writes it, by property too.
            function style() {
              var made = {};
              Object.defineProperties(made, {
                getPropertyValue: { value: function (name) { return this[name] || ''; } },
                setProperty: { value: function (name, value) { this[name] = value; } },
                removeProperty: { value: function (name) { delete this[name]; } }
              });
              return made;
            }
            function element(parent, tag) {
              return {
                tagName: tag || 'DIV', parentElement: parent, parentNode: parent,
                isConnected: true, attrs: {}, style: style(),
                setAttribute: function (key, value) { this.attrs[key] = value; },
                getAttribute: function (key) { return this.attrs[key] || null; },
                hasAttribute: function (key) { return key in this.attrs; },
                removeAttribute: function (key) { delete this.attrs[key]; },
                getBoundingClientRect: function () { return { width: 640, height: 360 }; }
              };
            }
            var html = element(null, 'HTML');
            html.classList = { add: function () {}, remove: function () {} };
            var body = element(html, 'BODY');
            var player = element(body);
            var video = element(player, 'VIDEO');
            video.paused = false; video.readyState = 4; video.textTracks = [];
            var wrapper = element(player);
            var captions = element(wrapper);
            captions.innerText = '  Current subtitle  ';
            var otherPlayer = element(body);
            var otherCaptions = element(otherPlayer);
            otherCaptions.innerText = 'Unrelated subtitle';
            var floatStyle = null;
            var document = {
              body: body, documentElement: html,
              head: { appendChild: function (sheet) { floatStyle = sheet; } },
              getElementById: function () { return floatStyle; },
              createElement: function () {
                return { sheet: { disabled: false }, remove: function () { floatStyle = null; } };
              },
              querySelectorAll: function (selector) {
                if (selector === 'video') return [video];
                if (selector.indexOf('ytp-caption') !== -1) return [captions, otherCaptions];
                return [];
              }
            };
            function getComputedStyle(el) {
              // Reproduce PiP's override, which otherwise masks the site's
              // visibility and opacity when closed captions are switched off.
              if (el === captions && floatStyle && !floatStyle.sheet.disabled)
                return { display: 'block', visibility: 'visible', opacity: '0' };
              return Object.assign({ display: 'block', visibility: 'visible', opacity: '1' }, el.style);
            }
            """)
        context.evaluateScript(Isolate.script.source)
        context.evaluateScript("window.__yabFloat.on().then(function (value) { floated = value[0]; });")
        #expect(context.exception == nil)
        #expect(context.evaluateScript("floated")?.toString() == "floating")
        return context
    }

    @MainActor private func words(_ context: JSContext) -> String? {
        context.evaluateScript("window.__yabFloat.words().then(function (value) { spoken = value; });")
        #expect(context.exception == nil)
        #expect(context.evaluateScript("floatStyle.sheet.disabled")?.toBool() == false)
        return context.evaluateScript("spoken")?.toString()
    }

    @MainActor @Test(arguments: [
        "captions.style.display = 'none'",
        "captions.style.visibility = 'hidden'",
        "captions.style.opacity = '0'",
        "wrapper.style.display = 'none'",
        "wrapper.style.visibility = 'hidden'",
        "wrapper.style.opacity = '0'",
        "wrapper.style.contentVisibility = 'hidden'",
        "captions.hidden = true",
        "wrapper.hidden = true"
    ])
    func disabledCaptionsStayOffAndCanBeReenabled(_ hide: String) throws {
        let context = try page()
        #expect(words(context) == "Current subtitle")
        context.evaluateScript(hide)
        #expect(words(context) == "")
        context.evaluateScript("captions.style = {}; wrapper.style = {}; captions.hidden = false; wrapper.hidden = false;")
        #expect(words(context) == "Current subtitle")
    }

    @MainActor @Test func nativeTracksFollowTheirMode() throws {
        let context = try page()
        context.evaluateScript("""
            captions.style.display = 'none';
            video.textTracks = [{ kind: 'subtitles', mode: 'showing', activeCues: [{ text: 'Native subtitle' }] }];
            """)
        #expect(words(context) == "Native subtitle")
        for mode in ["hidden", "disabled"] {
            context.evaluateScript("video.textTracks[0].mode = '\(mode)';")
            #expect(words(context) == "")
        }
        #expect(context.evaluateScript("video.textTracks[0].mode")?.toString() == "disabled")
    }

    @MainActor @Test func ignoresCaptionsFromAnotherPlayer() throws {
        let context = try page()
        context.evaluateScript("""
            var query = document.querySelectorAll;
            document.querySelectorAll = function (selector) {
              if (selector.indexOf('ytp-caption') !== -1) return [otherCaptions, captions];
              return query(selector);
            };
            """)
        #expect(words(context) == "Current subtitle")
        context.evaluateScript("captions.innerText = '';")
        #expect(words(context) == "")
    }

    @MainActor @Test func restoresFloatStylesAfterCaptionReadFails() throws {
        let context = try page()
        context.evaluateScript("""
            Object.defineProperty(captions, 'innerText', { get: function () { throw new Error('Gone'); } });
            try { window.__yabFloat.words(); } catch (error) { failed = true; }
            """)
        #expect(context.evaluateScript("failed")?.toBool() == true)
        #expect(context.evaluateScript("floatStyle.sheet.disabled")?.toBool() == false)
    }
}
