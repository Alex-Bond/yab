// A link for another app. Chrome's own question would be asked from a window
// nobody sees and the navigation would hang on it, so every scheme a page
// cannot show stops here and the client decides: its card, its remembered
// answers, and macOS for the opening. WebKit's tabs take the same path.
static bool ExternalScheme(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame> frame, CefRefPtr<CefRequest> request, bool gesture) {
  if (!request || !frame) return false;
  NSString* url = Str(request->GetURL());
  NSString* scheme = [NSURL URLWithString:url].scheme.lowercaseString;
  if (!scheme.length) {
    NSRange colon = [url rangeOfString:@":"];
    if (colon.location == NSNotFound) return false;
    scheme = [url substringToIndex:colon.location].lowercaseString;
  }
  static NSSet* pages = [NSSet setWithArray:@[@"http", @"https", @"file", @"about", @"data", @"blob", @"filesystem", @"ws", @"wss",
    @"chrome", @"chrome-extension", @"chrome-untrusted", @"chrome-search", @"chrome-error", @"devtools", @"view-source", @"javascript", @"yab"]];
  if ([pages containsObject:scheme]) return false;
  auto t = Find(b);
  if (!t) return false;
  if (t->internal) return true;
  // A frame made to carry the link has no document of its own yet: the page
  // that made it is what asks (Slack's "Redirecting..." frame).
  auto asker = frame;
  if (!frame->IsMain() && frame->GetURL().empty() && frame->GetParent()) asker = frame->GetParent();
  Event(@"page.external", t, @{@"url": url, @"main": @(frame->IsMain()), @"gesture": @(gesture),
    @"askerMain": @(asker->IsMain()), @"asker": Str(asker->GetURL()) ?: @""});
  return true;
}
