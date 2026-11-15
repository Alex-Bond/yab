// CDP's cookie representation includes partition metadata; never flatten CHIPS.
// The caller is the private local app connection, not an extension/page relay.
static bool DRMCookieCommand(Tab& tab, NSString* method, NSDictionary* params, NSString* request) {
  NSString* cdp = nil;
  NSDictionary* arguments = @{};
  if ([method isEqual:@"drm.cookies.list"]) cdp = @"Network.getAllCookies";
  else if ([method isEqual:@"drm.cookies.set"] || [method isEqual:@"drm.cookies.delete"]) {
    if (![params[@"cookie"] isKindOfClass:NSDictionary.class]) { Reply(request, nil, @"cookie must be an object"); return true; }
    arguments = params[@"cookie"];
    cdp = [method isEqual:@"drm.cookies.set"] ? @"Network.setCookie" : @"Network.deleteCookies";
  }
  if (!cdp) return false;
  DRMCDP(tab.id, cdp, arguments, [request](NSDictionary* value, NSString* error) {
    if (!error && value[@"success"] && ![value[@"success"] boolValue]) error = @"Chromium rejected the cookie";
    Reply(request, value, error);
  }, Now() + 10);
  return true;
}
