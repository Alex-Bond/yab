import UIKit
import WebKit

/// Where a link a page follows goes. Web addresses load in the page; an
/// app's universal link to another site, tapped, opens its app when iOS has
/// one (WebPool.decidePolicy, OutsideLink.openApp), and loads
/// here otherwise. Mail, calls, Messages, FaceTime, Maps and other apps' own
/// addresses go to iOS when the person tapped them (iOS asks before a call);
/// a page sending itself there with no touch (a redirect, a script on load)
/// is not followed, as before.
enum PageLinkRoute: Equatable, Sendable {
    /// WebKit loads it in the page.
    case page
    /// iOS opens it: Mail, Phone, Messages, FaceTime, Maps, an app.
    case outside
    /// Not followed, and not a failure of the page either.
    case refused

    /// Never handed to iOS, tapped or not: the web's own (they stay in Yab),
    /// Yab's own (a page must not press a task's Live Activity buttons),
    /// local files and scripts. App installs over the air are refused by
    /// what they ask for (`installsAnApp`), whatever their scheme.
    static let neverOutside: Set<String> = [
        "http", "https", "about", "data", "blob", "file", "javascript",
        "yab", "yab-open", PageSchemeHandler.scheme, "chrome-extension", "webkit-extension",
    ]

    /// A link that asks iOS to download and install an app from a manifest
    /// (an enterprise or ad hoc install): never followed.
    static func installsAnApp(_ url: URL) -> Bool {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.contains { $0.name.lowercased() == "action" && $0.value?.lowercased() == "download-manifest" }
    }

    /// How long a touch on the page counts for the navigation it starts: a
    /// link, or a button whose script goes to tel:.
    static let tapWindow: TimeInterval = 1

    /// `inPage`: the page may load it (WebPool.allows). `tapped`: a real
    /// touch on this page, in front, within the tap window.
    static func route(_ url: URL, inPage: Bool, navigation: WKNavigationType, tapped: Bool) -> PageLinkRoute {
        if inPage { return .page }
        let scheme = url.scheme?.lowercased() ?? ""
        guard !scheme.isEmpty, !neverOutside.contains(scheme), !installsAnApp(url) else { return .refused }
        // Back, Forward and Reload never leave for an app, whatever touched them.
        guard tapped, ![.backForward, .reload, .formResubmitted].contains(navigation) else { return .refused }
        return .outside
    }
}

/// Hands a tapped link to iOS. Test runs write each request to the file
/// YAB_OPEN_JOURNAL names, one address a line, instead of leaving the app.
@MainActor
enum OutsideLink {
    /// Unit tests see each request here instead.
    static var record: ((URL) -> Void)?

    static func open(_ url: URL) {
        if let record { record(url); return }
        if let path = ProcessInfo.processInfo.environment["YAB_OPEN_JOURNAL"], !path.isEmpty {
            let line = Data((url.absoluteString + "\n").utf8)
            if let file = FileHandle(forWritingAtPath: path) {
                file.seekToEndOfFile(); file.write(line); try? file.close()
            } else {
                FileManager.default.createFile(atPath: path, contents: line)
            }
            return
        }
        UIApplication.shared.open(url)
    }

    /// A universal link, to its app only: true when iOS opened one. Test
    /// runs journal it as "app <address>" and open nothing.
    static func openApp(_ url: URL) async -> Bool {
        if let path = ProcessInfo.processInfo.environment["YAB_OPEN_JOURNAL"], !path.isEmpty {
            let line = Data(("app " + url.absoluteString + "\n").utf8)
            if let file = FileHandle(forWritingAtPath: path) { file.seekToEndOfFile(); file.write(line); try? file.close() }
            else { FileManager.default.createFile(atPath: path, contents: line) }
            return false
        }
        if record != nil { return false }
        return await UIApplication.shared.open(url, options: [.universalLinksOnly: true])
    }
}

/// What only the person and the page's media can say, heard in a world of
/// Yab's own that the page's scripts can't reach or imitate: a real touch
/// (a link may then leave for an app) and media starting or stopping (the
/// playing page stays alive and the audio session follows it). In every
/// frame, from the document's start.
enum PageSignals {
    static let world = WKContentWorld.world(name: "yab.signals")
    static let handler = "yabSignal"

    static func install(in controller: WKUserContentController, handler: WKScriptMessageHandler) {
        controller.removeScriptMessageHandler(forName: Self.handler, contentWorld: world)
        controller.add(handler, contentWorld: world, name: Self.handler)
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: world))
    }

    /// With the store's Add to Yab only while extensions are shown (ExtensionHost.isAvailable).
    static var script: String { source.replacingOccurrences(of: "__YAB_STORE__", with: ExtensionHost.isAvailable ? "true" : "false") }

    private static let source = """
    (function () {
      var post = function (m) { try { webkit.messageHandlers.yabSignal.postMessage(m); } catch (e) {} };
      var last = 0;
      // Trusted events only: a script's click() or dispatchEvent() is not a touch.
      ['pointerup', 'click', 'keydown', 'submit'].forEach(function (kind) {
        addEventListener(kind, function (e) {
          if (!e.isTrusted || performance.now() - last < 150) return;
          last = performance.now(); post({ tap: true });
        }, { capture: true, passive: true });
      });
      // Where the finger came down, for a hold: WKContextMenuElementInfo says
      // the link, never the image (PageImage.held asks here).
      var held = null;
      addEventListener('touchstart', function (e) {
        if (e.isTrusted && e.touches.length === 1) held = { x: e.touches[0].clientX, y: e.touches[0].clientY };
      }, { capture: true, passive: true });
      window.__yabHeld = function () {
        if (!held) return null;
        var list = document.elementsFromPoint(held.x, held.y);
        for (var i = 0; i < list.length; i++) {
          var el = list[i];
          if (el.tagName === 'IMG' && (el.currentSrc || el.src)) {
            return { src: el.currentSrc || el.src, width: el.naturalWidth, height: el.naturalHeight };
          }
        }
        return null;
      };
      // A finger on a part of the page that keeps sideways moves for
      // itself (a carousel's touch-action: pan-y, a slider, a scroller
      // still able to move): a swipe there isn't Back (Back/SwipeAnywhere).
      addEventListener('touchstart', function (e) {
        if (!e.isTrusted || e.touches.length !== 1) return;
        for (var el = e.target; el && el.nodeType === 1; el = el.parentElement) {
          if (el.tagName === 'INPUT' && el.type === 'range') return post({ swipeHold: true });
          // A custom slider names itself by role; a video's own controls (its
          // progress bar) are in the strip along the bottom, an audio's all over.
          var role = el.getAttribute && el.getAttribute('role');
          if (role === 'slider' || role === 'scrollbar' || role === 'spinbutton') return post({ swipeHold: true });
          if ((el.tagName === 'VIDEO' || el.tagName === 'AUDIO') && el.hasAttribute('controls')) {
            var box = el.getBoundingClientRect(), y = e.touches[0].clientY;
            if (el.tagName === 'AUDIO' || y > box.bottom - Math.max(72, box.height * 0.3)) return post({ swipeHold: true });
          }
          var style = getComputedStyle(el), action = style.touchAction;
          if (action && action !== 'auto' && action !== 'manipulation' && action.indexOf('pan-x') < 0) return post({ swipeHold: true });
          var x = style.overflowX;
          if ((x === 'auto' || x === 'scroll') && el.scrollWidth > el.clientWidth + 1) return post({ swipeHold: true });
        }
      }, { capture: true, passive: true });
      // Media events don't bubble; capture still passes the window.
      ['play', 'playing', 'pause', 'ended', 'emptied'].forEach(function (kind) {
        addEventListener(kind, function (e) {
          if (e.target instanceof HTMLMediaElement) post({ media: true });
        }, true);
      });
      // The Chrome Web Store's page of an extension: its Add button adds it
      // to Yab, as Add to Chrome does on a computer (Extensions/ExtensionHost).
      if (__YAB_STORE__ && window === top && location.hostname === 'chromewebstore.google.com'&& /\\/detail\\//.test(location.pathname)) {
        var adds = /^(Add to (Desktop|Chrome)|Add to Yab)$/;
        var button = function (node) {
          for (var el = node; el && el !== document; el = el.parentNode) {
            if (el.tagName === 'BUTTON' && adds.test((el.textContent || '').trim())) return el;
          }
          return null;
        };
        var relabel = function () {
          document.querySelectorAll('button').forEach(function (b) {
            var words = (b.textContent || '').trim();
            if (/^Add to (Desktop|Chrome)$/.test(words)) {
              var walker = document.createTreeWalker(b, NodeFilter.SHOW_TEXT);
              for (var t = walker.nextNode(); t; t = walker.nextNode()) {
                if (/Add to (Desktop|Chrome)/.test(t.nodeValue)) { t.nodeValue = t.nodeValue.replace(/Add to (Desktop|Chrome)/, 'Add to Yab'); break; }
              }
              b.setAttribute('data-yab-add', '1');
            }
          });
        };
        addEventListener('click', function (e) {
          if (!e.isTrusted || !button(e.target)) return;
          e.preventDefault(); e.stopImmediatePropagation();
          post({ addExtension: location.href });
        }, true);
        new MutationObserver(relabel).observe(document, { childList: true, subtree: true, characterData: true });
        addEventListener('DOMContentLoaded', relabel);
      }
    })();
    """
}
