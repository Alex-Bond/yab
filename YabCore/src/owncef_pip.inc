// Original native video-PiP session/surface, independent from the page layer.
#if YABCORE_NATIVE_VIDEO_PIP
static NSDictionary* NativePiPSnapshot(Tab& tab, CefRefPtr<CefDictionaryValue> native) {
  if (!native || !tab.browser || native->GetInt("version") != 1 ||
      native->GetInt("browserId") != tab.browser->GetIdentifier() ||
      native->GetString("kind") != "video") return nil;
  NSMutableDictionary* state = [NativeDictionary(native) mutableCopy];
  state[@"profile"] = @(tab.profile.c_str());
  if (![state[@"active"] boolValue]) return state;
  NSString* document = S(state, @"document"), *frameId = S(state, @"frameId");
  if (!S(state, @"token").length || !document.length || !frameId.length) return nil;
  for (const auto& [key, context] : tab.scripts.contexts) {
    if (!context.isDefault || ![context.nativeDocument isEqual:document] ||
        ![context.frame isEqual:frameId]) continue;
    NSDictionary* frame = ScriptFrame(tab, context);
    if (![S(frame, @"url") isEqual:S(state, @"url")] ||
        [frame[@"main"] boolValue] != [state[@"main"] boolValue]) continue;
    state[@"source"] = @{@"version": @1, @"frame": frame, @"nativeDocument": document};
    break;
  }
  // Native ownership is never replaced by a main-frame or visible-tab guess.
  return state;
}
static void NativePiPChanged(Tab* tab, CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefDictionaryValue> native) {
  if (!tab || tab->closing || !tab->browser || !browser || !tab->browser->IsSame(browser)) return;
  if (NSDictionary* state = NativePiPSnapshot(*tab, native)) Event(@"media.pip.changed", tab, state);
}
#endif
static bool NativePiPRequest(Tab& tab, NSString* method, NSDictionary* params, NSString* request) {
  if (![method isEqual:@"media.pip.state"] && ![method isEqual:@"media.pip.control"]) return false;
#if YABCORE_NATIVE_VIDEO_PIP
  if (!tab.browser || tab.closing || tab.internal || !tab.adopted ||
      (params[@"profile"] && ![S(params, @"profile") isEqual:@(tab.profile.c_str())])) {
    Reply(request, nil, @"Native PiP browser is unavailable or mismatched"); return true;
  }
  auto host = tab.browser->GetHost();
  if ([method isEqual:@"media.pip.state"]) {
    NSDictionary* state = NativePiPSnapshot(tab, host->GetNativeVideoPiPState());
    Reply(request, state, state ? nil : @"Native PiP state is unavailable"); return true;
  }
  NSString* action = S(params, @"action"), *token = S(params, @"token");
  CefSize size;
  if ([action isEqual:@"resize"]) {
    for (NSString* key in @[@"width", @"height"]) {
      id value = params[key];
      if (![value isKindOfClass:NSNumber.class] ||
          CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() ||
          !std::isfinite([value doubleValue]) || std::floor([value doubleValue]) != [value doubleValue] ||
          [value doubleValue] < 1 || [value doubleValue] > 3840) {
        Reply(request, nil, @"Native PiP size must contain finite positive integral dimensions"); return true;
      }
    }
    size = CefSize([params[@"width"] intValue], [params[@"height"] intValue]);
  }
  double controlValue = 0;
  NSString* numericKey = nil;
  if ([action isEqual:@"seek"] || [action isEqual:@"seekForward"] || [action isEqual:@"seekBackward"]) numericKey = @"seconds";
  if ([action isEqual:@"rate"]) numericKey = @"rate";
  if (numericKey) {
    id value = params[numericKey];
    if (![value isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() ||
        !std::isfinite([value doubleValue]) || [value doubleValue] < 0) {
      Reply(request, nil, @"Native PiP control requires a finite nonnegative numeric value"); return true;
    }
    controlValue = [value doubleValue];
  }
  if ([action isEqual:@"mute"] || [action isEqual:@"captions"]) {
    id value = params[@"enabled"];
    if (!value || CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()) {
      Reply(request, nil, @"Native PiP control requires an explicit boolean enabled"); return true;
    }
    controlValue = [value boolValue] ? 1 : 0;
  }
  bool dispatched = token.length && action.length && host->ControlNativeVideoPiP(Key(token), Key(action), size, controlValue);
  Reply(request, dispatched ? @{@"dispatched": @YES} : nil,
        dispatched ? nil : @"Native PiP token, action or geometry is stale or unsupported");
#else
  (void)tab; (void)params;
  Reply(request, nil, @"Native video-PiP is unavailable in this SDK/API mode");
#endif
  return true;
}
