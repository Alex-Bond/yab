// Included by core.mm after the Tab struct. tab.loadHTML shows a document the
// host already holds under a URL it chooses, with that URL's origin and base
// (WebKit's loadHTMLString(_:baseURL:)). The browser-process resource handler
// serves the body to the one main-frame navigation to that URL, so it needs no
// DevTools session and works on a tab that has not shown a document yet.
class HTMLResource : public CefResourceHandler {
  std::string body_;
  size_t offset_ = 0;
 public:
  explicit HTMLResource(std::string body) : body_(std::move(body)) {}
  bool Open(CefRefPtr<CefRequest>, bool& handle_request, CefRefPtr<CefCallback>) override {
    handle_request = true; return true;
  }
  void GetResponseHeaders(CefRefPtr<CefResponse> response, int64_t& length, CefString&) override {
    response->SetStatus(200); response->SetStatusText("OK");
    response->SetMimeType("text/html"); response->SetCharset("utf-8");
    length = (int64_t)body_.size();
  }
  bool Read(void* out, int want, int& read, CefRefPtr<CefResourceReadCallback>) override {
    size_t n = std::min<size_t>((size_t)std::max(want, 0), body_.size() - offset_);
    if (n) memcpy(out, body_.data() + offset_, n);
    offset_ += n; read = (int)n;
    return n > 0;
  }
  void Cancel() override {}
  IMPLEMENT_REFCOUNTING(HTMLResource);
};
// Resource callbacks run on CEF's IO thread, so the pending documents live in
// their own locked table keyed by browser, never in the main-thread tab map.
// The URL as the network stack will report it: no fragment, and "/" for an empty path.
static std::string CanonicalPageURL(std::string url) {
  auto hash = url.find('#'); if (hash != std::string::npos) url.erase(hash);
  auto scheme = url.find("://");
  if (scheme != std::string::npos && url.find_first_of("/?", scheme + 3) == std::string::npos) url += "/";
  return url;
}
static std::mutex htmlMutex;
static std::map<int, std::pair<std::string, std::string>> htmlPending;  // browser -> (url, body)
class HTMLResourceRequests : public CefResourceRequestHandler {
  int browser_;
 public:
  explicit HTMLResourceRequests(int browser) : browser_(browser) {}
  CefRefPtr<CefResourceHandler> GetResourceHandler(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                                                   CefRefPtr<CefRequest> request) override {
    if (!frame || !frame->IsMain()) return nullptr;
    std::lock_guard<std::mutex> lock(htmlMutex);
    auto pending = htmlPending.find(browser_);
    if (pending == htmlPending.end() || pending->second.first != CanonicalPageURL(request->GetURL().ToString())) return nullptr;
    // One navigation only: a reload or a later load of that URL goes to the network.
    auto body = std::move(pending->second.second);
    htmlPending.erase(pending);
    return new HTMLResource(std::move(body));
  }
  IMPLEMENT_REFCOUNTING(HTMLResourceRequests);
};
static CefRefPtr<CefResourceRequestHandler> HTMLRequestHandler(CefRefPtr<CefBrowser> b, bool navigation) {
  if (!navigation || !b) return nullptr;
  std::lock_guard<std::mutex> lock(htmlMutex);
  if (!htmlPending.count(b->GetIdentifier())) return nullptr;
  return new HTMLResourceRequests(b->GetIdentifier());
}
static bool HTMLLoadRequest(Tab& tab, NSString* method, NSDictionary* p, NSString* request) {
  if (![method isEqual:@"tab.loadHTML"]) return false;
  NSString* url = S(p, @"url");
  if (!url.length || ![p[@"html"] isKindOfClass:NSString.class]) { Reply(request, nil, @"url and html are required"); return true; }
  { std::lock_guard<std::mutex> lock(htmlMutex); htmlPending[tab.browser->GetIdentifier()] = {CanonicalPageURL(Key(url)), Key(p[@"html"])}; }
  tab.browser->GetMainFrame()->LoadURL(Key(url));
  Reply(request);
  return true;
}
