// Dedicated task-read transport. This is deliberately not a ChromiumPage
// adapter: no caller JavaScript, input or generic page endpoint is admitted.
// Included after owncef_native.inc, before Client. Native isolation is still
// unavailable; never infer it from the narrower autoplay lock API.
#include <atomic>

struct ReadPagePolicy {
  const std::string owner, session, profile, token;
  std::atomic<bool> retired{false};
  ReadPagePolicy(std::string o, std::string s, std::string p)
      : owner(std::move(o)), session(std::move(s)), profile(std::move(p)),
        token(Key(NSUUID.UUID.UUIDString)) {}
};
static constexpr bool NativeRemoteReadAvailable() { return false; }
static NSString* ReadPageUnavailable() {
  return @"Native task read is unavailable: immutable task-local service-worker and extension isolation is not implemented";
}
static bool ReadPageIdentifier(NSString* value) {
  return value.length && value.length <= 128 &&
      [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
}
static bool ReadPageURL(NSString* value) {
  if (!value.length || value.length > 16384 ||
      [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return false;
  NSURLComponents* parts = [NSURLComponents componentsWithString:value];
  NSString* scheme = parts.scheme.lowercaseString;
  return parts && ( [scheme isEqual:@"http"] || [scheme isEqual:@"https"] ) &&
      parts.host.length && parts.user == nil && parts.password == nil;
}
// A policy's lifetime crosses UI and IO tasks. Never look up the UI-owned tabs
// map in a resource callback; hold the immutable policy and its atomic veto.
class ReadResourceGuard : public CefResourceRequestHandler {
  const std::shared_ptr<ReadPagePolicy> policy_;
 public:
  explicit ReadResourceGuard(std::shared_ptr<ReadPagePolicy> policy)
      : policy_(std::move(policy)) {}
  bool Allowed(CefRefPtr<CefRequest> request) const {
    return policy_ && !policy_->retired.load(std::memory_order_acquire) &&
        request && request->GetMethod() == "GET" &&
        !request->GetPostData() && ReadPageURL(Str(request->GetURL()));
  }
  cef_return_value_t OnBeforeResourceLoad(CefRefPtr<CefBrowser>,
      CefRefPtr<CefFrame>, CefRefPtr<CefRequest> request,
      CefRefPtr<CefCallback>) override {
    return Allowed(request) ? RV_CONTINUE : RV_CANCEL;
  }
  // OnResourceResponse false means continue, not cancel. Do not pretend it is
  // an attachment/response veto. Full native policy must supply that boundary.
  IMPLEMENT_REFCOUNTING(ReadResourceGuard);
};
struct ReadPageEntry {
  std::string tab;
  std::shared_ptr<ReadPagePolicy> policy;
};
static std::map<std::string, ReadPageEntry> readPages;
static std::set<std::pair<std::string, std::string>> retiredReadSessions;
static bool readAdmissionRetired = false;
static std::mutex readBrowserMutex;
static std::map<int, std::shared_ptr<ReadPagePolicy>> readBrowserPolicies;
static std::shared_ptr<ReadPagePolicy> ReadPolicyForBrowser(CefRefPtr<CefBrowser> browser) {
  if (!browser) return {};
  std::lock_guard<std::mutex> lock(readBrowserMutex);
  auto i = readBrowserPolicies.find(browser->GetIdentifier());
  return i == readBrowserPolicies.end() ? nullptr : i->second;
}
static bool IsReadBrowser(CefRefPtr<CefBrowser> browser) {
  return static_cast<bool>(ReadPolicyForBrowser(browser));
}
static bool IsReadTab(const Tab* tab) {
  return tab && readPages.count(tab->id);
}
static NSDictionary* ReadIdentity(const ReadPageEntry& entry) {
  return @{@"tab": @(entry.tab.c_str()), @"profile": @(entry.policy->profile.c_str()),
      @"private": @NO, @"owner": @(entry.policy->owner.c_str()),
      @"session": @(entry.policy->session.c_str()), @"token": @(entry.policy->token.c_str())};
}
static bool ReadPageMatches(const ReadPageEntry& entry, NSDictionary* p) {
  const auto& q = entry.policy;
  return !q->retired.load(std::memory_order_acquire) &&
      Key(S(p, @"tab")) == entry.tab && Key(S(p, @"profile")) == q->profile &&
      Key(S(p, @"owner")) == q->owner && Key(S(p, @"session")) == q->session &&
      Key(S(p, @"token")) == q->token && p[@"private"] &&
      CFGetTypeID((__bridge CFTypeRef)p[@"private"]) == CFBooleanGetTypeID() &&
      ![p[@"private"] boolValue];
}
static void RetireReadPage(ReadPageEntry& entry) {
  // This veto is visible to IO before any asynchronous browser destruction.
  entry.policy->retired.store(true, std::memory_order_release);
  auto t = tabs.find(entry.tab);
  if (t != tabs.end() && t->second.browser) {
    t->second.closing = true;
    auto browser = t->second.browser;
    dispatch_async(dispatch_get_main_queue(), ^{ browser->GetHost()->CloseBrowser(true); });
  }
}
static void ReadPageClosed(CefRefPtr<CefBrowser> browser) {
  if (!browser) return;
  std::shared_ptr<ReadPagePolicy> policy;
  {
    std::lock_guard<std::mutex> lock(readBrowserMutex);
    auto i = readBrowserPolicies.find(browser->GetIdentifier());
    if (i == readBrowserPolicies.end()) return;
    policy = i->second; policy->retired.store(true, std::memory_order_release);
    readBrowserPolicies.erase(i);
  }
  for (auto& [_, entry] : readPages) {
    if (entry.policy != policy) continue;
    NSMutableDictionary* result = [ReadIdentity(entry) mutableCopy];
    result[@"reason"] = @"native-browser-closed";
    Event(@"read.page.closed", nullptr, result);
  }
  // Preserve immutable role through the rest of OnBeforeClose so generic
  // tab.closed/layer events remain suppressed even after policy retirement.
}
static void ForgetReadPage(const std::string& tab) { readPages.erase(tab); }
static void ClearReadPages() {
  readAdmissionRetired = true;
  for (auto& [_, entry] : readPages)
    entry.policy->retired.store(true, std::memory_order_release);
  std::lock_guard<std::mutex> lock(readBrowserMutex);
  for (auto& [_, policy] : readBrowserPolicies)
    policy->retired.store(true, std::memory_order_release);
  readBrowserPolicies.clear(); readPages.clear();
}
static bool ReadPageRequest(NSString* method, NSDictionary* p, NSString* request) {
  if (![method hasPrefix:@"read.page."]) return false;
  NSString* owner = S(p, @"owner"), *session = S(p, @"session");
  if (!ReadPageIdentifier(owner) || !ReadPageIdentifier(session)) {
    Reply(request, nil, @"Task read requires bounded owner and session identities"); return true;
  }
  auto key = std::make_pair(Key(owner), Key(session));
  if ([method isEqual:@"read.page.revoke"]) {
    if (retiredReadSessions.count(key) || retiredReadSessions.size() < 256)
      retiredReadSessions.insert(key);
    else readAdmissionRetired = true; // Bound tombstones without allowing reuse.
    NSMutableArray* retired = [NSMutableArray new];
    for (auto& [_, entry] : readPages) if (entry.policy->owner == key.first && entry.policy->session == key.second) {
      RetireReadPage(entry); [retired addObject:@(entry.tab.c_str())];
    }
    Reply(request, @{@"revoked": @YES, @"retired": retired}); return true;
  }
  if ([method isEqual:@"read.page.create"]) {
    if (readAdmissionRetired || retiredReadSessions.count(key)) { Reply(request, nil, @"Task read session was revoked"); return true; }
    NSString* profile = S(p, @"profile");
    auto context = profiles.find(Key(profile));
    if (!p[@"private"] || CFGetTypeID((__bridge CFTypeRef)p[@"private"]) != CFBooleanGetTypeID() ||
        [p[@"private"] boolValue] || context == profiles.end() ||
        !context->second.ready || context->second.privateMode) {
      Reply(request, nil, @"Task read requires the already opened captured public profile"); return true;
    }
    if (!ReadPageURL(S(p, @"url"))) { Reply(request, nil, @"Task read requires HTTP(S) without URL credentials"); return true; }
    // Absolutely no Create(), policy UUID receipt or ordinary tab.created is
    // allowed until native pre-navigation full-tree isolation is implemented.
    Reply(request, nil, ReadPageUnavailable()); return true;
  }
  auto entry = readPages.find(Key(S(p, @"tab")));
  if (entry == readPages.end() || !ReadPageMatches(entry->second, p)) {
    Reply(request, nil, @"Unknown, retired or foreign task read page"); return true;
  }
  if ([method isEqual:@"read.page.close"]) {
    NSDictionary* identity = ReadIdentity(entry->second);
    RetireReadPage(entry->second);
    NSMutableDictionary* result = [identity mutableCopy]; result[@"retired"] = @YES;
    Reply(request, result); return true;
  }
  // No partial state/read response is returned while all-frame native document
  // binding, pre/post secret guards and original tree stitching are absent.
  Reply(request, nil, ReadPageUnavailable()); return true;
}
