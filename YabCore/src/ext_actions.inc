// Extension action state for Yab's own buttons.
//
// CEF_CTT_NONE has no Chrome toolbar, so nothing draws an action. Chrome's
// own ExtensionAction still keeps every badge, title and enabled state per
// tab; the extension's worker reads it with chrome.action getters for the
// native tab ID. Own CEF supplies that exact browser-bound identity even
// when several external pages share one logical Chrome window. Prebuilt
// CEF keeps its one-tab physical-window fallback. Dynamic icons have no
// getter: the worker's setIcon calls are recorded after the hook is in,
// and the button keeps the extension's own icon until one arrives.
// Only the profile's privileged chrome://extensions control tab may ask,
// and the page must be an ordinary Yab tab of the same, non-private profile.

static NSString* ExtensionActionScript = @R"JS(async (identity) => {
 const windowId = identity.windowId;
 const a = chrome.action;
 const g = globalThis;
 if (a && !g.__yabActionWatch) {
  const icons = new Map();
  g.__yabActionWatch = {icons};
  const tell = tabId => { try { __yabExtensionBridge(JSON.stringify({op:'action.changed', tabId: Number.isInteger(tabId) ? tabId : null})) } catch (_) {} };
  for (const m of ['setBadgeText','setBadgeBackgroundColor','setBadgeTextColor','setTitle','setPopup','enable','disable']) {
   const old = a[m]?.bind(a);
   if (!old) continue;
   a[m] = (...args) => {
    const d = args[0], tabId = typeof d === 'number' ? d : d?.tabId;
    const r = old(...args);
    Promise.resolve(r).then(() => tell(tabId), () => tell(tabId));
    return r;
   };
  }
  const largest = v => {
   if (!v || typeof v !== 'object' || 'width' in v) return v;
   const keys = Object.keys(v).sort((x, y) => Number(y) - Number(x));
   return keys.length ? v[keys[0]] : null;
  };
  const encode = async blob => {
   const bytes = new Uint8Array(await blob.arrayBuffer());
   if (bytes.length > 150000) return null;
   let s = '';
   for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
   return 'data:image/png;base64,' + btoa(s);
  };
  const png = async source => {
   const w = source.width, h = source.height;
   if (!w || !h || w > 256 || h > 256) return null;
   const canvas = new OffscreenCanvas(w, h), ctx = canvas.getContext('2d');
   if (source instanceof ImageData) ctx.putImageData(source, 0, 0);
   else if (source.data) ctx.putImageData(new ImageData(new Uint8ClampedArray(source.data), w, h), 0, 0);
   else ctx.drawImage(source, 0, 0);
   return encode(await canvas.convertToBlob({type: 'image/png'}));
  };
  const capture = async details => {
   const image = largest(details?.imageData);
   if (image) return png(image);
   const path = largest(details?.path);
   if (typeof path !== 'string' || !path) return null;
   const response = await fetch(chrome.runtime.getURL(path.replace(/^\//, '')));
   const blob = await response.blob();
   if (blob.type === 'image/png') return encode(blob);
   return png(await createImageBitmap(blob));
  };
  const setIcon = a.setIcon?.bind(a);
  if (setIcon) a.setIcon = (details, cb) => {
   const r = setIcon(details, cb);
   const key = Number.isInteger(details?.tabId) ? details.tabId : -1;
   capture(details).then(url => { if (url) icons.set(key, url); else icons.delete(key); tell(details?.tabId); },
                         () => { icons.delete(key); tell(details?.tabId); });
   return r;
  };
  // Chrome drops a tab's own action values when it navigates.
  chrome.tabs.onUpdated.addListener((tabId, change) => { if (change.url) { icons.delete(tabId); tell(tabId); } });
  chrome.tabs.onRemoved.addListener(tabId => icons.delete(tabId));
 }
 if (!a) return {action: false};
 let tabId;
 if (Number.isInteger(identity.tabId)) {
  const tab = await chrome.tabs.get(identity.tabId);
  if (tab.id !== identity.tabId || tab.windowId !== windowId)
   return {action: true, error: 'Native page identity no longer matches this profile/window'};
  tabId = tab.id;
 } else {
  const rows = await chrome.tabs.query({windowId});
  if (rows.length !== 1) return {action: true, error: 'Expected one native tab in the page window, found ' + rows.length};
  tabId = rows[0].id;
 }
 const [title, badge, background, color, enabled, popup] = await Promise.all([
  a.getTitle({tabId}), a.getBadgeText({tabId}), a.getBadgeBackgroundColor({tabId}),
  a.getBadgeTextColor ? a.getBadgeTextColor({tabId}) : null,
  a.isEnabled ? a.isEnabled(tabId) : true, a.getPopup({tabId})]);
 const icons = g.__yabActionWatch?.icons;
 // The declarativeNetRequest count is hidden from an extension without
 // feedback access; Chrome answers a placeholder, never the number.
 const hidden = badge === '<<declarativeNetRequestActionCount>>';
 return {action: true, tabId, title, badge: hidden ? '' : badge, countHidden: hidden, background, color,
         enabled, popup: !!popup, icon: icons ? (icons.get(tabId) ?? icons.get(-1) ?? null) : null};
})JS";

static bool ExtensionValidID(NSString* id) {
  NSCharacterSet* invalid = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnop"] invertedSet];
  return id.length == 32 && [id rangeOfCharacterFromSet:invalid].location == NSNotFound;
}

// Called from ExtensionBridgeEvent for the worker's own binding calls.
static bool ExtensionActionBinding(Tab& control, const std::string& extension, NSDictionary* value) {
  if (![S(value, @"op") isEqual:@"action.changed"]) return false;
  NSMutableDictionary* payload = [@{@"extension": @(extension.c_str()), @"profile": @(control.profile.c_str()), @"reason": @"action"} mutableCopy];
  if ([value[@"tabId"] isKindOfClass:NSNumber.class]) payload[@"nativeTab"] = value[@"tabId"];
  Event(@"ext.actions.changed", &control, payload);
  return true;
}

// A worker that started again lost the hook; its owner reads it anew.
static void ExtensionActionWorker(Tab& control, NSString* extension, const std::string& before, const std::string& now) {
  if (now != "running" || before == "running" || !ExtensionValidID(extension)) return;
  Event(@"ext.actions.changed", &control, @{@"extension": extension, @"profile": @(control.profile.c_str()), @"reason": @"worker"});
}

static void ExtensionActionCollect(std::string control, std::string page, int windowId, int nativeTab, NSArray* ids, size_t index,
                                   NSMutableArray* rows, NSString* request) {
  auto c = tabs.find(control);
  if (c == tabs.end() || c->second.closing) { Reply(request, nil, @"Extension control tab closed"); return; }
  auto owner = tabs.find(page);
  if (owner == tabs.end() || owner->second.closing || owner->second.profile != c->second.profile) {
    Reply(request, nil, @"Extension action owner closed or changed profile"); return;
  }
  if (index >= ids.count) { Reply(request, @{@"windowId": @(windowId), @"actions": rows}); return; }
  NSString* extension = ids[index];
  auto next = [control, page, windowId, nativeTab, ids, index, rows, request]() {
    dispatch_async(dispatch_get_main_queue(), ^{ ExtensionActionCollect(control, page, windowId, nativeTab, ids, index + 1, rows, request); });
  };
  ExtensionWithWorker(c->second, extension, [extension, windowId, nativeTab, rows, next](ExtensionWorker worker) {
    NSDictionary* identity = nativeTab >= 0 ? @{@"windowId": @(windowId), @"tabId": @(nativeTab)} : @{@"windowId": @(windowId)};
    NSString* call = [NSString stringWithFormat:@"(%@)(%@)", ExtensionActionScript, JSON(identity)];
    ExtensionEvaluate(worker, call, [extension, rows, next](NSDictionary* value, NSString* error) {
      NSMutableDictionary* row = [@{@"id": extension} mutableCopy];
      if (error) row[@"error"] = error;
      else if ([value isKindOfClass:NSDictionary.class]) [row addEntriesFromDictionary:value];
      else row[@"error"] = @"Extension worker returned no action state";
      [rows addObject:row]; next();
    });
  }, [extension, rows, next](NSDictionary*, NSString* error) {
    [rows addObject:@{@"id": extension, @"error": error ?: @"No extension worker"}]; next();
  });
}

static bool ExtensionActionCommand(Tab& t, NSString* method, NSDictionary* p, NSString* request) {
  bool press = [method isEqual:@"ext.actions.openPopup"];
  if (!press && ![method isEqual:@"ext.actions.state"]) return false;
  if (![Str(t.browser->GetMainFrame()->GetURL()) isEqual:@"chrome://extensions/"]) {
    Reply(request, nil, @"Action state requires this profile's privileged extension-management tab"); return true;
  }
  if (profiles[t.profile].privateMode) { Reply(request, nil, @"Extension actions are unavailable in private profiles"); return true; }
  NSArray* ids = press ? @[S(p, @"extension")] : ([p[@"extensions"] isKindOfClass:NSArray.class] ? p[@"extensions"] : nil);
  if (!ids || ids.count > 64) { Reply(request, nil, @"extensions must list at most 64 Chrome extension IDs"); return true; }
  for (id value in ids) if (![value isKindOfClass:NSString.class] || !ExtensionValidID(value)) {
    Reply(request, nil, @"extensions must list Chrome extension IDs (32 lowercase letters a-p)"); return true;
  }
  auto page = tabs.find(Key(S(p, @"page")));
  if (page == tabs.end() || !page->second.browser || page->second.closing || page->second.internal || !page->second.adopted || page->second.profile != t.profile) {
    Reply(request, nil, @"page must be an open Yab tab of this profile"); return true;
  }
  std::string control = t.id, pageID = page->second.id;
  auto open = [control, pageID, ids, request](int windowId) {
    auto c = tabs.find(control), page = tabs.find(pageID);
    if (c == tabs.end() || page == tabs.end() || page->second.closing || page->second.profile != c->second.profile) {
      Reply(request, nil, @"Extension action owner closed"); return;
    }
    ExtensionWithWorker(c->second, ids[0], [control, pageID, windowId, request](ExtensionWorker worker) {
      auto c = tabs.find(control), page = tabs.find(pageID);
      if (c == tabs.end() || page == tabs.end() || page->second.closing || page->second.profile != c->second.profile) {
        Reply(request, nil, @"Extension action owner closed"); return;
      }
      NSString* script = [NSString stringWithFormat:@"(async()=>{const a=chrome.action??chrome.browserAction;if(!a?.openPopup)throw Error('This action cannot open a popup');await a.openPopup({windowId:%d});return true})()", windowId];
      ExtensionEvaluate(worker, script, [request](NSDictionary* value, NSString* error) { Reply(request, value, error); });
    }, [request](NSDictionary*, NSString* error) { Reply(request, nil, error); });
  };
#if YABCORE_NATIVE_TAB_MODEL && YABCORE_NATIVE_PAGE
  auto native = page->second.browser->GetHost()->GetExternalPageState();
  auto tabID = native ? native->GetValue("extensionTabId") : nullptr;
  auto windowID = native ? native->GetValue("extensionWindowId") : nullptr;
  if (!native || native->GetInt("browserId") != page->second.browser->GetIdentifier() ||
      !tabID || tabID->GetType() != VTYPE_INT || tabID->GetInt() < 0 ||
      !windowID || windowID->GetType() != VTYPE_INT || windowID->GetInt() < 0) {
    Reply(request, nil, @"Native extension tab identity is unavailable"); return true;
  }
  if (press) open(windowID->GetInt());
  else ExtensionActionCollect(control, pageID, windowID->GetInt(), tabID->GetInt(), ids, 0, [NSMutableArray new], request);
#else
  CDP(page->second, @"Browser.getWindowForTarget", @{}, [control, pageID, ids, request, press, open](NSDictionary* r, NSString* error) {
    int windowId = [r[@"windowId"] isKindOfClass:NSNumber.class] ? [r[@"windowId"] intValue] : 0;
    if (error || windowId <= 0) { Reply(request, nil, error ?: @"Chrome did not name the page's window"); return; }
    if (press) open(windowId);
    else ExtensionActionCollect(control, pageID, windowId, -1, ids, 0, [NSMutableArray new], request);
  });
#endif
  return true;
}
