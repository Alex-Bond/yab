import Foundation

/// Installed only in a boost's isolated content world. DOM loads cannot use
/// fetch's redirect, credentials and header policy, so code must use fetch and
/// render its response instead. The site's own world keeps its normal APIs.
enum BoostNetwork {
    static let script = #"""
    const definePolicy = Object.defineProperty;
    if (window.__yabBoostNetworkPolicy === undefined) definePolicy(window,'__yabBoostNetworkPolicy',{value:BOOST_POLICY,writable:false,configurable:false});
    const functionPrototype = Object.getPrototypeOf(function(){});
    const networkError = () => { throw Error('Use fetch for boost network requests.'); };
    const define = Object.defineProperty;
    const descriptor = Object.getOwnPropertyDescriptor;
    const lock = (target, key, value) => {
      if (!target || descriptor(target, key)?.configurable === false) return;
      // Shadowing a WebIDL method on window alone can leave its native
      // implementation reachable on Window.prototype.
      let owner=Object.getPrototypeOf(target);
      while(owner && !descriptor(owner,key)) owner=Object.getPrototypeOf(owner);
      if(owner && descriptor(owner,key)?.configurable && owner[key]===target[key]) define(owner,key,{value,writable:false,configurable:false});
      define(target, key, {value, writable:false, configurable:false});
    };
    const method = (target, key, wrap) => {
      const old = target?.[key];
      if (typeof old === 'function' && descriptor(target, key)?.configurable !== false) lock(target, key, wrap(old));
    };
    // These APIs send without fetch, or create a realm with fresh network APIs.
    for (const name of ['XMLHttpRequest','WebSocket','EventSource','Worker','SharedWorker','WebTransport','Audio','FontFace','RTCPeerConnection','webkitRTCPeerConnection']) {
      lock(window, name, class { constructor() { networkError(); } });
    }
    lock(window, 'open', networkError);
    // Constructors and string timers can otherwise import code without a DOM
    // script element. Cover ordinary, async and generator constructors.
    const dynamicCode = () => { throw Error('Dynamic code is not available to boosts.'); };
    for (const fn of [function(){}, async function(){}, function*(){}, async function*(){}]) {
      lock(Object.getPrototypeOf(fn), 'constructor', dynamicCode);
    }
    lock(window, 'Function', dynamicCode); lock(window, 'eval', dynamicCode);
    for (const key of ['setTimeout','setInterval']) method(window,key,old=>function(fn,...args) {
      if(typeof fn !== 'function') dynamicCode();
      return old.call(this,fn,...args);
    });
    method(Navigator.prototype, 'sendBeacon', () => networkError);
    method(window.ServiceWorkerContainer?.prototype, 'register', () => networkError);

    const originalFetch = window.fetch.bind(window);
    const NativeRequest = window.Request;
    const requestURL = functionPrototype.call.bind(descriptor(NativeRequest.prototype,'url').get);
    const hosts = BOOST_HOSTS;
    const declared = url => url.protocol === 'https:' && url.port === '' && !url.username && !url.password && hosts.includes(url.hostname);
    const reach = value => {
      const url = new URL(value, location.href);
      if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || (url.origin !== location.origin && !declared(url)))
        throw Error('Boost network requests must stay on this origin or the plugin’s hosts.');
      return url;
    };
    lock(window, 'fetch', (input, options) => {
      const url = reach(input instanceof NativeRequest ? requestURL(input) : input);
      // Pass the validated URL, never an object that can stringify differently
      // the second time. Snapshot Request options before forcing redirect:error.
      if (url.origin === location.origin) {
        const request = input instanceof NativeRequest ? new NativeRequest(input, options) : null;
        return originalFetch(request || url.href, {...(request ? {} : options), redirect:'error'});
      }
      if (input instanceof NativeRequest) throw Error('Pass a URL to fetch another host.');
      const method = String(options?.method || 'GET').toUpperCase(), body = options?.body;
      if (!['GET','POST'].includes(method)) throw Error('Other hosts take GET or POST.');
      if (body !== undefined && (method !== 'POST' || typeof body !== 'string')) throw Error('Send JSON text to other hosts with POST.');
      const headers = {'Accept':'application/json'};
      if (body !== undefined) headers['Content-Type'] = 'application/json';
      return originalFetch(url.href, {method, headers, body, signal:options?.signal, credentials:'omit', redirect:'error', referrerPolicy:'no-referrer', cache:'no-store', mode:'cors'});
    });

    // Validate synchronously before the native DOM operation. A MutationObserver
    // is too late: WebKit can start a request before its callback runs.
    const noCSSLoads = text => {
      if (/\\|url\s*\(|@import|image-set\s*\(/i.test(String(text))) networkError();
    };
    const inertImage = value => /^(?:data:image\/(?:png|jpeg|gif|webp|avif);base64,|blob:)/i.test(String(value));
    const getter = (proto,key) => {
      let d;
      while(proto && !d) { d=descriptor(proto,key); proto=Object.getPrototypeOf(proto); }
      if(typeof d?.get!=='function') throw Error('Missing DOM getter: '+key);
      return functionPrototype.call.bind(d.get);
    };
    const elementName=getter(Element.prototype,'localName'), nodeType=getter(Node.prototype,'nodeType');
    const children=getter(Node.prototype,'childNodes'), attributes=getter(Element.prototype,'attributes');
    const textContent=getter(Node.prototype,'textContent'), templateContent=getter(HTMLTemplateElement.prototype,'content');
    const attributeName=getter(Attr.prototype,'name'), attributeValue=getter(Attr.prototype,'value'), ownerElement=getter(Attr.prototype,'ownerElement');
    const parentElement=getter(Node.prototype,'parentElement');
    const tagOf = node => node && nodeType(node)===1 ? elementName(node).toLowerCase() : '';
    const inStyle = node => tagOf(node)==='style' || tagOf(parentElement(node))==='style';
    const closest=functionPrototype.call.bind(Element.prototype.closest), eventType=getter(Event.prototype,'type'), rangeStart=getter(Range.prototype,'startContainer');
    const attributeAt=functionPrototype.call.bind(NamedNodeMap.prototype.item);
    const eachChild=functionPrototype.call.bind(NodeList.prototype.forEach);
    const createElement=Document.prototype.createElement.bind(document);
    const attribute = (element, name, value) => {
      name = String(name).toLowerCase().split(':').pop();
      if (name.startsWith('on') || name === 'srcdoc' || name === 'ping') networkError();
      if (name === 'style') noCSSLoads(value);
      const tag = elementName(element).toLowerCase();
      if (['script','iframe','frame','object','embed','base','meta','animate','set','animatemotion','animatetransform'].includes(tag)) networkError();
      if (['src','srcset','href','data','action','formaction','poster','background','codebase','manifest','xlink:href'].includes(name) && String(value)) {
        if (tag === 'img' && name === 'src' && inertImage(value)) return;
        // A link may be displayed; a synthetic click is checked separately.
        if (['a','area'].includes(tag) && name === 'href' && !/^\s*(?:javascript|data|blob):/i.test(String(value))) return;
        // Local SVG references do not load a document or another resource.
        if (name === 'href' && String(value).startsWith('#')) return;
        networkError();
      }
    };
    const tree = node => {
      if (!node || typeof node !== 'object') return;
      if (nodeType(node) === 1) {
        const tag=elementName(node).toLowerCase();
        if (['script','iframe','frame','object','embed','base','meta','animate','set','animatemotion','animatetransform'].includes(tag)) networkError();
        const attrs=attributes(node);
        for(let i=0;;i++) { const a=attributeAt(attrs,i); if(!a) break; attribute(node,attributeName(a),attributeValue(a)); }
        if (tag === 'style') noCSSLoads(textContent(node));
        if (tag === 'template') tree(templateContent(node));
      }
      eachChild(children(node),tree);
    };
    method(Element.prototype, 'setAttribute', old => function(name, value) { name=String(name); value=String(value); attribute(this,name,value); return old.call(this,name,value); });
    method(Element.prototype, 'setAttributeNS', old => function(ns,name,value) { ns=ns == null ? null : String(ns); name=String(name); value=String(value); attribute(this,name,value); return old.call(this,ns,name,value); });
    method(Element.prototype, 'setAttributeNode', old => function(a) { attribute(this,attributeName(a),attributeValue(a)); return old.call(this,a); });
    method(Element.prototype, 'setAttributeNodeNS', old => function(a) { attribute(this,attributeName(a),attributeValue(a)); return old.call(this,a); });
    // IDL setters can load without going through setAttribute in JavaScript.
    const setter = (proto,key,check) => {
      const d = proto && descriptor(proto,key);
      if (!d?.set || !d.configurable) return;
      define(proto,key,{...d,configurable:false,set(value) { value=String(value); check(this,value); return d.set.call(this,value); }});
    };
    const constructors = ['HTMLImageElement','HTMLSourceElement','HTMLMediaElement','HTMLVideoElement','HTMLInputElement','HTMLScriptElement','HTMLLinkElement','HTMLIFrameElement','HTMLFrameElement','HTMLObjectElement','HTMLEmbedElement','HTMLFormElement','HTMLButtonElement','HTMLAnchorElement','HTMLAreaElement','HTMLBaseElement','HTMLMetaElement','HTMLBodyElement','HTMLTableElement','HTMLTableCellElement'];
    for (const name of constructors) for (const key of ['src','srcset','href','data','action','formAction','poster','background','srcdoc','ping','codeBase','content','httpEquiv']) {
      setter(window[name]?.prototype,key,(e,v)=>attribute(e,key,v));
    }
    setter(Attr.prototype,'value',(a,v)=>{ if(ownerElement(a)) attribute(ownerElement(a),attributeName(a),v); });
    setter(Node.prototype,'nodeValue',(n,v)=>{ if(nodeType(n)===2 && ownerElement(n)) attribute(ownerElement(n),attributeName(n),v); if(tagOf(parentElement(n))==='style') networkError(); });
    for (const name of ['HTMLIFrameElement','HTMLFrameElement','HTMLObjectElement']) for (const key of ['contentWindow','contentDocument']) {
      const proto=window[name]?.prototype, d=proto && descriptor(proto,key);
      if(d?.configurable) define(proto,key,{...d,configurable:false,get:networkError});
    }
    for (const key of ['appendChild','insertBefore','replaceChild']) method(Node.prototype,key,old=>function(node,...rest) { tree(node); if(inStyle(this)) networkError(); return old.call(this,node,...rest); });
    for (const proto of [Element.prototype,Document.prototype,DocumentFragment.prototype,CharacterData.prototype]) for (const key of ['append','prepend','replaceChildren','before','after','replaceWith']) {
      method(proto,key,old=>function(...nodes) { nodes.forEach(tree); if(inStyle(this)) networkError(); return old.apply(this,nodes); });
    }
    // Parse markup in an inert template, then check before it touches live DOM.
    const html = descriptor(Element.prototype,'innerHTML');
    const checkHTML = value => { const t=createElement('template'); html.set.call(t,String(value)); tree(templateContent(t)); };
    for (const proto of [Element.prototype,ShadowRoot.prototype]) for (const key of ['innerHTML','outerHTML']) setter(proto,key,(e,v)=>{ if(tagOf(e)==='style') noCSSLoads(v); checkHTML(v); });
    method(Element.prototype,'insertAdjacentHTML',old=>function(where,value) { value=String(value); if(inStyle(this)) networkError(); checkHTML(value); return old.call(this,where,value); });
    method(Element.prototype,'insertAdjacentText',old=>function(where,value) { if(inStyle(this)) networkError(); return old.call(this,where,value); });
    method(Element.prototype,'insertAdjacentElement',old=>function(where,node) { if(inStyle(this)) networkError(); tree(node); return old.call(this,where,node); });
    method(Range.prototype,'insertNode',old=>function(node) { if(inStyle(rangeStart(this))) networkError(); tree(node); return old.call(this,node); });
    method(Range.prototype,'createContextualFragment',old=>function(value) { value=String(value); checkHTML(value); return old.call(this,value); });
    method(Node.prototype,'removeChild',old=>function(node) { if(inStyle(this)) networkError(); return old.call(this,node); });
    for(const proto of [Element.prototype,CharacterData.prototype]) method(proto,'remove',old=>function() { if(tagOf(parentElement(this))==='style') networkError(); return old.call(this); });
    for (const key of ['setHTML','setHTMLUnsafe']) method(Element.prototype,key,old=>function(value,...args) { value=String(value); if(tagOf(this)==='style') noCSSLoads(value); checkHTML(value); return old.call(this,value,...args); });
    method(Document.prototype,'execCommand',old=>function(command,showUI,value) {
      command=String(command); value=String(value);
      if(command.toLowerCase()==='inserthtml') checkHTML(value);
      if(command.toLowerCase()==='insertimage') networkError();
      return old.call(this,command,showUI,value);
    });
    setter(window.SVGAnimatedString?.prototype,'baseVal',()=>networkError());
    for (const name of ['HTMLObjectElement','HTMLEmbedElement']) method(window[name]?.prototype,'getSVGDocument',()=>networkError);
    setter(CharacterData.prototype,'data',(n,v)=>{ if(tagOf(parentElement(n))==='style') networkError(); });
    for (const key of ['appendData','insertData','replaceData','deleteData']) method(CharacterData.prototype,key,old=>function(...args) {
      if(tagOf(parentElement(this))==='style') networkError();
      return old.apply(this,args);
    });
    for (const key of ['write','writeln']) method(Document.prototype,key,()=>networkError);
    // CSS named properties may be WebKit custom bindings rather than own
    // prototype setters. Guard the returned declaration as well as CSSOM calls.
    const styleProxies = new WeakMap();
    for (const name of ['HTMLElement','SVGElement','CSSStyleRule','CSSKeyframeRule','CSSFontFaceRule','CSSPageRule']) {
      const proto=window[name]?.prototype, d=proto && descriptor(proto,'style');
      if(!d?.get || !d.configurable) continue;
      define(proto,'style',{...d,configurable:false,
        get() {
          const style=d.get.call(this);
          let proto=Object.getPrototypeOf(style);
          while(proto && proto!==Object.prototype) { Object.freeze(proto); proto=Object.getPrototypeOf(proto); }
          if(!styleProxies.has(style)) styleProxies.set(style,new Proxy(style,{
            get(target,key) { const value=Reflect.get(target,key,target); return typeof value==='function' ? value.bind(target) : value; },
            set(target,key,value) { value=String(value); noCSSLoads(value); return Reflect.set(target,key,value,target); },
            // A user getter or bound method could otherwise receive and
            // return the native declaration, escaping this proxy.
            defineProperty:networkError,
            setPrototypeOf:networkError
          }));
          return styleProxies.get(style);
        },
        ...(d.set ? {set(value) { value=String(value); noCSSLoads(value); d.set.call(this,value); }} : {})
      });
    }
    for (const key of ['set','append']) method(window.StylePropertyMap?.prototype,key,old=>function(...args) { args=args.map(String); args.forEach(noCSSLoads); return old.apply(this,args); });
    // CSSOM and style.textContent otherwise bypass stylesheet package validation.
    for (const key of Object.getOwnPropertyNames(CSSStyleDeclaration.prototype)) setter(CSSStyleDeclaration.prototype,key,(_,v)=>noCSSLoads(v));
    method(CSSStyleDeclaration.prototype,'setProperty',old=>function(name,value,...rest) { value=String(value); noCSSLoads(value); return old.call(this,name,value,...rest); });
    for (const key of ['insertRule','replace','replaceSync','addRule']) method(CSSStyleSheet.prototype,key,old=>function(...args) { args=args.map(String); args.forEach(noCSSLoads); return old.apply(this,args); });
    setter(Node.prototype,'textContent',(n,v)=>{
      if(nodeType(n)===2 && ownerElement(n)) attribute(ownerElement(n),attributeName(n),v);
      if(tagOf(n)==='style') noCSSLoads(v);
      else if(tagOf(parentElement(n))==='style') networkError();
      if(tagOf(n)==='script') networkError();
    });
    setter(HTMLElement.prototype,'innerText',(n,v)=>{ if(tagOf(n)==='style') noCSSLoads(v); if(tagOf(n)==='script') networkError(); });
    for (const key of ['submit','requestSubmit']) method(HTMLFormElement.prototype,key,()=>networkError);
    // A site-action grant is separate from fetch hosts. Use native getters so
    // own properties, adopted nodes and foreign documents cannot spoof scope.
    const actionMatches = BOOST_MATCHES, clicks = BOOST_CLICKS;
    const ownerDocument = getter(Node.prototype,'ownerDocument'), documentURL = getter(Document.prototype,'URL');
    const baseURI = getter(Node.prototype,'baseURI'), getAttribute = functionPrototype.call.bind(Element.prototype.getAttribute);
    const buttonForm = getter(HTMLButtonElement.prototype,'form'), inputForm = getter(HTMLInputElement.prototype,'form');
    const actionAllowed = element => {
      if (!clicks || !element || nodeType(element)!==1 || ownerDocument(element)!==document) networkError();
      const url = new URL(documentURL(document));
      if (!actionMatches.some(pattern => { const u=new URL(pattern); return u.origin===url.origin && glob(u.pathname,url.pathname); })) networkError();
      const link = closest(element,'a,area');
      if (link) {
        const href=getAttribute(link,'href');
        const target=getAttribute(link,'target');
        if (getAttribute(link,'ping') || getAttribute(link,'download')!==null || (target && target.toLowerCase()!=='_self')) networkError();
        if (href) { const destination=new URL(href,baseURI(link)); if(destination.origin!==url.origin || destination.username || destination.password) networkError(); }
      }
      const control=closest(element,'button,input');
      if (control) {
        const tag=tagOf(control), form=tag==='button' ? buttonForm(control) : inputForm(control);
        const type=(getAttribute(control,'type') || (tag==='button' ? 'submit' : 'text')).toLowerCase();
        if (form && (tag==='button' ? type!=='button' && type!=='reset' : ['submit','image'].includes(type))) networkError();
      }
    };
    // Deliver site handlers an already-canceled event. Calling native click
    // and canceling later is unsafe: a detached link, a shadow tree or an
    // earlier stopImmediatePropagation can avoid the canceling listener.
    // No native default activation (navigation, form submission, new window).
    const dispatch=functionPrototype.call.bind(EventTarget.prototype.dispatchEvent);
    const preventDefault=functionPrototype.call.bind(Event.prototype.preventDefault);
    const cancelable=getter(Event.prototype,'cancelable'), NativeMouseEvent=window.MouseEvent;
    method(HTMLElement.prototype,'click',()=>function() {
      actionAllowed(this);
      const event=new NativeMouseEvent('click',{bubbles:true,cancelable:true,composed:true,view:window});
      preventDefault(event); dispatch(this,event);
    });
    method(EventTarget.prototype,'dispatchEvent',()=>function(event) {
      if(eventType(event)==='submit') networkError();
      actionAllowed(this);
      if(!cancelable(event)) networkError();
      preventDefault(event); return dispatch(this,event);
    });
    // The guard and package share this world's intrinsics. Prevent a script
    // from changing includes/test/call or a URL getter to falsify its checks or
    // intercept a native receiver passed by a wrapper. Objects and arrays the
    // package creates are still mutable.
    for (const name of ['Object','Array','String','RegExp','Function','URL','Request','Set','WeakMap','CSSStyleDeclaration']) {
      const value=window[name];
      if(value?.prototype) Object.freeze(value.prototype);
      if(value) { Object.freeze(value); lock(window,name,value); }
    }
    for(const iterator of [[][Symbol.iterator](), new Set()[Symbol.iterator](), ''[Symbol.iterator]()]) {
      let proto=Object.getPrototypeOf(iterator);
      while(proto && proto!==Object.prototype) { Object.freeze(proto); proto=Object.getPrototypeOf(proto); }
    }
    Object.freeze(Object.getPrototypeOf(function(){}));
    Object.freeze(Reflect);
    lock(window,'Reflect',Reflect);
    // Do not restore native APIs on Undo. A retained callback must remain guarded.
    """#
}
