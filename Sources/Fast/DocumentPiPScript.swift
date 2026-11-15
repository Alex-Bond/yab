import Foundation

/// The page-facing API, backed by WebKit's real window.open relationship.
/// The engine still owns both documents and their live DOM nodes.
enum DocumentPiPScript {
    static var source: String {
        let rules = Players.known.map { entry -> [String: Any] in
            ["host": entry.host, "path": entry.path as Any? ?? NSNull()]
        }
        let encoded = String(data: try! JSONSerialization.data(withJSONObject: rules), encoding: .utf8)!
        return #"""
        (() => {
          if ('documentPictureInPicture' in window || !window.isSecureContext || window.top !== window) return;
          const playerRules = \#(encoded);
          function ownedMedia() {
            const host = location.hostname.toLowerCase(), path = location.pathname.toLowerCase();
            if (playerRules.some(rule => (host === rule.host || host.endsWith('.' + rule.host)) &&
                (!rule.path || path.startsWith(rule.path)))) return true;
            const parts = location.pathname.split('/').filter(Boolean);
            if (host === 'meet.google.com')
              return /^[a-z]{3}-[a-z]{4}-[a-z]{3}$/i.test(parts[0] || '') ||
                (parts[0] === 'lookup' && parts.length >= 2);
            if (host === 'zoom.us' || host.endsWith('.zoom.us'))
              return parts.length >= 2 && ((['j','wc','s','w'].includes(parts[0]) && /^\d+$/.test(parts[1])) || parts[0] === 'my' ||
                (parts[0] === 'wc' && parts[1] === 'join' && /^\d+$/.test(parts[2] || '')));
            if (host === 'teams.microsoft.com' || host === 'teams.cloud.microsoft' || host === 'teams.live.com')
              return (parts[0] === 'l' && parts[1] === 'meetup-join' && parts.length >= 3) ||
                (parts[0] === 'meet' && parts.length >= 2);
            if (host === 'app.slack.com') return parts[0] === 'huddle' && parts.length >= 3;
            if (host.endsWith('.webex.com'))
              return parts.length >= 2 && ['meet','join','j.php','wbxmjs'].includes(parts[0]);
            return false;
          }
          // Keep sites' existing fallback paths to yab's player/call windows.
          if (ownedMedia()) return;
          const originalOpen = window.open.bind(window);
          let current = null, onenter = null;
          const prepared = new WeakSet(), ended = new WeakSet();
          const api = new EventTarget();
          Object.defineProperty(api, Symbol.toStringTag, {value:'DocumentPictureInPicture'});
          Object.defineProperty(api, 'window', {get:() => current && !current.closed ? current : null});
          Object.defineProperty(api, 'onenter', {
            get:() => onenter,
            set:value => {
              if (onenter) api.removeEventListener('enter', onenter);
              onenter = typeof value === 'function' ? value : null;
              if (onenter) api.addEventListener('enter', onenter);
            }
          });
          function dimension(value) {
            const number = value === undefined ? 0 : Number(value);
            if (!Number.isFinite(number) || number < 0 || number > Number.MAX_SAFE_INTEGER)
              throw new TypeError('Picture-in-Picture dimensions must be finite non-negative integers.');
            return Math.trunc(number);
          }
          function prepare(child) {
            // Public WebKit APIs cannot set the engine's CSS display-mode.
            // Everything else here is the actual child Window and Document.
            const stopMoving = () => {};
            child.moveTo = stopMoving;
            child.moveBy = stopMoving;
            function resize(width, height, relative) {
              if (!child.navigator.userActivation?.isActive)
                throw new child.DOMException('Resizing Picture-in-Picture requires a user gesture.', 'NotAllowedError');
              width = Number(width); height = Number(height);
              if (!Number.isFinite(width) || !Number.isFinite(height)) return;
              child.dispatchEvent(new child.CustomEvent('__yab_document_pip_resize', {
                detail:JSON.stringify({width,height,relative})
              }));
            }
            child.resizeTo = (width, height) => resize(width, height, false);
            child.resizeBy = (width, height) => resize(width, height, true);
            const nested = new child.EventTarget();
            Object.defineProperty(nested, 'window', {get:() => null});
            nested.requestWindow = () => Promise.reject(new child.DOMException(
              'A Picture-in-Picture window cannot open another one.', 'NotAllowedError'));
            Object.defineProperty(child, 'documentPictureInPicture', {configurable:true, value:nested});
            // about:blank normally inherits this base from its opener. Keep
            // relative resources correct on WebKit versions that omit it.
            if (child.document.baseURI.startsWith('about:')) {
              const base = child.document.createElement('base');
              base.href = document.baseURI;
              child.document.head.prepend(base);
            }
            prepared.add(child);
            const endedDocument = () => {
              lifecycle.disconnect();
              if (current === child) current = null;
              // Let all site pagehide listeners restore their nodes before
              // the replacement's promise can continue site code.
              setTimeout(() => ended.add(child), 0);
            };
            function armLifecycle() {
              child.removeEventListener('pagehide', endedDocument);
              child.addEventListener('pagehide', endedDocument, {once:true});
            }
            // document.open/write reuses Document but removes Window event
            // listeners. Its root mutations let us restore this listener.
            const lifecycle = new child.MutationObserver(armLifecycle);
            lifecycle.observe(child.document, {childList:true});
            armLifecycle();
          }
          api.requestWindow = function(options = {}) {
            try {
              if (!window.isSecureContext || window.top !== window || ownedMedia())
                throw new DOMException('Document Picture-in-Picture is unavailable for this page.', 'NotAllowedError');
              if (options === null) options = {};
              if (typeof options !== 'object' && typeof options !== 'function')
                throw new TypeError('Picture-in-Picture options must be a dictionary.');
              const width = dimension(options.width), height = dimension(options.height);
              if ((width === 0) !== (height === 0))
                throw new RangeError('Specify both Picture-in-Picture dimensions, or neither.');
              if (!navigator.userActivation?.isActive)
                throw new DOMException('Opening Picture-in-Picture requires a user gesture.', 'NotAllowedError');
              const previous = current, waitForPrevious = previous && prepared.has(previous);
              if (previous && !previous.closed) previous.close();
              const token = Array.from(crypto.getRandomValues(new Uint32Array(4)), n => n.toString(16)).join('-');
              const address = 'about:blank#__yab_document_pip=' + token +
                '&disallowReturnToOpener=' + (options.disallowReturnToOpener ? '1' : '0') +
                '&preferInitialWindowPlacement=' + (options.preferInitialWindowPlacement ? '1' : '0');
              // Synchronous: window.open consumes the engine's real gesture.
              const child = originalOpen(address, '_blank', 'popup,width=' + (width || 480) + ',height=' + (height || 320));
              if (!child) throw new DOMException('Picture-in-Picture could not be opened.', 'NotAllowedError');
              current = child;
              const started = performance.now();
              return new Promise((resolve, reject) => {
                function ready() {
                  if (child.closed || current !== child) {
                    reject(new DOMException('Picture-in-Picture closed before it was ready.', 'AbortError'));
                    return;
                  }
                  if (performance.now() - started > 10000) {
                    child.close();
                    reject(new DOMException('Picture-in-Picture did not finish opening.', 'AbortError'));
                    return;
                  }
                  // WebKit does not send didFinish for its initial empty
                  // document. Wait for the requested engine URL and DOM.
                  let loaded;
                  try { loaded = child.location.href === address && child.document.readyState === 'complete'; }
                  catch (error) { child.close(); reject(error); return; }
                  if (!loaded || (waitForPrevious && !ended.has(previous))) {
                    setTimeout(ready, 10);
                    return;
                  }
                  try {
                    prepare(child);
                    resolve(child);
                    setTimeout(() => {
                      const event = new Event('enter');
                      Object.defineProperty(event, 'window', {value:child});
                      api.dispatchEvent(event);
                    }, 0);
                  } catch (error) { child.close(); reject(error); }
                }
                ready();
              });
            } catch (error) { return Promise.reject(error); }
          };
          Object.defineProperty(window, 'documentPictureInPicture', {configurable:true, value:api});
          window.addEventListener('pagehide', () => { if (current && !current.closed) current.close(); });
        })();
        """#
    }
}
