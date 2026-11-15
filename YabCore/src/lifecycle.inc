// Native non-destructive approvals and final original-document outcomes.
#if YABCORE_CLOSE_PREFLIGHT
struct NativeCloseScope { NativeCloseScope() { ++nativeCloseDepth; } ~NativeCloseScope() { --nativeCloseDepth; } };
struct CloseMember {
  std::string tab;
  NSString* owner;
  NSString* request;
  NSString* document;
  NSString* token;
  bool final = false, closed = false;
};
struct CloseBatch {
  NSString* wire;
  std::vector<CloseMember> members;
  bool dispatching = true;
};
static std::map<std::string, CloseBatch> closeBatches;
static void ReplyCloseBatch(const std::string& id, bool expired = false) {
  auto found = closeBatches.find(id); if (found == closeBatches.end() || found->second.dispatching) return;
  bool complete = std::all_of(found->second.members.begin(), found->second.members.end(), [](const auto& member) { return member.final; });
  if (!complete && !expired) return;
  NSMutableArray* closed = [NSMutableArray new], *retained = [NSMutableArray new], *unknown = [NSMutableArray new];
  for (const auto& member : found->second.members) {
    if (!member.final) [unknown addObject:@(member.tab.c_str())];
    else [(member.closed ? closed : retained) addObject:@(member.tab.c_str())];
  }
  NSString* wire = found->second.wire; found->second.wire = nil;
  if (complete) closeBatches.erase(found);
  if (wire.length) Reply(wire, @{@"complete": @(complete), @"closed": closed, @"retained": retained, @"unknown": unknown});
}
static void RecordCloseFinal(Tab& tab, NSDictionary* state) {
  std::vector<std::string> ready;
  for (auto& [id, batch] : closeBatches) {
    for (auto& member : batch.members) {
      if (member.tab != tab.id || member.final || ![member.owner isEqual:tab.closeOwner] ||
          ![member.request isEqual:S(state, @"request")] || ![member.document isEqual:S(state, @"document")] ||
          ![member.token isEqual:S(state, @"token")]) continue;
      member.final = true; member.closed = [state[@"closed"] boolValue];
      // A replacement native document remains a usable tab. An unknown
      // in-flight unload stays closing until a real final state arrives.
      if (!member.closed) tab.closing = false;
      ready.push_back(id);
    }
  }
  for (const auto& id : ready) ReplyCloseBatch(id);
}
static void NativeClosePreflight(Tab* tab, CefRefPtr<CefDictionaryValue> native) {
  NativeCloseScope scope; // Even a wire overflow cannot synchronously shut down another browser here.
  if (!tab || !tab->browser || !tab->closeOwner.length) return;
  NSDictionary* state = NativeDictionary(native);
  if (![state[@"version"] isEqual:@1] || [state[@"browserId"] intValue] != tab->browser->GetIdentifier() ||
      !S(state, @"request").length || !S(state, @"document").length) return;
  NSString* expected = S(tab->closePreflight, @"request");
  if (expected.length && ![expected isEqual:S(state, @"request")]) return;
  if (S(tab->closePreflight, @"document").length && ![S(tab->closePreflight, @"document") isEqual:S(state, @"document")]) return;
  if ([state[@"final"] boolValue] &&
      (!S(tab->closePreflight, @"token").length || ![S(tab->closePreflight, @"token") isEqual:S(state, @"token")] ||
       ![@[@"closed", @"retained"] containsObject:S(state, @"phase")] ||
       [state[@"closed"] boolValue] != [S(state, @"phase") isEqual:@"closed"])) return;
  tab->closePreflight = state;
  NSMutableDictionary* event = [state mutableCopy]; event[@"owner"] = tab->closeOwner;
  Event(@"tab.closePreflight", tab, event);
  if ([state[@"final"] boolValue]) {
    RecordCloseFinal(*tab, state);
    if (![state[@"closed"] boolValue]) tab->closeOwner = nil;
    return;
  }
  if ([state[@"decision"] boolValue] || [state[@"withdrawn"] boolValue]) {
    NSString* wire = tab->closeWireRequest; tab->closeWireRequest = nil;
    if (wire.length) Reply(wire, event);
  }
}
static void CancelClosePreflight(Tab& tab) {
  NSString* owner = tab.closeOwner, *request = S(tab.closePreflight, @"request");
  if (request.length && tab.browser && !tab.closing && ![tab.closePreflight[@"final"] boolValue])
    tab.browser->GetHost()->CancelClosePreflight(Key(request));
  NSString* wire = tab.closeWireRequest; tab.closeWireRequest = nil;
  if (!tab.closing) { tab.closeOwner = nil; tab.closePreflight = nil; }
  if (owner.length) CancelCloseDialogs(tab.id, owner);
  if (wire.length) Reply(wire, nil, @"Native close preflight cancelled");
}
static void LifecycleBeforeClose(Tab& tab) {
  // The native observer emits final before delegate Close. An external
  // browser destruction may instead arrive here: record the real endpoint
  // death, never infer closure from dispatch or a timer.
  if (tab.closing && tab.closeOwner.length) {
    NSMutableDictionary* final = [tab.closePreflight mutableCopy];
    final[@"final"] = @YES; final[@"closed"] = @YES; final[@"phase"] = @"closed";
    RecordCloseFinal(tab, final);
  }
  CancelClosePreflight(tab);
}
#endif

static bool LifecycleExpireRequest(NSString* request) {
#if YABCORE_CLOSE_PREFLIGHT
  if (closeBatches.count(Key(request))) { ReplyCloseBatch(Key(request), true); return true; }
  for (auto& [id, tab] : tabs) if ([tab.closeWireRequest isEqual:request]) { CancelClosePreflight(tab); return true; }
#else
  (void)request;
#endif
  return false;
}

static bool LifecycleBatchRequest(NSString* method, NSDictionary* p, NSString* request) {
  if (![method isEqual:@"tabs.close.commit"]) return false;
#if YABCORE_CLOSE_PREFLIGHT
  NSArray* approvals = [p[@"approvals"] isKindOfClass:NSArray.class] ? p[@"approvals"] : nil;
  if (!approvals.count || approvals.count > 256 || closeBatches.size() >= 64) { Reply(request, nil, @"Expected bounded native close approvals"); return true; }
  struct Commit { std::string tab, token; CefRefPtr<CefBrowserHost> host; };
  std::vector<Commit> commits;
  CloseBatch batch; batch.wire = request;
  std::set<std::string> seen;
  NativeCloseScope scope;
  // No event-loop yield or client/native mutation between validate-all and dispatch-all.
  for (::id row in approvals) {
    NSDictionary* item = [row isKindOfClass:NSDictionary.class] ? row : @{};
    auto found = tabs.find(Key(S(item, @"tab")));
    if (found == tabs.end() || !found->second.browser || found->second.closing || !found->second.adopted || !seen.insert(found->first).second) {
      Reply(request, nil, @"Close batch contains an unavailable or duplicate tab"); return true;
    }
    auto& t = found->second; NSString* token = S(item, @"token");
    if (!token.length || ![S(item, @"owner") isEqual:t.closeOwner] ||
        ![S(item, @"document") isEqual:S(t.closePreflight, @"document")] || ![token isEqual:S(t.closePreflight, @"token")] ||
        ![t.closePreflight[@"allow"] boolValue] || [t.closePreflight[@"withdrawn"] boolValue] ||
        !t.browser->GetHost()->ValidateClosePreflight(Key(token))) {
      Reply(request, nil, @"A native close approval expired; no page was closed"); return true;
    }
    batch.members.push_back({found->first, t.closeOwner, S(t.closePreflight, @"request"), S(t.closePreflight, @"document"), token});
    commits.push_back({found->first, Key(token), t.browser->GetHost()});
  }
  const std::string id = Key(request);
  closeBatches.emplace(id, std::move(batch)); requests[id] = Now() + 240;
  for (const auto& commit : commits) tabs.at(commit.tab).closing = true;
  for (const auto& commit : commits) {
    if (!commit.host->CommitClosePreflight(commit.token)) {
      // Refusal is a retained outcome, never a force-close retry.
      auto found = tabs.find(commit.tab);
      if (found != tabs.end()) {
        NSMutableDictionary* final = [found->second.closePreflight mutableCopy];
        final[@"final"] = @YES; final[@"closed"] = @NO; final[@"phase"] = @"retained";
        RecordCloseFinal(found->second, final);
      }
    }
  }
  auto current = closeBatches.find(id);
  if (current != closeBatches.end()) current->second.dispatching = false;
  ReplyCloseBatch(id);
#else
  (void)p;
  Reply(request, nil, @"Non-destructive native close is unavailable in this SDK/API mode");
#endif
  return true;
}

static bool LifecycleRequest(Tab& tab, NSString* method, NSDictionary* p, NSString* request) {
  if ([method isEqual:@"tab.close.prepare"]) {
#if YABCORE_CLOSE_PREFLIGHT
    NSString* owner = S(p, @"owner");
    if (!owner.length || owner.length > 128 || tab.closeOwner.length) {
      Reply(request, nil, @"Invalid or competing native close preflight"); return true;
    }
    tab.closeOwner = owner; tab.closeWireRequest = request; tab.closePreflight = nil;
    requests[Key(request)] = Now() + 240;
    NSDictionary* begin = NativeDictionary(tab.browser->GetHost()->BeginClosePreflight());
    if (![begin[@"accepted"] boolValue] || !S(begin, @"request").length || !S(begin, @"document").length) {
      CancelClosePreflight(tab);
      return true;
    }
    // A no-listener native decision is permitted to arrive synchronously.
    if (!tab.closePreflight) tab.closePreflight = begin;
#else
    (void)p;
    Reply(request, nil, @"Non-destructive native close is unavailable in this SDK/API mode");
#endif
    return true;
  }
  if ([method isEqual:@"tab.close.cancel"]) {
#if YABCORE_CLOSE_PREFLIGHT
    if (![S(p, @"owner") isEqual:tab.closeOwner]) { Reply(request, nil, @"Close preflight owner changed"); return true; }
    CancelClosePreflight(tab); Reply(request);
#else
    Reply(request, nil, @"Non-destructive native close is unavailable in this SDK/API mode");
#endif
    return true;
  }
  if ([method isEqual:@"tab.tryClose"]) {
    bool now = tab.browser->GetHost()->TryCloseBrowser();
    Reply(request, @{@"immediate": @(now)});
    return true;
  }
  if (![method isEqual:@"page.beforeUnloadListeners"]) return false;
  std::string id = tab.id;
  CDP(tab, @"Runtime.evaluate", @{@"expression": @"window", @"returnByValue": @NO}, [id, request](NSDictionary* r, NSString* e) {
    auto t = tabs.find(id);
    NSString* object = S(r[@"result"], @"objectId");
    if (e || t == tabs.end() || !object.length) { Reply(request, nil, e ?: @"No window object"); return; }
    CDP(t->second, @"DOMDebugger.getEventListeners", @{@"objectId": object}, [id, request, object](NSDictionary* r, NSString* e) {
      int count = 0;
      for (NSDictionary* listener in r[@"listeners"]) if ([S(listener, @"type") isEqual:@"beforeunload"]) count++;
      auto t = tabs.find(id);
      if (t != tabs.end()) CDP(t->second, @"Runtime.releaseObject", @{@"objectId": object}, Ignore);
      if (e) Reply(request, nil, e); else Reply(request, @{@"count": @(count)});
    });
  });
  return true;
}
