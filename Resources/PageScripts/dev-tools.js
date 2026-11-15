(function () {
  if (window.__yab) { return; }
  var Y = window.__yab = { ready: false, log: [] };
  document.documentElement.classList.add('yab-hosted');
  function post(m) { try { webkit.messageHandlers.yabInspector.postMessage(m); } catch (e) {} }
  // Yab supplies the head both in the card and in the adopted native window.
  // Keep WebKit's own head hidden in either attachment mode.
  var css = [
    ':root { --yab-accent: -apple-system-control-accent; --yab-soft: color-mix(in srgb, -apple-system-control-accent 16%, transparent); --yab-vink: -apple-system-control-accent; }',
    ':root, body { --selected-background-color: var(--yab-accent) !important; --selected-background-color-active: var(--yab-accent) !important; --selected-background-color-unfocused: var(--yab-soft) !important; --background-color-selected: var(--yab-soft) !important; --selected-text-background-color: var(--yab-soft) !important; --glyph-color-active: var(--yab-accent) !important; --glyph-color-active-pressed: var(--yab-vink) !important; --link-text-color: var(--yab-vink) !important; }',
    '@media (prefers-color-scheme: light) { body { --background-color: #fff; --background-color-content: #fff; --panel-background-color: #fafafb; --border-color: #ececf0; --separator-color: #ececf0; } .tree-outline.dom li:not(.selected) .html-tag-name { color: #881280 !important; } .tree-outline.dom li:not(.selected) .html-attribute-name { color: #994500 !important; } .tree-outline.dom li:not(.selected) .html-attribute-value { color: #1a1aa6 !important; } }',
    '@media (prefers-color-scheme: dark) { body { --background-color: #1d1c22; --background-color-content: #1d1c22; --panel-background-color: #19181e; --border-color: rgba(236, 235, 240, 0.1); --separator-color: rgba(236, 235, 240, 0.1); } }',
    'body { font-family: -apple-system, system-ui !important; }',
    ':is(body.docked, .yab-hosted body) { display: flex !important; flex-direction: column !important; height: 100vh; background: transparent; }',
    ':is(body.docked, .yab-hosted body) #tab-bar, :is(body.docked, .yab-hosted body) #docked-resizer { display: none !important; }',
    ':is(body.docked, .yab-hosted body) #main { flex: 1 1 auto !important; min-height: 0 !important; top: 0 !important; }',
    ':is(body.docked, .yab-hosted body) #main > #content { flex: 1 1 auto; min-height: 0; }',
    '.tree-outline.dom, .console-messages, .console-prompt, .CodeMirror, .details-section .content { font-family: "SF Mono", Menlo, monospace !important; }',
    '.scope-bar > li { border-radius: 6px !important; }',
    '.radio.selected::before, .toggle.selected::before, .scope-bar li.selected::before, .radio-button-group .selected::before { background-color: var(--yab-soft) !important; }',
    '.toggle.selected, .radio.selected, .scope-bar li.selected { color: var(--yab-vink) !important; }',
    // WebKit gives every item of its bar the bar's whole height: as
    // high as its filter field instead.
    '.navigation-bar .item.yab-agent { align-self: center; height: 22px; box-sizing: border-box; font: 500 11px -apple-system, system-ui; padding: 0 8px; margin: 0 6px; border-radius: 5px; background: color-mix(in srgb, currentColor 9%, transparent); white-space: nowrap; cursor: default; }',
    '.navigation-bar .item.yab-agent:hover { background: color-mix(in srgb, currentColor 15%, transparent); }',
    '.console-item { position: relative; }',
    '.console-item > .yab-copy { display: none; position: absolute; right: 6px; top: 1px; z-index: 2; font: 500 11px -apple-system, system-ui; padding: 1px 7px; border-radius: 5px; background: var(--background-color, #fff); border: 1px solid color-mix(in srgb, currentColor 18%, transparent); cursor: default; }',
    '.console-item:hover > .yab-copy { display: inline-block; }'
  ].join('\n');
  function typeOf(item) {
    var o = item && item.representedObject;
    return (o && o.constructor && o.constructor.Type) || '';
  }
  // What the page said before yab's card was listening, handed over
  // as the inspector connects: errors and warnings, for the counts.
  // Hooked the moment WebKit's classes are there, before the console
  // is asked for what it kept.
  function hookConsole() {
    if (!window.WI || !WI.ConsoleManager) { setTimeout(hookConsole, 5); return; }
    if (WI.ConsoleManager.prototype.__yab) return;
    var added = WI.ConsoleManager.prototype.messageWasAdded;
    WI.ConsoleManager.prototype.__yab = true;
    var cleared = WI.ConsoleManager.prototype.messagesCleared;
    if (cleared) WI.ConsoleManager.prototype.messagesCleared = function () { Y.log = []; return cleared.apply(this, arguments); };
    WI.ConsoleManager.prototype.messageWasAdded = function (target, source, level, text, type, url, line, column, repeatCount, parameters, stackTrace, requestId, timestamp) {
      // Every line, for Everything in the Console (Y.lines).
      try {
        Y.log.push({ v: level, x: String(text || '').slice(0, 2000), u: url || '', l: line || 0, n: repeatCount || 1 });
        if (Y.log.length > 2000) Y.log.shift();
      } catch (e) {}
      try {
        // Only what came before yab's own script listened: Yab says when
        // (window.__yabCutoff); what came after, its script hears.
        var ts = +timestamp || 0;
        if (ts > 0 && ts < 1e11) ts *= 1000;
        var cutoff = window.__yabCutoff;
        if ((level === 'error' || level === 'warning') && !(cutoff !== undefined && !(ts < cutoff))) {
          var frames = Array.isArray(stackTrace) ? stackTrace : (stackTrace && stackTrace.callFrames) || [];
          var stack = frames.slice(0, 20).map(function (f) { return (f.functionName || '') + '@' + (f.url || '') + ':' + (f.lineNumber || 0) + ':' + (f.columnNumber || 0); }).join('\n');
          for (var n = 0; n < Math.max(1, repeatCount || 1) && n < 50; n++)
            post({ k: 'console', v: level, x: String(text || '').slice(0, 4000), u: url || '', l: line || 0, ts: ts, n: n, s: stack });
        }
      } catch (e) {}
      return added.apply(this, arguments);
    };
  }
  hookConsole();
  function start() {
    if (!window.WI || !WI.tabBrowser || !document.head) { setTimeout(start, 50); return; }
    var style = document.createElement('style');
    style.id = 'yab';
    style.textContent = css;
    document.head.appendChild(style);
    // A tab by the type WebKit gives it: elements, timeline, search...
    // Memory is Timelines with the memory instruments turned on.
    Y.show = function (type, memory) {
      try {
        if (memory) {
          var want = WI.timelineManager.enabledTimelineTypes.slice();
          [WI.TimelineRecord.Type.Memory, WI.TimelineRecord.Type.HeapAllocations].forEach(function (x) { if (want.indexOf(x) < 0) want.push(x); });
          WI.timelineManager.enabledTimelineTypes = want;
        }
        if (type === 'settings' && WI.showSettingsTab) { WI.showSettingsTab(); return type; }
        var bar = WI.tabBrowser.tabBar;
        var item = bar.tabBarItems.find(function (i) { return typeOf(i) === type; });
        if (item) { bar.selectedTabBarItem = item; return type; }
        var open = { elements: 'showElementsTab', console: 'showConsoleTab', sources: 'showSourcesTab', network: 'showNetworkTab', timeline: 'showTimelineTab', storage: 'showStorageTab', layers: 'showLayersTab' };
        if (open[type] && WI[open[type]]) { WI[open[type]](); return type; }
      } catch (e) {}
      return '';
    };
    // Device Settings, as WebKit's own popover sets them.
    Y.override = function (setting, value) {
      try { WI.mainTarget.PageAgent.overrideSetting(setting, value); return true; } catch (e) { return false; }
    };
    Y.drawer = function () { try { WI.toggleSplitConsole(); } catch (e) {} return Y.drawerShown(); };
    Y.drawerShown = function () { try { return WI.isShowingSplitConsole(); } catch (e) { return false; } };
    // What is picked in Elements, as markup, for the chat.
    Y.picked = function () {
      var node = WI.domManager && WI.domManager.inspectedNode;
      if (!node || node.nodeType() !== Node.ELEMENT_NODE) return Promise.resolve('');
      return node.getOuterHTML().then(function (html) { return String(html || '').slice(0, 6000); }, function () { return ''; });
    };
    // The console's every line, as Everything in the Console copies it.
    // Where yab's own listener on a local page wrapped the console, the
    // place is the listener's, which says nothing: left out.
    Y.lines = function () {
      return Y.log.map(function (m) {
        var at = m.u && m.u.indexOf('user-script') !== 0 ? '  (' + m.u + (m.l ? ':' + m.l : '') + ')' : '';
        return '[' + m.v + '] ' + m.x + (m.n > 1 ? ' ×' + m.n : '') + at;
      });
    };
    // Just connected, the inspector is still being handed what it kept:
    // read once that has had a moment.
    Y.linesSoon = function () {
      var wait = Math.max(0, 1200 - (Date.now() - Y.readyAt));
      return new Promise(function (done) { setTimeout(function () { done(Y.lines()); }, wait); });
    };
    // A file at a line, in Sources.
    Y.reveal = function (u, l, c) {
      try {
        var res = WI.networkManager.resourcesForURL(u), code = null;
        if (res) code = res.values ? res.values().next().value : res[0];
        if (!code && WI.debuggerManager && WI.debuggerManager.scriptsForURL) code = (WI.debuggerManager.scriptsForURL(u, WI.mainTarget) || [])[0];
        if (!code) return false;
        WI.showSourceCodeLocation(code.createSourceCodeLocation(Math.max(0, l - 1), Math.max(0, (c || 1) - 1)));
        return true;
      } catch (e) { return false; }
    };
    // Yab's own in WebKit's console: Copy for Agent in its bar, on a
    // message under the pointer, and in a message's menu.
    function agent(what, item) {
      var m = { k: 'agent', w: what };
      if (item) {
        var v = item.__messageView, text = v && v.toClipboardString ? v.toClipboardString(true) : item.innerText;
        // yab's own listener on a local page is no frame of the page's.
        m.x = String(text).split('\n').filter(function (l) { return l.indexOf('user-script') < 0; }).join('\n');
      }
      post(m);
    }
    function placeAgent() {
      var scope = document.querySelector('.navigation-bar .log-scope-bar');
      if (!scope || scope.parentElement.querySelector('.yab-agent')) return;
      var bar = scope.parentElement, b = document.createElement('div');
      b.className = 'item yab-agent'; b.textContent = 'Copy for Agent'; b.title = 'Copy the console for your agent';
      b.addEventListener('click', function (e) { e.stopPropagation(); agent('all'); });
      var flex = bar.querySelector('.flexible-space');
      bar.insertBefore(b, flex ? flex.nextSibling : null);
    }
    var queued = false;
    new MutationObserver(function () {
      if (queued) return;
      queued = true;
      // A timer, not a frame: loaded while the card showed yab's own
      // list, the inspector's page is hidden and draws no frames.
      setTimeout(function () { queued = false; placeAgent(); }, 60);
    }).observe(document.body, { childList: true, subtree: true });
    placeAgent();
    document.addEventListener('mouseover', function (e) {
      var item = e.target.closest && e.target.closest('.console-item');
      if (!item || item.querySelector(':scope > .yab-copy')) return;
      var c = document.createElement('span');
      c.className = 'yab-copy'; c.textContent = 'Copy for Agent';
      c.addEventListener('click', function (ev) { ev.stopPropagation(); ev.preventDefault(); agent('one', item); });
      item.appendChild(c);
    }, true);
    document.addEventListener('contextmenu', function (e) {
      var item = e.target.closest && e.target.closest('.console-item');
      if (!item || !WI.ContextMenu || !WI.ContextMenu.createFromEvent) return;
      var menu = WI.ContextMenu.createFromEvent(e);
      menu.appendItem('Copy for Agent', function () { agent('one', item); });
      menu.appendItem('Copy Console for Agent', function () { agent('all'); });
      menu.appendItem('Ask in Chat', function () { agent('chat', item); });
      menu.appendSeparator();
    }, true);
    // Panels extensions add, React's Components and Profiler: WebKit
    // makes each a tab of its row, which the card hides, so their
    // names go to yab's head, and Y.panel shows one.
    function panels() {
      try {
        var views = WI.sharedApp.extensionController._extensionTabContentViewForExtensionTabIDMap;
        return Array.from(views.values()).map(function (v) { return { id: v.extensionTabID, title: v.tabInfo().displayName }; });
      } catch (e) { return []; }
    }
    var saidPanels = '';
    function toldPanels() {
      var list = panels(), said = JSON.stringify(list);
      if (said !== saidPanels) { saidPanels = said; post({ k: 'panels', p: list }); }
    }
    Y.panel = function (id) {
      try { WI.sharedApp.extensionController.showExtensionTab(id); return true; } catch (e) { return false; }
    };
    try {
      var extensions = WI.WebInspectorExtensionController.prototype;
      if (!extensions.__yab) {
        extensions.__yab = true;
        var make = extensions.createTabForExtension, drop = extensions.unregisterExtension;
        extensions.createTabForExtension = function () {
          var made = make.apply(this, arguments);
          Promise.resolve(made).then(toldPanels, toldPanels);
          return made;
        };
        extensions.unregisterExtension = function () {
          var gone = drop.apply(this, arguments);
          setTimeout(toldPanels);
          return gone;
        };
      }
    } catch (e) {}
    toldPanels();
    // Each panel's frame told whether it is the one on screen: one that
    // runs its extension's DevTools page itself (React's, see
    // ExtensionShims) starts as it comes and lets go as it goes.
    function tellPanels(shown) {
      try {
        WI.sharedApp.extensionController._extensionTabContentViewForExtensionTabIDMap.forEach(function (v, id) {
          var send = function () { var f = v.iframeElement; if (f && f.contentWindow) f.contentWindow.postMessage({ yab: 'panel', shown: id === shown }, '*'); };
          send();
          if (id === shown && v.whenPageAvailable) v.whenPageAvailable().then(send);
        });
      } catch (e) {}
    }
    // What is picked in Elements, told to every panel's frame: React
    // follows it with its own selection (ExtensionShims).
    try {
      WI.domManager.addEventListener(WI.DOMManager.Event.InspectedNodeChanged, function () {
        try {
          WI.sharedApp.extensionController._extensionTabContentViewForExtensionTabIDMap.forEach(function (v) {
            var f = v.iframeElement;
            if (f && f.contentWindow) f.contentWindow.postMessage({ yab: 'selection' }, '*');
          });
        } catch (e) {}
      });
    } catch (e) {}
    // A panel asking for a file at a line (React's "view source"): in
    // Sources, from a panel's own frame only.
    window.addEventListener('message', function (e) {
      var d = e.data, from = false;
      if (!d || d.yab !== 'reveal') return;
      try {
        WI.sharedApp.extensionController._extensionTabContentViewForExtensionTabIDMap.forEach(function (v) {
          if (v.iframeElement && v.iframeElement.contentWindow === e.source) from = true;
        });
      } catch (x) {}
      if (from) Y.reveal(String(d.url), +d.line || 1, +d.column || 1);
    });
    var last = '';
    function told() {
      var item = WI.tabBrowser.tabBar.selectedTabBarItem, type = typeOf(item);
      var view = item && item.representedObject;
      var name = view && view.extensionTabID && view.tabInfo ? view.tabInfo().displayName : '';
      var key = type + name;
      if (type && key !== last) {
        last = key;
        post(name ? { k: 'tab', t: type, n: name } : { k: 'tab', t: type });
        tellPanels(name ? view.extensionTabID : '');
      }
    }
    try { WI.tabBrowser.addEventListener(WI.TabBrowser.Event.SelectedTabContentViewDidChange, function () { told(); placeAgent(); }); } catch (e) {}
    // Light or dark as the window is, whatever was chosen in the
    // inspector's own settings: the card around it follows the window.
    try { if (WI.settings.frontendAppearance.value !== 'system') WI.settings.frontendAppearance.value = 'system'; } catch (e) {}
    // yab has rulers of its own (Measure): WebKit's over the page are
    // off the first time, and after that as whoever uses it leaves them.
    try { if (!localStorage.getItem('yab-rulers')) { WI.settings.showRulers.value = false; localStorage.setItem('yab-rulers', '1'); } } catch (e) {}
    Y.ready = true;
    Y.readyAt = Date.now();
    post({ k: 'ready', at: Y.readyAt });
  }
  start();
})();
