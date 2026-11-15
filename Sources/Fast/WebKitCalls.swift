import WebKit

extension PageHandle {
    /// Floater still owns a WebKit view; migrate its native view lifecycle
    /// separately from ordinary call controls and scripts.
    func webKitPutOut(_ tab: Tab, in browser: Browser) {
        if let webKit { browser.putOut(tab, web: webKit) }
    }
}

extension Tab {
    static let screenKey = "_displayCaptureState"
    /// The screen or a window shown by the page, as WebKit has it now.
    static func screenState(of web: WKWebView) -> WKMediaCaptureState {
        guard web.responds(to: NSSelectorFromString(screenKey)) else { return .none }
        return WKMediaCaptureState(rawValue: (web.value(forKey: screenKey) as? NSNumber)?.intValue ?? 0) ?? .none
    }

    static func endScreen(of web: WKWebView) {
        let selector = NSSelectorFromString("_setDisplayCaptureState:completionHandler:")
        guard web.responds(to: selector) else { return }
        typealias Set = @convention(c) (AnyObject, Selector, Int, @convention(block) () -> Void) -> Void
        unsafeBitCast(web.method(for: selector), to: Set.self)(web, selector, WKMediaCaptureState.none.rawValue, {})
    }
}

extension CallStage {
    static var world: WKContentWorld { PageWorld.named("call").contentWorld }
    static func run(_ verb: String, _ argument: Any = 0, on web: PageView, _ answer: ((Any?) -> Void)? = nil) {
        run(verb, argument, on: web as any PageHandle, answer)
    }
    static func run(_ verb: String, _ argument: Any = 0, on web: WKWebView, _ answer: ((Any?) -> Void)? = nil) {
        if let page = web as? any PageHandle { return run(verb, argument, on: page, answer) }
        let arguments: [String: Any] = ["verb": verb, "argument": argument]
        func done(_ result: Result<Any, any Error>) {
            if case .success(let value) = result { answer?(value) } else { answer?(nil) }
        }
        handed(call)
        web.callAsyncJavaScript(call, arguments: arguments, in: nil, in: world) { [weak web] result in
            MainActor.assumeIsolated {
                guard case .success(let value) = result, value as? String == missing else { return done(result) }
                guard let web else { answer?(nil); return }
                handed(source)
                handed(call)
                web.callAsyncJavaScript(source + "\n" + call, arguments: arguments, in: nil, in: world) { result in
                    MainActor.assumeIsolated { done(result) }
                }
            }
        }
    }
}

extension PageMediaState {
    var webKit: WKMediaCaptureState {
        switch self {
        case .none: return .none
        case .active: return .active
        case .muted: return .muted
        }
    }
}

/// The call's own microphone and camera switches, read and pressed from
/// yab's world. Meet and Zoom mute by switching their track off, which
/// WebKit never hears of: muted from the page, the dot said you were
/// heard; muted from the dot, the page said you were live and nobody saw
/// you muted. Meet's buttons carry `data-is-muted` and stable `jsname`s
/// whatever the language; Zoom's web client says it in its buttons'
/// labels ("mute my microphone", "start my video"). Watched for those,
/// and pressed for a change, so the page, the dot, the window and the
/// menu are one switch. Elsewhere WebKit's capture state stays the switch.
final class CallRelay: NSObject, PageScriptReceiving {
    static let name = "yabCall"
    weak var tab: Tab?

    /// The sites whose switches the script reads: Meet, and Zoom's web
    /// client on any of its hosts (app.zoom.us, us06web.zoom.us).
    nonisolated static func serves(_ host: String) -> Bool {
        let host = host.lowercased()
        return host == "meet.google.com" || host == "zoom.us" || host.hasSuffix(".zoom.us") || host == "app.slack.com"
    }

    func receive(_ message: PageScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        let frame = message.frame
        MainActor.assumeIsolated {
            // The call's own page, the one place the script is for (RelayGuard).
            guard let tab, frame.isMain, frame.origin.scheme.lowercased() == "https",
                  Self.serves(frame.origin.host) else { return }
            let mic = body["mic"] as? Bool, camera = body["camera"] as? Bool
            // Slack's tab says nothing of a huddle's switches (they are in
            // its huddle window): an empty word there leaves what the
            // window said (Browser.captureChanged hands it over).
            if mic == nil, camera == nil, frame.origin.host.lowercased() == "app.slack.com" { return }
            tab.pageMic = mic
            tab.pageCamera = camera
        }
    }

    static let script = """
    (function () {
      var host = location.hostname;
      var meet = host === 'meet.google.com', zoom = host === 'zoom.us' || /\\.zoom\\.us$/.test(host);
      var slack = host === 'app.slack.com';
      if (!(meet || zoom || slack) || window.__yabCall) return;
      var ICON = { mic: /^mic(_off)?$/, camera: /^videocam(_off)?$/ };
      var NAME = { mic: 'hw0c9', camera: 'psRWwc' };
      // Zoom's: the label says what a press does, so the opposite of now.
      // "join audio" is no microphone at all: nothing to say or press.
      var ZOOM = { mic: '.join-audio-container__btn', camera: '.send-video-container__btn' };
      var OFF = { mic: /^unmute my microphone$/i, camera: /^start my video$/i };
      var ON = { mic: /^mute my microphone$/i, camera: /^stop my video$/i };
      // A Slack huddle's, in its huddle window: the label is what a press does.
      var SLACK = { mic: '[data-qa="segmented-mute-button-main"]', camera: '[data-qa="huddle_camera_huddle_toolbar"]' };
      var SLACK_OFF = { mic: /^unmute/i, camera: /^turn on camera/i };
      // Slack's own keys for the huddle, from its tab too: ⌘⇧Space, ⌘⇧V.
      var SLACK_KEY = { mic: [' ', 'Space', 32], camera: ['v', 'KeyV', 86] };
      function button(kind) {
        if (slack) return document.querySelector('button' + SLACK[kind]);
        if (zoom) {
          var z = document.querySelector('button' + ZOOM[kind]);
          var said = z && (z.getAttribute('aria-label') || '').trim();
          return z && (OFF[kind].test(said) || ON[kind].test(said)) ? z : null;
        }
        var hit = document.querySelector('button[jsname="' + NAME[kind] + '"][data-is-muted]');
        if (hit) return hit;
        var all = document.querySelectorAll('button[data-is-muted]');
        for (var i = 0; i < all.length; i++) {
          var icon = all[i].querySelector('i');
          if (icon && ICON[kind].test(icon.textContent.trim())) return all[i];
        }
        return null;
      }
      function muted(kind) {
        var b = button(kind);
        if (!b) return null;
        if (zoom) return OFF[kind].test((b.getAttribute('aria-label') || '').trim());
        if (slack) return SLACK_OFF[kind].test((b.getAttribute('aria-label') || '').trim());
        return b.getAttribute('data-is-muted') === 'true';
      }
      var said = '', looking = 0, soon = 0;
      function tell() {
        soon = 0;
        var now = { mic: muted('mic'), camera: muted('camera') };
        var text = JSON.stringify(now);
        if (text === said) return;
        said = text;
        window.webkit.messageHandlers.yabCall.postMessage(now);
      }
      // One attribute, on any element: nothing else the page changes
      // wakes this. Zoom's labels change with much else: a look a tick later.
      new MutationObserver(function () { if (!soon) soon = setTimeout(tell, 50); }).observe(document.documentElement, {
        subtree: true, attributes: true, attributeFilter: [zoom || slack ? 'aria-label' : 'data-is-muted']
      });
      // The buttons come with the call; until they do, a look a second.
      looking = setInterval(function () {
        tell();
        if (meet && (button('mic') || button('camera'))) { clearInterval(looking); looking = 0; }
      }, 1000);
      window.__yabCall = {
        press: function (kind) {
          var b = button(kind);
          if (!b && slack) {
            // Slack's tab, its huddle window elsewhere: the huddle's own key.
            var k = SLACK_KEY[kind], at = document.activeElement || document.body;
            ['keydown', 'keyup'].forEach(function (type) {
              at.dispatchEvent(new KeyboardEvent(type, { key: k[0], code: k[1], keyCode: k[2], which: k[2],
                metaKey: true, shiftKey: true, bubbles: true, cancelable: true }));
            });
            return true;
          }
          if (!b) return false;
          b.click();
          return true;
        }
      };
    })();
    """
}
