// Included inside yc after CDP and the profile/tab tables. CEF's HasDocument
// can lag Chrome WebUI/CWS documents, so it is diagnostic only, never proof.
static bool DocumentMatches(Tab& t, NSDictionary* proof) {
  if (!proof) return true;  // Low-level wire clients may evaluate explicitly.
  auto main = t.browser ? t.browser->GetMainFrame() : nullptr;
  if (![proof isKindOfClass:NSDictionary.class] || t.closing || t.crashed || !t.domainsReady ||
      !main || !main->IsValid() ||
      ![S(proof, @"profile") isEqual:@(t.profile.c_str())] ||
      ![proof[@"generation"] isKindOfClass:NSNumber.class] ||
      ![proof[@"context"] isKindOfClass:NSNumber.class] ||
      [proof[@"generation"] unsignedLongLongValue] != t.documentGeneration ||
      ![S(proof, @"url") isEqual:Str(main->GetURL())]) return false;
  auto context = t.drmFrames.find([proof[@"context"] intValue]);
  return context != t.drmFrames.end() && context->second == Key(S(proof, @"frame"));
}
static void Readiness(Tab& tab, NSDictionary* params, NSString* request) {
  std::string id = tab.id, profile = Key(S(params, @"profile"));
  NSString* expected = S(params, @"url");
  if (profile.empty() || profile != tab.profile) { Reply(request, nil, @"Readiness profile mismatch"); return; }
  auto frame = tab.browser->GetMainFrame();
  NSString* url = frame ? Str(frame->GetURL()) : @"";
  auto unready = [request](NSString* reason) { Reply(request, @{@"ready": @NO, @"reason": reason}); };
  if (tab.crashed || !tab.domainsReady || !frame || !frame->IsValid() ||
      (expected.length && ![expected isEqual:url])) { unready(@"No live target document"); return; }
  uint64_t generation = tab.documentGeneration;
  auto valid = [id, profile, url, generation]() -> Tab* {
    auto current = tabs.find(id);
    if (current == tabs.end()) return nullptr;
    Tab& t = current->second;
    if (stopping || t.closing || t.crashed || !t.browser || !t.domainsReady ||
        t.profile != profile || t.documentGeneration != generation) return nullptr;
    auto main = t.browser->GetMainFrame();
    return main && main->IsValid() && [Str(main->GetURL()) isEqual:url] ? &t : nullptr;
  };
  CDP(tab, @"Page.getFrameTree", @{}, [request, url, valid, unready](NSDictionary* result, NSString* error) {
    Tab* t = valid();
    if (error || !t) { unready(error ?: @"Document changed"); return; }
    NSDictionary* frame = result[@"frameTree"][@"frame"];
    NSString* frameID = S(frame, @"id");
    NSString* frameURL = [S(frame, @"url") stringByAppendingString:S(frame, @"urlFragment")];
    if (!frameID.length || frame[@"parentId"] || ![frameURL isEqual:url]) { unready(@"Main frame changed"); return; }
    int context = 0;
    for (auto& [candidate, owner] : t->drmFrames) if (owner == Key(frameID)) { context = candidate; break; }
    if (!context) { unready(@"Main world unavailable"); return; }
    Eval(*t, @"({live:document.nodeType===9&&!!document.documentElement,url:document.URL,state:document.readyState})", context,
      [request, url, frameID, context, valid, unready](NSDictionary* result, NSString* error) {
        Tab* t = valid();
        if (error || !t) { unready(error ?: @"Document changed"); return; }
        auto owner = t->drmFrames.find(context);
        NSDictionary* proof = result[@"result"][@"value"];
        if (owner == t->drmFrames.end() || owner->second != Key(frameID) ||
            ![proof isKindOfClass:NSDictionary.class] || ![proof[@"live"] boolValue] ||
            ![S(proof, @"url") isEqual:url] || ![@[@"loading", @"interactive", @"complete"] containsObject:S(proof, @"state")]) {
          unready(@"Document proof unavailable"); return;
        }
        Reply(request, @{@"ready": @YES, @"profile": @(t->profile.c_str()), @"url": url,
          @"frame": frameID, @"generation": @(t->documentGeneration), @"context": @(context), @"devToolsReady": @YES,
          @"hasDocument": @(t->browser->HasDocument()), @"proof": @"mainFrameDocument"});
      });
  });
}
