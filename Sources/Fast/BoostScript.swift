import Foundation

/// One isolated world per boost. The package stays portable; the wrapper owns
/// its styles, observers, listeners and timers so a new trial can replace it.
enum BoostScript {
    static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return text.replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
    // display:contents has no box of its own; its rendered children still count.
    static let visibility = #"function visible(e) { const s=getComputedStyle(e); if(s.display==='none'||s.visibility==='hidden') return false; return s.display==='contents' ? Array.from(e.children).some(visible) : e.getClientRects().length>0; }"#
    static let remove = "window.__yabBoost?.stop(); true"
    static let report = "window.__yabBoost?.report() ?? {error: 'The boost did not run on this page.'}"
    static let sensitive = #"""
    (() => !['http:', 'https:'].includes(location.protocol) ||
      /(?:^|\/)(?:login|signin|sign-in|auth|oauth|checkout|payment|wallet)(?:\/|$)/i.test(location.pathname) ||
      !!document.querySelector('input[type="password"], input[autocomplete^="cc-"], input[autocomplete="one-time-code"]'))()
    """#

    static func source(_ package: BoostPackage) -> String {
        let checks: [[String: Any]] = package.checks.map { check in
            var value: [String: Any] = ["line": check.line, "path": check.path, "kind": check.kind.rawValue, "selector": check.selector]
            if let count = check.count { value["count"] = count }
            if let words = check.words { value["words"] = words }
            return value
        }
        let content = package.content.enumerated().map { index, entry in
            let css = entry.css.compactMap { package.files[$0] }.joined(separator: "\n")
            let js = entry.js.compactMap { package.files[$0] }.joined(separator: "\n;\n")
            return """
            if (\(json(entry.matches)).some(matches)) {
              const style = document.createElement('style'); style.dataset.yabBoost = \(json(package.id));
              style.textContent = \(json(css)); (document.head || document.documentElement).append(style); styles.push(style);
              \(js.isEmpty ? "" : "try { const cleanup = scripts[\(index)](api); if (typeof cleanup === 'function') cleanups.push(cleanup); } catch(e) { errors.push(String(e)); }")
            }
            """
        }.joined(separator: "\n")
        // Arguments are created in global scope, outside the privileged wrapper.
        let scripts = package.content.map { entry in
            "function(boost) {\n" + entry.js.compactMap { package.files[$0] }.joined(separator: "\n;\n") + "\n}"
        }.joined(separator: ",\n")
        let checkScript = "function(boost) {\n" + (package.files["checks.js"] ?? "") + "\n}"
        // A world's native patches cannot be uninstalled. Permission changes
        // take a fresh document, as kept code updates already do. Fail closed
        // rather than run new code under an earlier version's grant.
        let networkPolicy = json(["hosts": package.plugin.hosts, "actions": package.plugin.siteActions,
                                  "matches": package.content.flatMap(\.matches)])
        return #"""
        /* yab-boost: \#(package.id) */
        ((scripts, checkScript) => {
          if (window.__yabBoostNetworkPolicy !== undefined && window.__yabBoostNetworkPolicy !== \#(json(networkPolicy)))
            return {error: 'Reload this page to change boost permissions.'};
          window.__yabBoost?.stop();
          if (\#(sensitive)) return {error: 'Boosts do not run on sign-in or payment pages.'};
          const sites = \#(json(package.sites)), checks = \#(json(checks));
          if (!sites.includes('<all_urls>') && !sites.includes(location.hostname)) return {error: 'This site is outside the boost.'};
          const styles = [], cleanups = [], errors = [], scriptedChecks = {}, started = performance.now();
          let stopped = false;
          const glob = (pattern, value) => new RegExp('^' + pattern.split('*').map(x => x.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('.*') + '$').test(value);
          const matches = pattern => { if(pattern === '<all_urls>') return ['http:', 'https:'].includes(location.protocol); const u = new URL(pattern); return u.protocol === location.protocol && u.hostname === location.hostname && glob(u.pathname, location.pathname); };
          const visible = \#(visibility);
          const api = Object.freeze({
            check(name, fn) { if(typeof fn !== 'function') throw Error('A check must be a function'); scriptedChecks[name] = fn; },
            on(target, event, fn, options) { target.addEventListener(event, fn, options); cleanups.push(() => target.removeEventListener(event, fn, options)); },
            observe(target, fn, options) {
              if (!target || target === document || target === document.documentElement) throw Error('Observe the closest stable parent.');
              let frame; const observer = new MutationObserver(records => {
                cancelAnimationFrame(frame); frame = requestAnimationFrame(() => { if (!stopped) fn(records); });
              }); observer.observe(target, options || {childList:true});
              cleanups.push(() => { observer.disconnect(); cancelAnimationFrame(frame); }); return observer;
            },
            cleanup(fn) { if (typeof fn === 'function') cleanups.push(fn); }
          });
          \#(package.rung == .look ? "" : BoostNetwork.script
              .replacingOccurrences(of: "BOOST_HOSTS", with: json(package.plugin.hosts))
              .replacingOccurrences(of: "BOOST_CLICKS", with: package.plugin.siteActions.contains("clicks") ? "true" : "false")
              .replacingOccurrences(of: "BOOST_MATCHES", with: json(package.content.flatMap(\.matches)))
              .replacingOccurrences(of: "BOOST_POLICY", with: json(networkPolicy)))
          function report() {
            const checkedAt = performance.now();
            const results = checks.map(c => {
              if (!glob(c.path, location.pathname)) return {line:c.line, state:'skipped', reason:'Another page'};
              try {
                if(c.kind === 'script') { const answer=scriptedChecks[c.selector]?.(); return {line:c.line,state:answer === true ? 'pass':'fail',reason:typeof answer === 'boolean' ? '' : 'Checks must return a boolean synchronously'}; }
                const all = Array.from(document.querySelectorAll(c.selector)), shown = all.filter(visible);
                let pass = false, found = shown.length;
                if (c.kind === 'none') pass = shown.length === 0;
                if (c.kind === 'some') pass = shown.length > 0;
                if (c.kind === 'text') pass = shown.some(e => e.textContent.includes(c.words));
                if (c.kind === 'rows') {
                  const children = shown.flatMap(e => Array.from(e.children).filter(visible));
                  const top = children.length ? Math.min(...children.map(e => e.getBoundingClientRect().top)) : NaN;
                  found = children.filter(e => Math.abs(e.getBoundingClientRect().top - top) < 3).length;
                  pass = found === c.count;
                }
                return {line:c.line, state:pass ? 'pass' : 'fail', found};
              } catch(e) { return {line:c.line, state:'fail', error:String(e)}; }
            });
            const matched = {};
            function rules(list) { for (const rule of list) {
              if (rule.selectorText) { try { matched[rule.selectorText] = document.querySelectorAll(rule.selectorText).length; } catch(e) { matched[rule.selectorText] = -1; } }
              if (rule.cssRules) rules(rule.cssRules);
            } }
            for (const style of styles) { try { if (style.sheet) rules(style.sheet.cssRules); } catch(e) { errors.push(String(e)); } }
            return {loaded: !stopped, matched, checks:results, errors:errors.slice(0,20), milliseconds:performance.now()-started, checkMilliseconds:performance.now()-checkedAt};
          }
          function stop() {
            stopped = true;
            for (const cleanup of cleanups.reverse()) { try { cleanup(); } catch(e) {} }
            for (const style of styles) style.remove();
          }
          window.__yabBoost = {stop, report};
          \#(package.plugin.permissions.isEmpty ? "" : BoostAPI.script)
          \#(content)
          try { checkScript(api); } catch(e) { errors.push(String(e)); }
          // A site may navigate to its login without loading a new document.
          const timer = setInterval(() => { if (!stopped && (\#(sensitive))) stop(); }, 1000);
          cleanups.push(() => clearInterval(timer));
          return report();
        })([\#(scripts)], \#(checkScript))
        """#
    }
}
