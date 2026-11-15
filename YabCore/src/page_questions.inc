// Native browser requests only. This registry is confined to the UI thread.
struct PageQuestion {
  std::string tab;
  std::function<void(NSDictionary*)> answer;
  uint64_t prompt = 0;
  bool isPrompt = false;
  bool isDialog = false;
  NSString* closeOwner = nil;
  bool replyQueued = false;
  // A page's alert, confirm, prompt or beforeunload. Chromium's, lent to Yab
  // until either Yab answers it once (DialogReplyTask) or Chromium takes it
  // back (WithdrawDialog); `answer` is unused for these rows.
  CefRefPtr<CefJSDialogCallback> dialog;
};
static std::map<std::string, PageQuestion> pageQuestions;
// Chromium takes a page's dialog back when it resets the tab's dialog state
// (navigation, reload, a process swap, the tab or its renderer going away):
// CefJSDialogHandler::OnResetDialogState, and from there OnDialogClosed. The
// callback is then Chromium's to finish, and finishing it from inside that
// reset ran WebContentsImpl::OnDialogClosed in the middle of Chromium's own
// CancelDialogs, sometimes inside ~WebContentsImpl, and the whole engine
// stopped on a CHECK (register row 2895). CEF's contract is to drop the
// callback, not Continue it; dropping the last reference cancels it in its
// destructor, so the reference is let go in a UI task of its own, after the
// reset has unwound. Nothing waits on it and nothing is retried.
class DialogRelease final : public CefTask {
 public:
  explicit DialogRelease(CefRefPtr<CefJSDialogCallback> callback) : callback_(std::move(callback)) {}
  void Execute() override { callback_ = nullptr; }
 private:
  CefRefPtr<CefJSDialogCallback> callback_;
  IMPLEMENT_REFCOUNTING(DialogRelease);
};
static void DialogClosedEvent(const std::string& tab, const std::string& token, NSString* reason);
// Erase every row first, then tell the client: an event can reenter the
// registry (a wire reply, shutdown), and a released callback can reenter CEF.
static void WithdrawDialogs(const std::string& tab, NSString* owner = nil) {
  std::vector<std::pair<std::string, CefRefPtr<CefJSDialogCallback>>> withdrawn;
  for (auto i = pageQuestions.begin(); i != pageQuestions.end();) {
    if (i->second.tab == tab && i->second.isDialog && (!owner || [i->second.closeOwner isEqual:owner])) {
      withdrawn.emplace_back(i->first, std::move(i->second.dialog)); i = pageQuestions.erase(i);
    } else ++i;
  }
  for (auto& [token, callback] : withdrawn) {
    DialogClosedEvent(tab, token, @"withdrawn");
    if (callback) CefPostTask(TID_UI, new DialogRelease(std::move(callback)));
  }
}
static std::map<std::string, int> authAttempts;
// What one page may have open at once, its own; no count across tabs. Chrome's
// PermissionRequestManager and dialog manager are per tab. A count of 128 for
// all tabs together denied every question past it: 300 tabs restored, each
// site asking for notifications, or 300 beforeunload asks at quit.
static constexpr size_t kQuestionsPerTab = 128;
static bool QuestionRoom(const Tab& tab) {
  size_t open = 0;
  for (const auto& [token, question] : pageQuestions) if (question.tab == tab.id && ++open >= kQuestionsPerTab) return false;
  return true;
}
static void CancelQuestions(const std::string& tab) {
  std::vector<std::function<void(NSDictionary*)>> cancel;
  for (auto i = pageQuestions.begin(); i != pageQuestions.end();) {
    if (i->second.tab == tab) {
      // Native prompts belong to Chromium's PermissionRequestManager. During
      // navigation/close it may already be resolving the original request;
      // calling Continue(DENY) here can reenter that half-finished decision.
      // A page's dialog is Chromium's to finish once its document or tab
      // goes: withdrawn below, never answered from here.
      if (i->second.isDialog) { ++i; continue; }
      if (!i->second.isPrompt) cancel.push_back(i->second.answer);
      i = pageQuestions.erase(i);
    }
    else ++i;
  }
  WithdrawDialogs(tab);
  for (auto& answer : cancel) answer(@{});
}
static void AskQuestion(Tab* tab, NSString* kind, NSDictionary* values,
                        std::function<void(NSDictionary*)> answer, uint64_t prompt = 0, bool isPrompt = false) {
  if (!tab || tab->closing || !QuestionRoom(*tab)) { answer(@{}); return; }
  NSString* token = NSUUID.UUID.UUIDString;
  pageQuestions.emplace(Key(token), PageQuestion{tab->id, answer, prompt, isPrompt});
  NSMutableDictionary* p = [values mutableCopy]; p[@"request"] = token; p[@"kind"] = kind;
  p[@"profile"] = @(tab->profile.c_str());
  Event(@"question.open", tab, p);
}
// Transport replies arrive from a CFRunLoop source, including nested native
// loops. Being on the main thread alone does not make it safe to reenter CEF's
// PermissionRequestManager. Keep the original registry entry until a CEF UI
// task executes, so native dismissal/close/navigation can still withdraw it.
class PermissionReplyTask final : public CefTask {
 public:
  PermissionReplyTask(std::string token, NSDictionary* reply) : token_(std::move(token)), reply_([reply copy]) {}
  void Execute() override {
    auto i = pageQuestions.find(token_);
    if (i == pageQuestions.end() || !i->second.isPrompt || !i->second.replyQueued) return;
    auto owner = tabs.find(i->second.tab);
    if (owner == tabs.end() || owner->second.closing) {
      pageQuestions.erase(i); return;
    }
    auto answer = std::move(i->second.answer);
    pageQuestions.erase(i); // Consume before Continue can synchronously dismiss.
    answer(reply_);
  }
 private:
  std::string token_;
  NSDictionary* reply_;
  IMPLEMENT_REFCOUNTING(PermissionReplyTask);
};
static bool QuestionRequest(Tab& tab, NSString* method, NSDictionary* p, NSString* request) {
  if (![method isEqual:@"question.reply"]) return false;
  auto i = pageQuestions.find(Key(S(p, @"request")));
  if (i == pageQuestions.end() || i->second.tab != tab.id || i->second.isDialog || i->second.replyQueued) {
    Reply(request, nil, @"No matching page question"); return true;
  }
  if (i->second.isPrompt) {
    const std::string token = i->first;
    i->second.replyQueued = true;
    if (!CefPostTask(TID_UI, new PermissionReplyTask(token, p))) {
      pageQuestions.erase(token);
      Reply(request, nil, @"Permission reply queue unavailable"); return true;
    }
    Reply(request); return true;
  }
  auto answer = i->second.answer;
  pageQuestions.erase(i);
  Reply(request);
  answer(p);
  return true;
}
static void DismissPermission(Tab* tab, uint64_t prompt) {
  if (!tab) return;
  const bool emit = !IsReadTab(tab);
  NSMutableArray<NSDictionary*>* closed = [NSMutableArray array];
  std::vector<std::function<void(NSDictionary*)>> retained;
  for (auto i = pageQuestions.begin(); i != pageQuestions.end();) {
    if (i->second.tab == tab->id && i->second.prompt == prompt && i->second.isPrompt) {
      [closed addObject:@{@"request": @(i->first.c_str()), @"tab": @(tab->id.c_str()),
        @"profile": @(tab->profile.c_str()), @"prompt": @(std::to_string(prompt).c_str()),
        @"reason": @"native-dismissed"}];
      retained.push_back(i->second.answer);
      i = pageQuestions.erase(i);
    }
    else ++i;
  }
  // Erase every terminal native callback before wire delivery can reenter
  // shutdown and mutate the map or destroy the original Tab. Retain callback
  // references until then as well; their destructors must not reenter erase.
  if (emit) for (NSDictionary* packet in closed) Event(@"question.closed", nullptr, packet);
}
