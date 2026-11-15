// CDP's cookie representation includes partition metadata; never flatten CHIPS.
// The caller is the private local app connection, not an extension/page relay.
// Nothing here walks a whole profile: its cookies are read an address at a time.
static constexpr NSUInteger kDRMCookieBatch = 128;
static constexpr NSUInteger kDRMCookieURLs = 64;
static void DRMCookieBatch(Tab& tab, NSArray* cookies, NSString* request) {
  auto results = [NSMutableArray arrayWithCapacity:cookies.count];
  for (NSUInteger i = 0; i < cookies.count; ++i) [results addObject:@NO];
  auto left = std::make_shared<NSUInteger>(cookies.count);
  DRMWhenReady(tab.id, [cookies, results, left, request](Tab& tab) {
    for (NSUInteger i = 0; i < cookies.count; ++i) {
      CDP(tab, @"Network.setCookie", cookies[i], [i, results, left, request](NSDictionary* value, NSString* error) {
        // One refused cookie says so in its row and costs the batch nothing.
        results[i] = @(!error && [value[@"success"] boolValue]);
        if (--*left == 0) Reply(request, @{@"results": results});
      });
    }
  }, [request](NSString* error) { Reply(request, nil, error); }, Running() + 10);
}
static bool DRMCookieCommand(Tab& tab, NSString* method, NSDictionary* params, NSString* request) {
  NSString* cdp = nil;
  NSDictionary* arguments = @{};
  if ([method isEqual:@"drm.cookies.setBatch"]) {
    NSArray* cookies = [params[@"cookies"] isKindOfClass:NSArray.class] ? params[@"cookies"] : nil;
    if (!cookies.count || cookies.count > kDRMCookieBatch) { Reply(request, nil, @"cookies must be a short array"); return true; }
    for (id cookie in cookies) if (![cookie isKindOfClass:NSDictionary.class]) { Reply(request, nil, @"cookie must be an object"); return true; }
    DRMCookieBatch(tab, cookies, request);
    return true;
  }
  if ([method isEqual:@"drm.cookies.get"]) {
    NSArray* urls = [params[@"urls"] isKindOfClass:NSArray.class] ? params[@"urls"] : nil;
    if (!urls.count || urls.count > kDRMCookieURLs) { Reply(request, nil, @"urls must be a short array"); return true; }
    for (id url in urls) if (![url isKindOfClass:NSString.class]) { Reply(request, nil, @"url must be a string"); return true; }
    cdp = @"Network.getCookies"; arguments = @{@"urls": urls};
  }
  else if ([method isEqual:@"drm.cookies.set"] || [method isEqual:@"drm.cookies.delete"]) {
    if (![params[@"cookie"] isKindOfClass:NSDictionary.class]) { Reply(request, nil, @"cookie must be an object"); return true; }
    arguments = params[@"cookie"];
    cdp = [method isEqual:@"drm.cookies.set"] ? @"Network.setCookie" : @"Network.deleteCookies";
  }
  if (!cdp) return false;
  DRMCDP(tab.id, cdp, arguments, [request](NSDictionary* value, NSString* error) {
    if (!error && value[@"success"] && ![value[@"success"] boolValue]) error = @"Chromium rejected the cookie";
    Reply(request, value, error);
  }, Running() + 10);
  return true;
}
