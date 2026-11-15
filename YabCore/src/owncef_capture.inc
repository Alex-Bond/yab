// Exact-browser native activity, independent of site-reported MediaSession state.
#if YABCORE_NATIVE_CAPTURE_ACTIVITY
static NSDictionary* NativeCaptureSnapshot(Tab& tab, CefRefPtr<CefDictionaryValue> native) {
  if (!native || !tab.browser || native->GetInt("version") != 1 ||
      native->GetInt("browserId") != tab.browser->GetIdentifier() ||
      native->GetString("scope") != "browser") return nil;
  NSMutableDictionary* state = [NativeDictionary(native) mutableCopy];
  state[@"profile"] = @(tab.profile.c_str());
  if ([state[@"known"] boolValue] && (!S(state, @"token").length ||
      !S(state, @"primaryDocument").length || !S(state, @"primaryFrameId").length)) return nil;
  return state;
}
// Automatic lifecycle callers carry the exact native capture snapshot they
// evaluated. Revalidate at mutation time, rather than trusting event order.
static bool NativeCaptureAllowsLifecycle(Tab& tab, NSDictionary* params) {
  NSDictionary* state = tab.browser ? NativeCaptureSnapshot(tab,
      tab.browser->GetHost()->GetNativeCaptureState()) : nil;
  if (!state || ![state[@"known"] boolValue] ||
      !S(params, @"captureToken").length || !S(params, @"captureDocument").length ||
      ![S(state, @"token") isEqual:S(params, @"captureToken")] ||
      ![S(state, @"primaryDocument") isEqual:S(params, @"captureDocument")]) return false;
  for (NSString* key in @[@"camera", @"microphone", @"screen", @"tab", @"window", @"display", @"allScreens",
                          @"mirrored", @"videoPiP", @"documentPiP"]) {
    id value = state[key];
    if (![value isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() || [value boolValue]) return false;
  }
  return true;
}
static void NativeCaptureChanged(Tab* tab, CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefDictionaryValue> native) {
  if (!tab || tab->closing || !tab->browser || !browser || !tab->browser->IsSame(browser)) return;
  if (NSDictionary* state = NativeCaptureSnapshot(*tab, native)) Event(@"media.capture.changed", tab, state);
}
#endif
static bool NativeCaptureRequest(Tab& tab, NSString* method, NSDictionary* params, NSString* request) {
  if (![method isEqual:@"media.capture.state"] && ![method isEqual:@"media.capture.stop"]) return false;
#if YABCORE_NATIVE_CAPTURE_ACTIVITY
  if (!tab.browser || tab.closing || tab.internal || !tab.adopted ||
      (params[@"profile"] && ![S(params, @"profile") isEqual:@(tab.profile.c_str())])) {
    Reply(request, nil, @"Native capture browser is unavailable or mismatched"); return true;
  }
  auto host = tab.browser->GetHost();
  if ([method isEqual:@"media.capture.state"]) {
    NSDictionary* state = NativeCaptureSnapshot(tab, host->GetNativeCaptureState());
    Reply(request, state, state ? nil : @"Native capture snapshot is unavailable"); return true;
  }
  NSString* token = S(params, @"token"), *kind = S(params, @"kind");
  bool dispatched = token.length && host->StopNativeCapture(Key(token), Key(kind));
  Reply(request, dispatched ? @{@"dispatched": @YES} : nil,
        dispatched ? nil : @"Native capture token or stop kind is stale or unsupported");
#else
  (void)tab; (void)params;
  Reply(request, nil, @"Native capture activity is unavailable in this SDK/API mode");
#endif
  return true;
}
