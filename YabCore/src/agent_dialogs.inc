// JavaScript questions use the same native continuation registry as auth and
// permissions. No DevTools event or renderer evaluation is needed to reply.
static void DialogClosedEvent(const std::string& tab, const std::string& token, NSString* reason) {
  auto found = tabs.find(tab);
  if (found != tabs.end()) Event(@"dialog.closed", &found->second, @{@"request": @(token.c_str()), @"reason": reason});
}
// Yab's own answer runs as a CEF UI task, as permission replies do: transport
// replies arrive from a CFRunLoop source, nested native loops included, where
// reentering Chromium's dialog manager is not safe. The row stays in the
// registry until then, so a reset in between withdraws it and the answer is
// dropped: the callback is answered at most once, never after Chromium took
// it back.
class DialogReplyTask final : public CefTask {
 public:
  DialogReplyTask(std::string token, bool accept, NSString* text) : token_(std::move(token)), accept_(accept), text_([text copy]) {}
  void Execute() override {
    auto i = pageQuestions.find(token_);
    if (i == pageQuestions.end() || !i->second.isDialog || !i->second.replyQueued) return;
    const std::string tab = i->second.tab;
    CefRefPtr<CefJSDialogCallback> callback = std::move(i->second.dialog);
    pageQuestions.erase(i); // Consume before Continue can reenter OnResetDialogState.
    DialogClosedEvent(tab, token_, accept_ ? @"accepted" : @"cancelled");
    if (callback) callback->Continue(accept_, Key(text_));
  }
 private:
  std::string token_;
  bool accept_;
  NSString* text_;
  IMPLEMENT_REFCOUNTING(DialogReplyTask);
};
static bool QueueDialogReply(std::map<std::string, PageQuestion>::iterator row, bool accept, NSString* text) {
  if (row->second.replyQueued) return true;
  row->second.replyQueued = true;
  if (CefPostTask(TID_UI, new DialogReplyTask(row->first, accept, text))) return true;
  row->second.replyQueued = false;
  return false;
}
static void CancelNativeDialogs(const std::string& tab) { WithdrawDialogs(tab); }
// Yab's own close flow gave up: the page's beforeunload asks are cancelled,
// as if the person pressed Stay.
[[maybe_unused]] static void CancelCloseDialogs(const std::string& tab, NSString* owner) {
  for (auto i = pageQuestions.begin(); i != pageQuestions.end(); ++i) {
    if (i->second.tab == tab && i->second.isDialog && [i->second.closeOwner isEqual:owner])
      QueueDialogReply(i, false, @"");
  }
}
static bool OpenNativeDialog(Tab* tab, NSString* origin, NSString* kind,
                             NSString* message, NSString* text,
                             CefRefPtr<CefJSDialogCallback> callback, bool& suppress) {
  // One dialog per tab, as Chromium's JavaScriptDialogManager; no count across tabs.
  if (!tab || tab->closing) {
    suppress = true; return false;
  }
  for (const auto& [id, question] : pageQuestions) {
    if (question.tab == tab->id && question.isDialog) { suppress = true; return false; }
  }
  suppress = false;
  NSString* token = NSUUID.UUID.UUIDString;
  pageQuestions.emplace(Key(token), PageQuestion{tab->id, nullptr, 0, false, true,
    [kind isEqual:@"beforeunload"] ? tab->closeOwner : nil, false, callback});
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
  if (found == pageQuestions.end() || found->second.tab != tab.id || !found->second.isDialog || found->second.replyQueued) {
    Reply(request, nil, @"No matching native dialog"); return true;
  }
  if (!QueueDialogReply(found, [p[@"accept"] boolValue], S(p, @"text"))) {
    Reply(request, nil, @"Dialog reply queue unavailable"); return true;
  }
  Reply(request);
  return true;
}
