// Chrome's real DevTools for a tab. Its frontend is one more external page:
// the tab is reserved here, Chrome makes the browser inside ShowDevTools and
// View::OnPopupBrowserViewCreated hosts it in a Window as any page, so surface,
// resize and input work as they do for a tab. Answered once Attach sees it.
static bool DevToolsRequest(Tab& t, NSString* method, NSDictionary* p, NSString* request) {
  if ([method isEqual:@"devtools.close"]) {
    // Chrome closes its window later: the next open must not find this one.
    t.devToolsFront.clear();
    if (t.browser) t.browser->GetHost()->CloseDevTools();
    Reply(request, @{});
    return true;
  }
  if (![method isEqual:@"devtools.open"]) return false;
  if (t.internal || t.devToolsFrontend || !t.view) { Reply(request, nil, @"This tab has no DevTools"); return true; }
  // Page points. Chrome reads (0, 0) as no point to inspect.
  CefPoint at([p[@"x"] intValue], [p[@"y"] intValue]);
  CefWindowInfo info; info.runtime_style = CEF_RUNTIME_STYLE_CHROME;
  CefBrowserSettings settings; settings.background_color = 0xffffffff;
  auto front = tabs.find(t.devToolsFront);
  if (front != tabs.end() && !front->second.closing) {
    t.browser->GetHost()->ShowDevTools(info, nullptr, settings, at);
    Reply(request, @{@"tab": @(front->first.c_str())});
    return true;
  }
  auto browser = t.browser;
  std::string profile = t.profile, id = "tab-" + std::to_string(++tabSequence);
  Tab value; value.id = id; value.profile = profile; value.createRequest = request; value.devToolsFrontend = true;
  if (p[@"width"]) value.width = [p[@"width"] intValue];
  if (p[@"height"]) value.height = [p[@"height"] intValue];
  // Inserting may move nothing else, but keep no reference across it.
  std::string owner = t.id;
  tabs.emplace(id, std::move(value));
  tabs.at(owner).devToolsFront = id;
  devToolsAsked[browser->GetIdentifier()] = id;
  browser->GetHost()->ShowDevTools(info, new Client(profile, id), settings, at);
  devToolsAsked.erase(browser->GetIdentifier());
  auto made = tabs.find(id);
  if (made != tabs.end() && !made->second.browser) {
    tabs.erase(made);
    Reply(request, nil, @"Chrome did not open DevTools for this page");
  }
  return true;
}
