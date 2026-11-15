// Included in core.mm so page scripts share its bounded CDP transport.
static void ScriptTree(Tab& tab, NSDictionary* tree) {
  NSDictionary* frame = tree[@"frame"];
  if (S(frame, @"id").length) {
    std::string id = Key(S(frame, @"id"));
    if (!tab.scripts.frames.count(id)) tab.scripts.frameOrder.push_back(id);
    tab.scripts.frames[id] = frame;
    if (S(frame, @"parentId").length) tab.scripts.parents[id] = Key(S(frame, @"parentId"));
  }
  for (NSDictionary* child in tree[@"childFrames"]) ScriptTree(tab, child);
}
using ScriptCommands = std::vector<std::pair<NSString*, NSDictionary*>>;
static void ScriptRun(std::string tab, NSString* session, std::shared_ptr<ScriptCommands> commands,
                      size_t index, Completion done) {
  auto found = tabs.find(tab);
  if (found == tabs.end() || found->second.closing) { done(nil, @"Tab closed"); return; }
  if (index == commands->size()) { done(@{}, nil); return; }
  auto [method, params] = commands->at(index);
  CDP(found->second, method, params, [tab, session, commands, index, done, method](NSDictionary* result, NSString* error) {
    if (error) { done(nil, error); return; }
    auto current = tabs.find(tab);
    if (current == tabs.end()) { done(nil, @"Tab closed"); return; }
    if ([method isEqual:@"Page.getFrameTree"]) {
      ScriptTree(current->second, result[@"frameTree"]);
      if (!session.length) current->second.scripts.mainFrame = S(result[@"frameTree"][@"frame"], @"id");
    }
    if ([method isEqual:@"Page.addScriptToEvaluateOnNewDocument"] && result[@"identifier"])
      current->second.scripts.identifiers[Key(session)].push_back(result[@"identifier"]);
    ScriptRun(tab, session, commands, index + 1, done);
  }, session);
}
static NSString* ScriptBridge(NSArray* names) {
  return [NSString stringWithFormat:@R"JS((()=>{
    const pending=new Map(); let serial=0;
    const prefix=Array.from(crypto.getRandomValues(new Uint32Array(4)),n=>n.toString(16)).join('-');
    const send=globalThis.yabScriptRelay;
    const handlers=Object.create(null);
    for(const name of %@) handlers[name]={postMessage(body){
      if(pending.size>=128) return Promise.reject(new Error('Too many relay requests'));
      const id=prefix+':'+String(++serial);
      return new Promise((resolve,reject)=>{
        const timer=setTimeout(()=>{pending.delete(id);reject(new Error('Relay timed out'))},20000);
        pending.set(id,{resolve,reject,timer});
        try {send(JSON.stringify({id,name,body}));} catch(error){clearTimeout(timer);pending.delete(id);reject(error)}
      });
    }};
    Object.defineProperty(globalThis,'__yabScriptReply',{value:(id,value,error)=>{
      const call=pending.get(id); if(!call)return;
      pending.delete(id);clearTimeout(call.timer);
      if(error)call.reject(new Error(error));else call.resolve(value);
    },configurable:true});
    Object.defineProperty(globalThis,'webkit',{value:{messageHandlers:handlers},configurable:true});
  })();
  )JS", JSON(names)];
}
static void ScriptSetup(Tab& tab, NSString* session, bool immediately, Completion done) {
  auto commands = std::make_shared<ScriptCommands>();
  auto old = tab.scripts.identifiers.find(Key(session));
  if (old != tab.scripts.identifiers.end()) {
    for (NSString* identifier : old->second)
      commands->push_back({@"Page.removeScriptToEvaluateOnNewDocument", @{@"identifier": identifier}});
    old->second.clear();
  }
  // Bind every world before feature scripts can execute. Register each
  // script separately in the caller's order, including across worlds.
  for (NSString* world in tab.scripts.relays) {
    NSArray* names = tab.scripts.relays[world];
    if (!names.count) continue;
    commands->push_back({@"Runtime.addBinding", @{@"name": @"yabScriptRelay", @"executionContextName": world}});
    NSMutableDictionary* bridge = [@{@"source": ScriptBridge(names), @"worldName": world} mutableCopy];
    if (immediately) bridge[@"runImmediately"] = @YES;
    commands->push_back({@"Page.addScriptToEvaluateOnNewDocument", bridge});
  }
  for (NSDictionary* script in tab.scripts.definitions) {
    NSString* world = S(script, @"world"), *source = S(script, @"source");
    if ([script[@"mainOnly"] boolValue]) source = [NSString stringWithFormat:@"if(window===window.top){\n%@\n}", source];
    source = [NSString stringWithFormat:@"(()=>{\n%@\n})();\n", source];
    if ([script[@"end"] boolValue]) source = [NSString stringWithFormat:@"(()=>{const run=()=>{%@};if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',run,{once:true});else run()})();\n", source];
    NSMutableDictionary* params = [@{@"source": source} mutableCopy];
    if (world.length) params[@"worldName"] = world;
    if (immediately) params[@"runImmediately"] = @YES;
    commands->push_back({@"Page.addScriptToEvaluateOnNewDocument", params});
  }
  ScriptRun(tab.id, session, commands, 0, done);
}
// CSS prefers-color-scheme and the ground before a page paints, as the
// app's view would give them in WebKit. Each target (main and every
// out-of-process frame) keeps its own emulation, so each session is told.
static void ScriptAppearance(const Tab& tab, ScriptCommands& commands) {
  NSDictionary* appearance = tab.scripts.appearance;
  if (!appearance) return;
  NSString* scheme = S(appearance, @"scheme");
  commands.push_back({@"Emulation.setEmulatedMedia", @{@"features": @[@{@"name": @"prefers-color-scheme", @"value": scheme}]}});
  NSDictionary* ground = [appearance[@"ground"] isKindOfClass:NSDictionary.class] ? appearance[@"ground"] : nil;
  commands.push_back({@"Emulation.setDefaultBackgroundColorOverride", ground ? @{@"color": ground} : @{}});
  // A page in a window nobody focuses (ours is hidden) hears its focus events
  // only when told it has focus, as a page in the key window would.
  if ([appearance[@"focused"] isKindOfClass:NSNumber.class])
    commands.push_back({@"Emulation.setFocusEmulationEnabled", @{@"enabled": @([appearance[@"focused"] boolValue] && tab.visible)}});
}
static void ScriptAttach(Tab& tab, NSString* session, Completion done) {
  tab.scripts.sessions.insert(Key(session));
  auto commands = std::make_shared<ScriptCommands>();
  commands->push_back({@"Page.enable", @{}});
  commands->push_back({@"Runtime.enable", @{}});
  commands->push_back({@"Page.getFrameTree", @{}});
  // Pause new out-of-process frames until their scripts and bindings exist.
  commands->push_back({@"Target.setAutoAttach", @{@"autoAttach": @YES, @"waitForDebuggerOnStart": @YES,
    @"flatten": @YES, @"filter": @[@{@"type": @"iframe", @"exclude": @NO}, @{@"exclude": @YES}]}});
  ScriptAppearance(tab, *commands);
  ScriptRun(tab.id, session, commands, 0, [id = tab.id, session, done](NSDictionary*, NSString* error) {
    auto found = tabs.find(id);
    if (error || found == tabs.end()) { done(nil, error ?: @"Tab closed"); return; }
    ScriptSetup(found->second, session, true, [id, session, done](NSDictionary* value, NSString* error) {
      // Release the target even on setup failure, and surface the failure.
      auto found = tabs.find(id);
      if (found != tabs.end() && session.length) CDP(found->second, @"Runtime.runIfWaitingForDebugger", @{}, Ignore, session);
      done(value, error);
    });
  });
}
static NSDictionary* ScriptFrame(const Tab& tab, const ScriptContext& context) {
  NSString* origin = context.origin;
  for (const auto& [key, candidate] : tab.scripts.contexts)
    if (candidate.isDefault && [candidate.session isEqual:context.session] && [candidate.frame isEqual:context.frame]) { origin = candidate.origin; break; }
  NSURL* url = [NSURL URLWithString:origin];
  auto frame = tab.scripts.frames.find(Key(context.frame));
  NSString* href = frame == tab.scripts.frames.end() ? origin : S(frame->second, @"url");
  bool main = !context.session.length && [context.frame isEqual:tab.scripts.mainFrame];
  return @{@"token": context.token, @"frameId": context.frame, @"main": @(main), @"url": href,
    @"scheme": url.scheme ?: @"", @"host": url.host ?: @"", @"port": url.port ?: @0};
}
static void ScriptEvent(Tab& tab, NSString* method, NSDictionary* params, NSString* session) {
  if ([method isEqual:@"Page.frameNavigated"]) {
    NSDictionary* frame = params[@"frame"];
    if (S(frame, @"id").length) {
      std::string id = Key(S(frame, @"id"));
      if (!tab.scripts.frames.count(id)) tab.scripts.frameOrder.push_back(id);
      tab.scripts.frames[id] = frame;
      if (S(frame, @"parentId").length) tab.scripts.parents[id] = Key(S(frame, @"parentId"));
    }
    if (!session.length && !frame[@"parentId"]) tab.scripts.mainFrame = S(frame, @"id");
    // A new document in a new renderer gets a new surface, which is drawn
    // in the default ground until told: say the ground again as it commits.
    if (!frame[@"parentId"] && tab.scripts.appearance && [tab.scripts.appearance[@"ground"] isKindOfClass:NSDictionary.class]) {
      std::string id = tab.id;
      dispatch_async(dispatch_get_main_queue(), ^{
        auto found = tabs.find(id);
        if (found == tabs.end() || found->second.closing) return;
        auto commands = std::make_shared<ScriptCommands>();
        ScriptAppearance(found->second, *commands);
        ScriptRun(id, session, commands, 0, [](NSDictionary*, NSString*) {});
      });
    }
  } else if ([method isEqual:@"Page.frameAttached"]) {
    std::string id = Key(S(params, @"frameId"));
    if (!tab.scripts.parents.count(id)) tab.scripts.frameOrder.push_back(id);
    tab.scripts.parents[id] = Key(S(params, @"parentFrameId"));
  } else if ([method isEqual:@"Page.frameDetached"] && [S(params, @"reason") isEqual:@"remove"]) {
    std::set<std::string> removed{Key(S(params, @"frameId"))};
    bool changed = true;
    while (changed) {
      changed = false;
      for (const auto& [frame, parent] : tab.scripts.parents)
        if (removed.count(parent) && removed.insert(frame).second) changed = true;
    }
    for (const auto& frame : removed) { tab.scripts.frames.erase(frame); tab.scripts.parents.erase(frame); }
    std::erase_if(tab.scripts.frameOrder, [&](const std::string& frame) { return removed.count(frame); });
    for (auto it = tab.scripts.contexts.begin(); it != tab.scripts.contexts.end();) {
      if (removed.count(Key(it->second.frame))) it = tab.scripts.contexts.erase(it); else ++it;
    }
  } else if ([method isEqual:@"Target.attachedToTarget"]) {
    NSString* child = S(params, @"sessionId");
    std::string id = tab.id;
    if (![S(params[@"targetInfo"], @"type") isEqual:@"iframe"] || !child.length) return;
    // Not from inside the observer's notification: the commands it sends may
    // be answered at once, which would nest a second one.
    dispatch_async(dispatch_get_main_queue(), ^{
      auto found = tabs.find(id);
      if (found == tabs.end() || found->second.closing) return;
      ScriptAttach(found->second, child, [id](NSDictionary*, NSString* error) {
        auto found = tabs.find(id);
        if (error && found != tabs.end()) Event(@"script.error", &found->second, @{@"message": error});
      });
    });
  } else if ([method isEqual:@"Target.detachedFromTarget"]) {
    NSString* child = S(params, @"sessionId");
    tab.scripts.sessions.erase(Key(child)); tab.scripts.identifiers.erase(Key(child));
    for (auto it = tab.scripts.contexts.begin(); it != tab.scripts.contexts.end();) {
      if ([it->second.session isEqual:child]) it = tab.scripts.contexts.erase(it); else ++it;
    }
  } else if ([method isEqual:@"Runtime.executionContextCreated"]) {
    NSDictionary* context = params[@"context"], *aux = context[@"auxData"];
    NSString* token = S(context, @"uniqueId"), *frame = S(aux, @"frameId");
    if (!token.length || !frame.length) return;
    tab.scripts.contexts[Key(token)] = {token, session, frame, S(context, @"name"), S(context, @"origin"),
      [context[@"id"] intValue], [aux[@"isDefault"] boolValue], S(aux, @"yabDocumentToken")};
  } else if ([method isEqual:@"Runtime.executionContextsCleared"] || [method isEqual:@"Runtime.executionContextDestroyed"]) {
    for (auto it = tab.scripts.contexts.begin(); it != tab.scripts.contexts.end();) {
      if ([it->second.session isEqual:session] && ([method isEqual:@"Runtime.executionContextsCleared"] || it->second.id == [params[@"executionContextId"] intValue]))
        it = tab.scripts.contexts.erase(it);
      else ++it;
    }
  } else if ([method isEqual:@"Runtime.bindingCalled"] && [S(params, @"name") isEqual:@"yabScriptRelay"]) {
    const ScriptContext* context = nullptr;
    for (auto& [key, value] : tab.scripts.contexts)
      if ([value.session isEqual:session] && value.id == [params[@"executionContextId"] intValue]) { context = &value; break; }
    if (!context) return;
    NSData* data = [S(params, @"payload") dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length > 1024 * 1024) return;
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![value isKindOfClass:NSDictionary.class]) return;
    NSArray* allowed = tab.scripts.relays[context->world];
    if (![allowed containsObject:S(value, @"name")] || !S(value, @"id").length) return;
    // Frame metadata comes only from CDP. The page cannot supply its origin.
    Event(@"script.relay", &tab, @{@"world": context->world, @"name": S(value, @"name"),
      @"request": S(value, @"id"), @"value": value[@"body"] ?: NSNull.null,
      @"frame": ScriptFrame(tab, *context)});
  }
}
// A tab CEF made with no URL has no DevTools agent until its first
// navigation starts, and the scripts must be in before the first document.
// So the agent is asked for with a blank document, which the first real load
// takes out of the history again (OnLoadEnd), and the request waits for it.
static void ScriptWithAgent(std::string id, Completion ready, double deadline = 0) {
  auto found = tabs.find(id);
  if (found == tabs.end() || found->second.closing) { ready(nil, @"Tab closed"); return; }
  Tab& tab = found->second;
  if (tab.domainsReady) { ready(@{}, nil); return; }
  if (deadline == 0) {
    deadline = Now() + 15;
    if (tab.scriptBootstrapAllowed && tab.browser && !tab.browser->HasDocument() && !tab.scripts.blankFirst) {
      tab.scripts.blankFirst = true;
      if (getenv("YAB_CEF_TRACE_CDP")) fprintf(stderr, "YabCore script bootstrap: tab=%s browser=%d at=%.6f\n", id.c_str(), tab.browser->GetIdentifier(), Now());
      tab.browser->GetMainFrame()->LoadURL("about:blank");
    }
  }
  if (Now() > deadline) { ready(nil, @"DevTools did not attach"); return; }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    ScriptWithAgent(id, ready, deadline);
  });
}
static bool ScriptRequest(Tab& tab, NSString* method, NSDictionary* params, NSString* request) {
  if (!tab.domainsReady && ([method isEqual:@"scripts.appearance"] || [method isEqual:@"scripts.install"])) {
    ScriptWithAgent(tab.id, [id = tab.id, method, params, request](NSDictionary*, NSString* error) {
      auto found = tabs.find(id);
      if (error || found == tabs.end()) { Reply(request, nil, error ?: @"Tab closed"); return; }
      ScriptRequest(found->second, method, params, request);
    });
    return true;
  }
  if ([method isEqual:@"scripts.input"]) {
    NSString* kind = S(params, @"kind");
    auto commands = std::make_shared<ScriptCommands>();
    int modifiers = [params[@"modifiers"] intValue];
    if ([kind isEqual:@"text"]) commands->push_back({@"Input.insertText", @{@"text": S(params, @"text")}});
    else if ([kind isEqual:@"key"]) {
      NSMutableDictionary* key = [@{@"type": @"keyDown", @"modifiers": @(modifiers), @"key": S(params, @"key"),
        @"code": S(params, @"code"), @"windowsVirtualKeyCode": params[@"keyCode"] ?: @0,
        @"nativeVirtualKeyCode": params[@"nativeCode"] ?: @0} mutableCopy];
      NSString* text = S(params, @"text");
      if ([S(params, @"key") isEqual:@"Enter"]) text = @"\r";
      if (text.length && !(modifiers & 6)) key[@"text"] = text;
      // CDP on macOS needs the editor command for native command shortcuts.
      if (modifiers & 4) {
        NSDictionary* editing = @{@"a": @"selectAll", @"c": @"copy", @"v": @"paste", @"x": @"cut", @"z": @"undo"};
        NSString* command = editing[[S(params, @"key") lowercaseString]];
        if ([command isEqual:@"undo"] && (modifiers & 8)) command = @"redo";
        if (command) key[@"commands"] = @[command];
      }
      if (modifiers == 2 && [[S(params, @"key") lowercaseString] isEqual:@"d"])
        key[@"commands"] = @[@"deleteForward"];
      commands->push_back({@"Input.dispatchKeyEvent", key});
      NSMutableDictionary* up = [key mutableCopy]; up[@"type"] = @"keyUp";
      [up removeObjectForKey:@"text"]; [up removeObjectForKey:@"commands"];
      commands->push_back({@"Input.dispatchKeyEvent", up});
    } else if ([kind isEqual:@"mousePressed"] || [kind isEqual:@"mouseReleased"] || [kind isEqual:@"mouseMoved"]) {
      double x = [params[@"x"] doubleValue], y = [params[@"y"] doubleValue];
      if (!std::isfinite(x) || !std::isfinite(y)) { Reply(request, nil, @"Invalid input coordinates"); return true; }
      commands->push_back({@"Input.dispatchMouseEvent", @{@"type": kind, @"x": @(x), @"y": @(y),
        @"button": S(params, @"button").length ? S(params, @"button") : @"none", @"buttons": params[@"buttons"] ?: @0,
        @"clickCount": params[@"clickCount"] ?: @0, @"modifiers": @(modifiers)}});
    } else { Reply(request, nil, @"Unknown script input"); return true; }
    ScriptRun(tab.id, @"", commands, 0, [request](NSDictionary* value, NSString* error) { Reply(request, value, error); });
    return true;
  }
  if ([method isEqual:@"scripts.appearance"]) {
    NSDictionary* appearance = params[@"appearance"];
    NSString* scheme = [appearance isKindOfClass:NSDictionary.class] ? S(appearance, @"scheme") : nil;
    if (![scheme isEqual:@"light"] && ![scheme isEqual:@"dark"]) { Reply(request, nil, @"A light or dark scheme is required"); return true; }
    id ground = appearance[@"ground"];
    NSMutableDictionary* stored = [@{@"scheme": scheme} mutableCopy];
    if ([ground isKindOfClass:NSDictionary.class]) {
      NSMutableDictionary* color = [NSMutableDictionary dictionary];
      for (NSString* key in @[@"r", @"g", @"b"]) {
        id v = ground[key];
        if (![v isKindOfClass:NSNumber.class] || !std::isfinite([v doubleValue]) || [v doubleValue] < 0 || [v doubleValue] > 255) { Reply(request, nil, @"Invalid ground"); return true; }
        color[key] = @((int)lround([v doubleValue]));
      }
      id a = ground[@"a"];
      double alpha = [a isKindOfClass:NSNumber.class] ? [a doubleValue] : 1;
      if (!std::isfinite(alpha) || alpha < 0 || alpha > 1) { Reply(request, nil, @"Invalid ground"); return true; }
      color[@"a"] = @(alpha);
      stored[@"ground"] = color;
    } else if (ground && ground != NSNull.null) { Reply(request, nil, @"Invalid ground"); return true; }
    if ([appearance[@"focused"] isKindOfClass:NSNumber.class]) stored[@"focused"] = @([appearance[@"focused"] boolValue]);
    // Chrome draws a page's surface in the theme's ground until the first
    // frame, and takes the theme from the process's appearance: the same
    // scheme, so the ground before the first frame is not a white flash.
    NSAppearance* wanted = [NSAppearance appearanceNamed:[scheme isEqual:@"dark"] ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
    if (wanted && ![NSApp.appearance.name isEqual:wanted.name]) NSApp.appearance = wanted;
    tab.scripts.appearance = stored;
    auto sessions = std::make_shared<std::vector<std::string>>(tab.scripts.sessions.begin(), tab.scripts.sessions.end());
    if (sessions->empty()) sessions->push_back("");
    auto remaining = std::make_shared<size_t>(sessions->size());
    auto failure = std::make_shared<NSString*>(nil);
    for (const auto& session : *sessions) {
      auto commands = std::make_shared<ScriptCommands>();
      ScriptAppearance(tab, *commands);
      ScriptRun(tab.id, @(session.c_str()), commands, 0, [request, remaining, failure](NSDictionary*, NSString* error) {
        if (error) *failure = error;
        if (--*remaining) return;
        Reply(request, @{}, *failure);
      });
    }
    return true;
  }
  if ([method isEqual:@"scripts.install"]) {
    id scripts = params[@"scripts"], relays = params[@"relays"];
    if (![scripts isKindOfClass:NSArray.class] || [scripts count] > 128 || ![relays isKindOfClass:NSDictionary.class]) {
      Reply(request, nil, @"Invalid scripts or relays"); return true;
    }
    for (id script in scripts) {
      if (![script isKindOfClass:NSDictionary.class] || !S(script, @"source").length || S(script, @"world").length > 128 || [S(script, @"world") hasPrefix:@"__yab"]) {
        Reply(request, nil, @"Invalid page script"); return true;
      }
    }
    for (NSString* world in relays) {
      id names = relays[world];
      if (!world.length || world.length > 128 || [world hasPrefix:@"__yab"] || ![names isKindOfClass:NSArray.class] || [names count] > 64) {
        Reply(request, nil, @"Relays require an isolated world"); return true;
      }
      for (id name in names) if (![name isKindOfClass:NSString.class] || ![name length] || [name length] > 128) {
        Reply(request, nil, @"Invalid relay name"); return true;
      }
    }
    if (tab.scripts.applying) { Reply(request, nil, @"Scripts are already being installed"); return true; }
    tab.scripts.definitions = scripts; tab.scripts.relays = relays;
    if (!tab.domainsReady) { Reply(request); return true; }
    tab.scripts.applying = true;
    auto sessions = std::make_shared<std::vector<std::string>>(tab.scripts.sessions.begin(), tab.scripts.sessions.end());
    if (sessions->empty()) sessions->push_back("");
    auto remaining = std::make_shared<size_t>(sessions->size());
    auto failure = std::make_shared<NSString*>(nil);
    for (const auto& session : *sessions) ScriptSetup(tab, @(session.c_str()), false, [id = tab.id, request, remaining, failure](NSDictionary*, NSString* error) {
      if (error) *failure = error;
      if (--*remaining) return;
      auto found = tabs.find(id); if (found != tabs.end()) found->second.scripts.applying = false;
      Reply(request, @{}, *failure);
    });
    return true;
  }
  if ([method isEqual:@"scripts.reply"] || [method isEqual:@"scripts.evaluate"]) {
    auto found = tab.scripts.contexts.find(Key(S(params, @"frame")));
    if (found == tab.scripts.contexts.end()) { Reply(request, nil, @"Stale or foreign frame"); return true; }
    ScriptContext context = found->second;
    if ([method isEqual:@"scripts.reply"]) {
      if (!tab.scripts.relays[context.world]) { Reply(request, nil, @"Not a relay context"); return true; }
      NSString* expression = [NSString stringWithFormat:@"globalThis.__yabScriptReply(%@,%@,%@)", JSON(S(params, @"request")), JSON(params[@"value"]), JSON(params[@"error"])];
      CDP(tab, @"Runtime.evaluate", @{@"expression": expression, @"uniqueContextId": context.token},
        [request](NSDictionary* result, NSString* error) { Reply(request, result, error); }, context.session);
      return true;
    }
    NSString* world = S(params, @"world"), *function = S(params, @"function");
    if (!function.length || world.length > 128 || [world hasPrefix:@"__yab"]) { Reply(request, nil, @"Invalid evaluation"); return true; }
    auto run = [id = tab.id, request, context, function, params](int executionContext) {
      auto current = tabs.find(id);
      if (current == tabs.end() || !current->second.scripts.contexts.count(Key(context.token))) { Reply(request, nil, @"Stale frame"); return; }
      NSString* unique = nil;
      for (const auto& [key, candidate] : current->second.scripts.contexts)
        if ([candidate.session isEqual:context.session] && candidate.id == executionContext) { unique = candidate.token; break; }
      if (!unique) { Reply(request, nil, @"Execution context unavailable"); return; }
      CDP(current->second, @"Runtime.callFunctionOn", @{@"functionDeclaration": function, @"uniqueContextId": unique,
        @"arguments": @[@{@"value": params[@"arguments"] ?: NSNull.null}], @"awaitPromise": @YES, @"returnByValue": @YES,
        @"userGesture": @([params[@"userGesture"] boolValue])}, [request](NSDictionary* result, NSString* error) {
          Reply(request, result[@"result"][@"value"] ?: NSNull.null, error ?: (result[@"exceptionDetails"] ? JSON(result[@"exceptionDetails"]) : nil));
        }, context.session);
    };
    if ([world isEqual:context.world] || (!world.length && context.isDefault)) run(context.id);
    else if (world.length && ([&]() {
      // A world of that name this frame already has (made by an earlier call or
      // by a script registered for it): reuse it, each Page.createIsolatedWorld
      // makes a new one, and a script defined in one is not seen from another.
      for (const auto& [key, candidate] : tab.scripts.contexts)
        if ([candidate.session isEqual:context.session] && [candidate.frame isEqual:context.frame] && [candidate.world isEqual:world]) {
          run(candidate.id); return true;
        }
      return false;
    })()) {}
    else if (world.length) CDP(tab, @"Page.createIsolatedWorld", @{@"frameId": context.frame, @"worldName": world},
      [run, request, id = tab.id, world, context](NSDictionary* result, NSString* error) {
        if (error) { Reply(request, nil, error); return; }
        int created = [result[@"executionContextId"] intValue];
        // A world made now, in a document that is already up, never saw the
        // bridge the new-document script gives it: give it, once, so a script
        // run there (dark pages turned on live) can reach its relay.
        auto current = tabs.find(id);
        NSArray* names = current == tabs.end() ? nil : current->second.scripts.relays[world];
        if (!names.count) { run(created); return; }
        NSString* once = [NSString stringWithFormat:@"if(!globalThis.__yabScriptReply){%@}", ScriptBridge(names)];
        CDP(current->second, @"Runtime.evaluate", @{@"expression": once, @"contextId": @(created)},
          [run, created](NSDictionary*, NSString*) { run(created); }, context.session);
      }, context.session);
    else {
      bool foundDefault = false;
      for (auto& [key, candidate] : tab.scripts.contexts) if (candidate.isDefault && [candidate.session isEqual:context.session] && [candidate.frame isEqual:context.frame]) {
        run(candidate.id); foundDefault = true; break;
      }
      if (!foundDefault) Reply(request, nil, @"Document context unavailable");
    }
    return true;
  }
  if ([method isEqual:@"scripts.status"]) {
    NSMutableArray* contexts = [NSMutableArray new], *sessions = [NSMutableArray new];
    for (auto& [key, context] : tab.scripts.contexts) {
      NSMutableDictionary* value = [ScriptFrame(tab, context) mutableCopy];
      value[@"nativeDocument"] = context.nativeDocument; value[@"world"] = context.world; value[@"session"] = context.session; value[@"default"] = @(context.isDefault);
      [contexts addObject:value];
    }
    for (const auto& session : tab.scripts.sessions) [sessions addObject:@(session.c_str())];
    Reply(request, @{@"contexts": contexts, @"sessions": sessions}); return true;
  }
  if ([method isEqual:@"scripts.frames"]) {
    CDP(tab, @"Page.getFrameTree", @{}, [id = tab.id, request](NSDictionary* result, NSString* error) {
      auto found = tabs.find(id);
      if (error || found == tabs.end()) { Reply(request, nil, error ?: @"Tab closed"); return; }
      NSString* main = result[@"frameTree"][@"frame"][@"id"];
      ScriptTree(found->second, result[@"frameTree"]);
      NSMutableArray* frames = [NSMutableArray new];
      std::set<std::string> visited;
      std::function<void(std::string, int)> walk = [&](std::string frame, int depth) {
        if (depth >= 8 || frames.count >= 40 || !visited.insert(frame).second) return;
        if (frame != Key(main)) for (const auto& [key, context] : found->second.scripts.contexts)
          if (context.isDefault && Key(context.frame) == frame) { [frames addObject:ScriptFrame(found->second, context)]; break; }
        for (const auto& child : found->second.scripts.frameOrder) {
          auto parent = found->second.scripts.parents.find(child);
          if (parent != found->second.scripts.parents.end() && parent->second == frame) walk(child, depth + 1);
        }
      };
      walk(Key(main), 0);
      Reply(request, frames);
    });
    return true;
  }
  return false;
}
