// WebAuthn on Chromium pages. Chromium checks each request itself (the RP ID
// against the origin, related origins, a frame's publickey-credentials
// permissions, an extension's host permissions), then CEF patch 0113 hands it
// here instead of showing Chromium's own authenticator UI, which would stand
// in a window nobody sees (#1843). The client answers with the Mac's sheet:
// "webauthn.request" carries the request out with the page's tab, or for an
// extension's action popup, which is no tab, its owner tab and the popup's
// lease; "webauthn.respond" brings the answer back; "webauthn.cancel" says the
// page gave up. A request nobody takes is refused (NotAllowedError).
#if YABCORE_WEBAUTHN_PROXY
static std::map<std::string, CefRefPtr<CefWebAuthnCallback>> webAuthnRequests;
static bool WebAuthnRequest(Tab* tab, CefRefPtr<CefDictionaryValue> request, CefRefPtr<CefWebAuthnCallback> callback) {
  if (!hello || !request || !callback || webAuthnRequests.size() >= 64) return false;
  NSMutableDictionary* copy = [NativeDictionary(request) mutableCopy];
  std::string token = Key(S(copy, @"request"));
  if (token.empty() || webAuthnRequests.count(token)) return false;
  [copy removeObjectForKey:@"profilePath"];
  Tab* target = tab && !tab->internal ? tab : nullptr;
#if YABCORE_EXTENSION_HOOKS
  // An action popup is Chrome's own page: the live popup of the extension
  // Chromium says asked, never a page's word.
  std::string extension = Key(S(copy, @"extensionId"));
  if (!target && !extension.empty() && [S(copy, @"viewType") isEqual:@"popup"]) {
    for (auto& [lease, value] : nativePopupLeases) {
      if (value.extension != extension) continue;
      auto owner = tabs.find(value.owner);
      if (owner == tabs.end() || owner->second.closing) continue;
      copy[@"popup"] = @(lease.c_str());
      target = &owner->second;
      break;
    }
  }
#endif
  if (!target) return false;
  webAuthnRequests[token] = callback;
  Event(@"webauthn.request", target, copy);
  return true;
}
static void WebAuthnCanceled(const std::string& token) {
  if (webAuthnRequests.erase(token)) Event(@"webauthn.cancel", nullptr, @{@"request": @(token.c_str())});
}
static bool WebAuthnRespond(NSString* method, NSDictionary* p, NSString* request) {
  if (![method isEqual:@"webauthn.respond"]) return false;
  auto found = webAuthnRequests.find(Key(S(p, @"request")));
  if (found == webAuthnRequests.end()) { Reply(request, nil, @"Unknown or finished WebAuthn request"); return true; }
  NSString* response = S(p, @"response");
  if (response.length > 1024 * 1024) { Reply(request, nil, @"The answer is too long"); return true; }
  auto callback = found->second;
  webAuthnRequests.erase(found);
  callback->Respond(CefString(response.UTF8String), CefString(S(p, @"errorName").UTF8String),
                    CefString(S(p, @"errorMessage").UTF8String));
  Reply(request);
  return true;
}
static void ClearWebAuthn() { webAuthnRequests.clear(); }  // A dropped callback refuses.
#else
static bool WebAuthnRespond(NSString*, NSDictionary*, NSString*) { return false; }
static void ClearWebAuthn() {}
#endif
