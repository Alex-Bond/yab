// Deferred helper adapter for the native MediaSession API. Not included by
// the active helper. Native capture/PiP activity remains a separate capability.
#if YABCORE_NATIVE_MEDIA_SESSION
static NSDictionary* NativeMediaSnapshot(Tab& tab, CefRefPtr<CefDictionaryValue> native) {
  if (!native || !tab.browser || native->GetInt("version") != 1 ||
      native->GetInt("browserId") != tab.browser->GetIdentifier()) return nil;
  NSMutableDictionary* copy = [NativeDictionary(native) mutableCopy];
  copy[@"profile"] = @(tab.profile.c_str());
  const bool privateMode = profiles.at(tab.profile).privateMode;
  copy[@"private"] = @(privateMode);
  copy[@"hideMetadata"] = @(privateMode || [copy[@"hideMetadata"] boolValue]);
  if ([copy[@"hideMetadata"] boolValue]) {
    copy[@"artwork"] = @[];
    copy[@"title"] = @""; copy[@"artist"] = @""; copy[@"album"] = @"";
  }
  if (![copy[@"available"] boolValue]) return copy;
  NSString* document = S(copy, @"document"), *frameId = S(copy, @"frameId");
  if (!document.length || !frameId.length || !S(copy, @"token").length || !S(copy, @"session").length)
    return nil;
  for (const auto& [key, context] : tab.scripts.contexts) {
    if (!context.isDefault || ![context.nativeDocument isEqual:document] ||
        ![context.frame isEqual:frameId]) continue;
    NSDictionary* frame = ScriptFrame(tab, context);
    if (![S(frame, @"url") isEqual:S(copy, @"url")] ||
        [frame[@"main"] boolValue] != [copy[@"main"] boolValue]) continue;
    copy[@"source"] = @{@"version": @1, @"frame": frame, @"nativeDocument": document};
    break;
  }
  // No current Runtime token means no source object, never a main-frame guess.
  // The native session token still authenticates original native controls.
  return copy;
}
static void NativeMediaChanged(Tab* tab, CefRefPtr<CefBrowser> browser,
                               CefRefPtr<CefDictionaryValue> state) {
  if (!tab || tab->closing || !tab->browser || !browser || !tab->browser->IsSame(browser)) return;
  if (NSDictionary* snapshot = NativeMediaSnapshot(*tab, state))
    Event(@"media.session.changed", tab, snapshot);
}
#endif

static bool NativeMediaRequest(Tab& tab, NSString* method, NSDictionary* params, NSString* request) {
  if (![method isEqual:@"media.session.state"] && ![method isEqual:@"media.session.action"]) return false;
#if YABCORE_NATIVE_MEDIA_SESSION
  if (!tab.browser || tab.closing || tab.internal || !tab.adopted ||
      (params[@"profile"] && ![S(params, @"profile") isEqual:@(tab.profile.c_str())])) {
    Reply(request, nil, @"Native media session owner is unavailable or mismatched"); return true;
  }
  auto host = tab.browser->GetHost();
  if ([method isEqual:@"media.session.state"]) {
    NSDictionary* snapshot = NativeMediaSnapshot(tab, host->GetNativeMediaSessionState());
    Reply(request, snapshot, snapshot ? nil : @"Native media snapshot is unavailable"); return true;
  }
  id value = params[@"seconds"];
  if (value && (![value isKindOfClass:NSNumber.class] ||
      CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID())) {
    Reply(request, nil, @"Media seek offset must be numeric"); return true;
  }
  const double seconds = value ? [value doubleValue] : 0;
  NSString* token = S(params, @"token"), *action = S(params, @"action");
  if (!token.length || !action.length || !std::isfinite(seconds)) {
    Reply(request, nil, @"Media action requires a native token and finite offset"); return true;
  }
  bool accepted = host->SendNativeMediaSessionAction(Key(token), Key(action), seconds);
  Reply(request, accepted ? @{@"dispatched": @YES} : nil,
      accepted ? nil : @"Native session token or action is stale or unsupported");
#else
  (void)tab; (void)params;
  Reply(request, nil, @"Native MediaSession is unavailable in this SDK/API mode");
#endif
  return true;
}
