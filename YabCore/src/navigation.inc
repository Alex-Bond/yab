// Included by core.mm so navigation shares its private tab registry and wire.
// CEF callbacks stay here; the app receives values and opaque request IDs.
#if defined(CEF_YAB_NATIVE_FILE_CONTEXT_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_NATIVE_FILE_SOURCE 1
#else
#define YABCORE_NATIVE_FILE_SOURCE 0
#endif

struct FilePick {
  CefRefPtr<CefFileDialogCallback> callback;
  NSString* token;
  bool multiple;
  NSDictionary* native = nil;
};
static std::map<std::string, FilePick> filePicks;
// Bind the accepted native chooser to a live Runtime document. Frame tokens
// come from Chromium's native DocumentToken, never from page-supplied values.
static NSDictionary* NativeFileSource(Tab& tab, const FilePick& pick) {
#if YABCORE_NATIVE_FILE_SOURCE
  if (!pick.native || !pick.callback->IsNativeRequestValid()) return nil;
  NSDictionary* native = pick.native;
  for (const auto& [key, context] : tab.scripts.contexts) {
    if (!context.isDefault || !context.nativeDocument.length ||
        ![context.nativeDocument isEqual:S(native, @"document")] ||
        ![context.frame isEqual:S(native, @"frameId")]) continue;
    NSDictionary* frame = ScriptFrame(tab, context);
    if (![S(frame, @"url") isEqual:S(native, @"url")] ||
        [frame[@"main"] boolValue] != [native[@"main"] boolValue]) continue;
    NSURL* origin = [NSURL URLWithString:S(native, @"origin")];
    if (![S(frame, @"scheme") isEqual:origin.scheme ?: @""] ||
        ![S(frame, @"host") isEqual:origin.host ?: @""] ||
        [frame[@"port"] integerValue] != (origin.port ?: @0).integerValue) continue;
    return @{@"version": @1, @"request": pick.token, @"frame": frame,
             @"session": context.session, @"nativeDocument": context.nativeDocument};
  }
#endif
  return nil;
}
static void CancelFilePick(const std::string& tab) {
  auto found = filePicks.find(tab);
  if (found == filePicks.end()) return;
  auto callback = found->second.callback;
  NSString* token = found->second.token;
  filePicks.erase(found);
  auto owner = tabs.find(tab);
  if (owner != tabs.end()) Event(@"file.closed", &owner->second, @{@"request": token, @"reason": @"cancelled"});
  callback->Cancel();
}
static bool OpenFilePick(Tab* tab, cef_file_dialog_mode_t mode, CefRefPtr<CefFileDialogCallback> callback, NSDictionary* native = nil) {
  // Save dialogs belong to downloads, not the upload chooser.
  if (!tab || mode == FILE_DIALOG_SAVE) { callback->Cancel(); return true; }
  CancelFilePick(tab->id);
  NSString* token = native ? S(native, @"request") : NSUUID.UUID.UUIDString;
  if (!token.length) { callback->Cancel(); return true; }
  filePicks.emplace(tab->id, FilePick{callback, token, mode == FILE_DIALOG_OPEN_MULTIPLE, native});
  NSMutableDictionary* params = [@{@"request": token, @"directories": @(mode == FILE_DIALOG_OPEN_FOLDER),
                                    @"multiple": @(mode == FILE_DIALOG_OPEN_MULTIPLE)} mutableCopy];
  if (NSDictionary* source = NativeFileSource(*tab, filePicks.at(tab->id))) params[@"source"] = source;
  Event(@"file.open", tab, params);
  return true;
}
static bool NavigationRequest(Tab& tab, NSString* method, NSDictionary* p, NSString* request) {
  if ([method isEqual:@"page.crashForTesting"]) {
    if (!CefCommandLine::GetGlobalCommandLine()->HasSwitch("use-mock-keychain")) {
      Reply(request, nil, @"Renderer crash is test-only"); return true;
    }
    Reply(request);
    CDP(tab, @"Page.crash", @{}, Ignore);
    return true;
  }
  if ([method isEqual:@"page.zoom"]) {
    double factor = [p[@"factor"] respondsToSelector:@selector(doubleValue)] ? [p[@"factor"] doubleValue] : 0;
    if (!std::isfinite(factor) || factor < 0.25 || factor > 10) {
      Reply(request, nil, @"Invalid page zoom"); return true;
    }
    tab.browser->GetHost()->SetZoomLevel(std::log(factor) / std::log(1.2));
    Reply(request); return true;
  }
#if YABCORE_NATIVE_FILE_SOURCE
  if ([method isEqual:@"file.nativeSource"]) {
    if (!CefCommandLine::GetGlobalCommandLine()->HasSwitch("use-mock-keychain")) {
      Reply(request, nil, @"Native file diagnostics are test-only"); return true;
    }
    auto pick = filePicks.find(tab.id);
    if (pick == filePicks.end() || !pick->second.native ||
        ![pick->second.token isEqual:S(p, @"request")] ||
        !pick->second.callback->IsNativeRequestValid()) {
      Reply(request, nil, @"No matching live native chooser"); return true;
    }
    NSDictionary* authenticated = NativeFileSource(tab, pick->second);
    Reply(request, @{@"native": pick->second.native, @"authenticated": authenticated ?: (::id)NSNull.null,
                     @"productionSourceV1": @YES}); return true;
  }
#endif
  if (![method isEqual:@"file.reply"]) return false;
  auto found = filePicks.find(tab.id);
  if (found == filePicks.end() || ![found->second.token isEqual:S(p, @"request")]) {
    Reply(request, nil, @"No matching file chooser"); return true;
  }
#if YABCORE_NATIVE_FILE_SOURCE
  if (found->second.native && !found->second.callback->IsNativeRequestValid()) {
    CancelFilePick(tab.id);
    Reply(request, nil, @"The native upload document retired"); return true;
  }
#endif
  id paths = p[@"paths"];
  if (paths && ![paths isKindOfClass:NSArray.class]) { Reply(request, nil, @"paths must be an array"); return true; }
  if ([paths count] > (found->second.multiple ? 1024 : 1)) { Reply(request, nil, @"Too many selected paths"); return true; }
  std::vector<CefString> selected;
  for (id path in paths) {
    if (![path isKindOfClass:NSString.class] || ![path isAbsolutePath]) {
      Reply(request, nil, @"Selected paths must be absolute"); return true;
    }
    NSData* bytes = [path dataUsingEncoding:NSUTF8StringEncoding];
    std::string native(bytes ? static_cast<const char*>(bytes.bytes) : "", bytes.length);
    if (native.find('\0') != std::string::npos) { Reply(request, nil, @"Selected path contains NUL"); return true; }
    selected.emplace_back(native);
  }
  auto callback = found->second.callback;
  filePicks.erase(found);
  Reply(request);
  if (selected.empty()) callback->Cancel(); else callback->Continue(selected);
  return true;
}
