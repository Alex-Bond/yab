import Foundation
import WebKit

/// A transient, main-document handoff. Never persisted, shared between tabs,
/// used on redirects, or interpreted as portable native interaction state.
@MainActor
final class EngineSwitchDocument {
    let url: URL
    let script: WKUserScript

    init(url: URL, json: String) throws {
        guard json.utf8.count <= 512 * 1024,
              let data = json.data(using: .utf8),
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["url"] as? String == url.absoluteString else { throw EngineSwitchDocumentError.invalidSnapshot }
        self.url = url
        // Embed as a JSON string, not executable source or an HTML fragment.
        let encoded = String(decoding: try JSONEncoder().encode(json), as: UTF8.self)
        let source = """
        (() => {
          const state = JSON.parse(\(encoded));
          if (window !== top || location.href !== state.url) return;
          const restoreStorage = (name, entries) => {
            if (entries === null) return;
            const store = window[name];
            store.clear();
            for (const [key, value] of entries) store.setItem(key, value);
          };
          restoreStorage('localStorage', state.local);
          restoreStorage('sessionStorage', state.session);
          const restoreView = () => {
            const controls = Array.from(document.querySelectorAll('input,textarea,select'));
            for (const field of state.fields) {
              const node = controls[field.index];
              if (!node || node.tagName !== field.tag || node.type !== field.type ||
                  node.id !== field.id || node.name !== field.name) continue;
              if (field.selected) {
                Array.from(node.options).forEach((option, i) => { option.selected = field.selected.includes(i); });
              } else if (field.type === 'checkbox' || field.type === 'radio') node.checked = field.checked;
              else node.value = field.value;
            }
            requestAnimationFrame(() => window.scrollTo(state.x, state.y));
          };
          if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', restoreView, {once:true});
          else restoreView();
        })();
        """
        script = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient)
    }

    func removeScript(from page: any PageHandle) {
        if let web = page.webKit {
            let controller = web.configuration.userContentController
            // Keep scripts installed by other owners. Re-arming the whole
            // tab at load finish could remove them or use a held old URL.
            PageScripts.fit(controller, controller.userScripts.filter { $0 !== script })
        } else {
            (page as? ChromiumPage)?.refreshEngineSwitchScripts()
        }
    }

    static func capture(from page: any PageHandle, at url: URL, within seconds: TimeInterval = 3) async throws -> EngineSwitchDocument? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), page.url == url else { return nil }
        let body = """
        if (location.href !== expected || window !== top) return null;
        const entries = name => {
          try { const store = window[name]; return Array.from({length:store.length}, (_, i) => store.key(i)).map(key => [key, store.getItem(key)]); }
          catch { return null; }
        };
        const fields = Array.from(document.querySelectorAll('input,textarea,select')).flatMap((node,index) => {
          if (node.type === 'password' || node.type === 'file' || node.type === 'hidden' ||
              /password|cc-|one-time-code/i.test(node.autocomplete || '')) return [];
          return [{index,tag:node.tagName,type:node.type,id:node.id,name:node.name,value:node.value,
            checked:node.checked || false,selected:node.tagName === 'SELECT' ? Array.from(node.options)
              .flatMap((option,i) => option.selected ? [i] : []) : null}];
        });
        return JSON.stringify({url:location.href,local:entries('localStorage'),session:entries('sessionStorage'),
          fields,x:scrollX,y:scrollY});
        """
        // A hung source page must not prevent switching away from it. The
        // callback can still arrive after timeout/retirement; answer once.
        let value: Any? = await withCheckedContinuation { continuation in
            var answered = false
            let deadline = Timer(timeInterval: seconds, repeats: false) { _ in
                MainActor.assumeIsolated {
                    guard !answered else { return }
                    answered = true
                    continuation.resume(returning: nil)
                }
            }
            RunLoop.main.add(deadline, forMode: .common)
            page.call(body, arguments: ["expected": url.absoluteString], in: .client, gesture: false) { result in
                guard !answered else { return }
                answered = true
                deadline.invalidate()
                continuation.resume(returning: try? result.get())
            }
        }
        guard let json = value as? String else { return nil }
        return try EngineSwitchDocument(url: url, json: json)
    }
}

enum EngineSwitchDocumentError: Error {
    case invalidSnapshot
}
