// desktopCapture.chooseDesktopMedia (CEF patch 0122): Chrome's picker would
// open over a tab's concealed window, where nobody sees or answers it, so the
// request comes to the client, which shows Yab's own share box, and its answer
// is registered by Chrome as its picker's would be. The extension's
// getUserMedia then plays it with Chrome's own capture, as a page's
// getDisplayMedia does through patch 0052. Included after the consent section
// of owncef_native.inc (ConsentProfile) and owncef_capture.inc
// (NativeDisplaySource).
#if defined(CEF_YAB_EXTENSION_DESKTOP_MEDIA_VERSION) && YABCORE_EXTENSION_CONSENT && YABCORE_NATIVE_DISPLAY_SOURCE && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_EXTENSION_DESKTOP_MEDIA 1
struct DesktopMediaAsk { CefRefPtr<CefExtensionDesktopMediaCallback> callback; std::string profile; std::string extension; };
static std::map<std::string, DesktopMediaAsk> desktopMediaAsks;
// Releasing a callback refuses, as Chromium's Cancel.
static void ClearDesktopMedia() { desktopMediaAsks.clear(); }
static void NativeDesktopMediaRequest(Tab* tab, CefRefPtr<CefDictionaryValue> request,
                                      CefRefPtr<CefExtensionDesktopMediaCallback> callback) {
  if (!callback) return;
  NSMutableDictionary* copy = [NativeDictionary(request) mutableCopy];
  std::string token = Key(copy[@"request"] ?: @""), extension = Key(copy[@"extensionId"] ?: @"");
  // The page it is for: a tab Yab shows, or none (a worker's or an offscreen
  // document's ask), and then the profile its directory names.
  if (tab && (tab->closing || tab->internal || !tab->adopted || IsReadTab(tab))) tab = nullptr;
  NSString* profile = ConsentProfile(tab, copy);
  if (!hello || token.empty() || extension.empty() || !profile || desktopMediaAsks.count(token)) {
    callback->Choose("", false); return;
  }
  desktopMediaAsks[token] = {callback, Key(profile), extension};
  copy[@"profile"] = profile;
  [copy removeObjectForKey:@"profilePath"];
  if (tab) copy[@"tab"] = @(tab->id.c_str());
  Event(@"extension.desktopMedia", nullptr, copy);
}
static void NativeDesktopMediaWithdrawn(const std::string& token) {
  if (desktopMediaAsks.erase(token)) Event(@"extension.desktopMedia.withdrawn", nullptr, @{@"request": @(token.c_str())});
}
// {request, profile, extension, source: "" | "tab" (sourceTab) | "window" |
// "screen" (id), audio}. A stale or mismatched answer has no effect; a source
// that is gone refuses.
static bool DesktopMediaReply(NSDictionary* p, NSString* request) {
  auto found = desktopMediaAsks.find(Key(S(p, @"request") ?: @""));
  if (found == desktopMediaAsks.end() || found->second.extension != Key(S(p, @"extension") ?: @"") ||
      found->second.profile != Key(S(p, @"profile") ?: @"")) {
    Reply(request, nil, @"Unknown, stale or mismatched desktop media request"); return true;
  }
  auto callback = found->second.callback;
  desktopMediaAsks.erase(found);
  const std::string source = S(p, @"source").length ? NativeDisplaySource(p) : std::string();
  callback->Choose(source, [p[@"audio"] boolValue]);
  Reply(request, @{@"chosen": @(!source.empty())});
  return true;
}
#else
#define YABCORE_EXTENSION_DESKTOP_MEDIA 0
static void ClearDesktopMedia() {}
#endif
