// JavaScript questions use the same native continuation registry as auth and
// permissions. No DevTools event or renderer evaluation is needed to reply.
static void CancelNativeDialogs(const std::string& tab) {
  std::vector<std::function<void(NSDictionary*)>> cancel;
  for (auto i = pageQuestions.begin(); i != pageQuestions.end();) {
    if (i->second.tab == tab && i->second.isDialog) {
      cancel.push_back(i->second.answer); i = pageQuestions.erase(i);
    } else ++i;
  }
  for (auto& answer : cancel) answer(@{});
}
[[maybe_unused]] static void CancelCloseDialogs(const std::string& tab, NSString* owner) {
  std::vector<std::function<void(NSDictionary*)>> cancel;
  for (auto i = pageQuestions.begin(); i != pageQuestions.end();) {
    if (i->second.tab == tab && i->second.isDialog && [i->second.closeOwner isEqual:owner]) {
      cancel.push_back(i->second.answer); i = pageQuestions.erase(i);
    } else ++i;
  }
  for (auto& answer : cancel) answer(@{});
}
static bool OpenNativeDialog(Tab* tab, NSString* origin, NSString* kind,
                             NSString* message, NSString* text,
                             CefRefPtr<CefJSDialogCallback> callback, bool& suppress) {
  if (!tab || tab->closing || pageQuestions.size() >= 128) {
    suppress = true; return false;
  }
  for (const auto& [id, question] : pageQuestions) {
    if (question.tab == tab->id && question.isDialog) { suppress = true; return false; }
  }
  suppress = false;
  NSString* token = NSUUID.UUID.UUIDString;
  pageQuestions.emplace(Key(token), PageQuestion{tab->id,
    [callback, tabID = tab->id, token](NSDictionary* p) {
      auto found = tabs.find(tabID);
      if (found != tabs.end()) Event(@"dialog.closed", &found->second, @{@"request": token});
      callback->Continue([p[@"accept"] boolValue], Key(S(p, @"text")));
    }, 0, false, true, [kind isEqual:@"beforeunload"] ? tab->closeOwner : nil});
  Event(@"dialog.open", tab, @{@"request": token, @"kind": kind, @"origin": origin,
    @"message": message, @"defaultText": text});
  return true;
}
static bool NativeDialogRequest(Tab& tab, NSString* method, NSDictionary* p, NSString* request) {
  if (![method isEqual:@"dialog.reply"]) return false;
  NSString* token = S(p, @"request");
  auto found = pageQuestions.find(Key(token));
  // Wire v1 allowed a tab-scoped reply without a request token. Preserve
  // that compatibility for direct clients; app continuations always name
  // the exact native request so a stale answer cannot settle a newer one.
  if (!token.length) {
    found = std::find_if(pageQuestions.begin(), pageQuestions.end(), [&](const auto& row) {
      return row.second.tab == tab.id && row.second.isDialog;
    });
  }
  if (found == pageQuestions.end() || found->second.tab != tab.id || !found->second.isDialog) {
    Reply(request, nil, @"No matching native dialog"); return true;
  }
  auto answer = found->second.answer;
  pageQuestions.erase(found);
  Reply(request);
  answer(p);
  return true;
}
