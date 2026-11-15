#include "media_permission_route.h"
#include "page_questions.inc"
static bool AskMedia(Tab* tab, NSString* origin, uint32_t mask, CefRefPtr<CefMediaAccessCallback> callback, bool sameBrowserFrame) {
  if (!callback) return true;
  const uint32_t devices = CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE | CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE;
  const uint32_t desktop = CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE | CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE;
  const yabcore::MediaPermissionOwner owner{tab != nullptr, !tab || tab->closing,
      IsReadTab(tab), tab && tab->adopted, !tab || tab->internal, sameBrowserFrame};
  const auto route = yabcore::ClassifyMediaPermission(mask, devices, desktop, owner);
  if (route == yabcore::MediaPermissionRoute::kDeny) { callback->Cancel(); return true; }
  if (route == yabcore::MediaPermissionRoute::kChromeDefault) {
    // Leave ORIGINAL callback untouched: CEF Chrome delegate then performs
    // original request/registry/picker checks. This is not an allow or stop ACK.
    return false;
  }
  AskQuestion(tab, @"capture", @{@"origin": origin, @"camera": @((mask & CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE) != 0),
                               @"microphone": @((mask & CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE) != 0)},
    // This path writes nothing into Chromium. A remembered answer reaches it
    // through permission.set, whoever asked.
    [callback, mask](NSDictionary* p) { callback->Continue([p[@"allow"] boolValue] ? mask : 0); });
  return true;
}
// What Chromium keeps of an answer the moment it is given, by the bits asked.
static std::vector<cef_content_setting_types_t> PromptTypes(uint32_t mask) {
  std::vector<cef_content_setting_types_t> types;
  if (mask & CEF_PERMISSION_TYPE_GEOLOCATION) types.push_back(CEF_CONTENT_SETTING_TYPE_GEOLOCATION);
  if (mask & CEF_PERMISSION_TYPE_NOTIFICATIONS) types.push_back(CEF_CONTENT_SETTING_TYPE_NOTIFICATIONS);
  if (mask & CEF_PERMISSION_TYPE_CAMERA_STREAM) types.push_back(CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_CAMERA);
  if (mask & CEF_PERMISSION_TYPE_MIC_STREAM) types.push_back(CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_MIC);
  if (mask & CEF_PERMISSION_TYPE_CAMERA_PAN_TILT_ZOOM) types.push_back(CEF_CONTENT_SETTING_TYPE_CAMERA_PAN_TILT_ZOOM);
  for (const auto& bit : kGrantBits) {
    if (!(mask & bit.bit)) continue;
    if (auto type = GrantType(bit.name)) types.push_back(*type);
  }
  return types;
}
// A refusal Yab did not decide, for a page no one can be asked for: the
// answer is for this request, and Chromium keeps none of it.
static void RefusePrompt(const std::string& tab, NSString* origin, uint32_t mask, CefRefPtr<CefPermissionPromptCallback> callback) {
  callback->Continue(CEF_PERMISSION_RESULT_DENY);
  ForgetGrant(tab, origin, PromptTypes(mask));
}
// A page's second file: Chromium's DownloadRequestLimiter asks about the
// site's automatic downloads, and keeps the answer as Chromium keeps the
// person's, for good: an Allow as the origin's AUTOMATIC_DOWNLOADS = ALLOW
// (TabDownloadState::Accept), a Deny as BLOCK (Cancel). Only a dismissal
// refuses the files once and keeps nothing (CancelOnce), as Chromium's bubble
// left unanswered. Nobody answers here: a tab Yab shows lets every file on
// to Yab's own card (OnBeforeDownload, SiteDownloads), and Chromium's copy
// of that Allow is forgotten; a tab nobody can be asked for (not adopted
// yet, closing, a task read page, an internal one) is refused this once. A
// Deny there kept the site blocked: past a click's first file every one
// was dropped before Yab saw it, unasked, in every tab of the profile, with
// nothing in Site Controls. What Chromium holds for a site's automatic
// downloads is only what Yab writes (permission.set, ChromiumPermissions).
static void AnswerDownloads(Tab* tab, NSString* origin, CefRefPtr<CefPermissionPromptCallback> callback) {
  if (!tab || tab->closing || tab->internal || !tab->adopted || IsReadTab(tab)) {
    callback->Continue(CEF_PERMISSION_RESULT_DISMISS);
    return;
  }
  callback->Continue(CEF_PERMISSION_RESULT_ACCEPT);
  ForgetGrant(tab->id, origin, {CEF_CONTENT_SETTING_TYPE_AUTOMATIC_DOWNLOADS});
}
// The tab whose native prompt answer Chromium is applying right now.
static std::string answeringPrompt;
static bool AskPermission(Tab* tab, uint64_t prompt, NSString* origin, uint32_t mask,
                          CefRefPtr<CefPermissionPromptCallback> callback) {
  if (!callback) return true;
  // A request the page's <geolocation>/<usermedia>/<permission> element made
  // runs Chromium's embedded prompt flow. Allowing it does not end it: when
  // macOS has not granted Yab that permission yet, or refused it,
  // PermissionRequestManager recreates the prompt, from inside that Allow,
  // for the same requests, now decided, to show a system step (Chrome's "Yab
  // needs macOS permission" bubble, which offers no Allow or Deny). A second
  // Allow or Deny decided them again: CHECK on the consumed
  // permission_decided_callback_ in PermissionGranted/PermissionDenied
  // (reports 623 to 1550). No other prompt opens synchronously inside an
  // answer; new requests are dequeued in a posted task. Close the step as
  // Chrome's bubble closes. cef-patches/0101 keeps it from the client.
  if (tab && !answeringPrompt.empty() && answeringPrompt == tab->id) {
    fprintf(stderr, "YabCore permission: system step %llu of an answered element request closed\n",
            (unsigned long long)prompt);
    callback->Continue(CEF_PERMISSION_RESULT_DISMISS);
    return true;
  }
  if (mask == CEF_PERMISSION_TYPE_MULTIPLE_DOWNLOADS) { AnswerDownloads(tab, origin, callback); return true; }
  if (!tab || tab->closing) { callback->Continue(CEF_PERMISSION_RESULT_DENY); return true; }
  if (IsReadTab(tab)) { RefusePrompt(tab->id, origin, mask, callback); return true; }
  NSString* kind = nil;
  NSMutableArray<NSString*>* asked = [NSMutableArray array];
  const uint32_t capture = CEF_PERMISSION_TYPE_CAMERA_STREAM | CEF_PERMISSION_TYPE_MIC_STREAM | CEF_PERMISSION_TYPE_CAMERA_PAN_TILT_ZOOM;
  if (mask == CEF_PERMISSION_TYPE_GEOLOCATION) kind = @"location";
  else if (mask == CEF_PERMISSION_TYPE_NOTIFICATIONS) kind = @"notifications";
  else if ((mask & capture) && !(mask & ~capture)) kind = @"capture";
  else {
    uint32_t unmapped = mask;
    for (const auto& bit : kGrantBits) if (mask & bit.bit) {
      [asked addObject:bit.name];
      unmapped &= ~bit.bit;
    }
    // Continue accepts the entire mask, never just the bits named on the card.
    if (asked.count && !unmapped) kind = @"permission";
  }
  // A feature with nothing behind it on this Mac (AR, VR, hand tracking).
  if (!kind) {
    static std::set<uint32_t> logged;
    if (logged.insert(mask).second)
      fprintf(stderr, "YabCore permission: unmapped mask 0x%08x denied\n", mask);
    RefusePrompt(tab->id, origin, mask, callback);
    return true;
  }
  NSString* top = @(GrantTopLevel(tab->id).c_str());
  AskQuestion(tab, kind, @{@"origin": origin, @"top": top, @"permissions": asked,
                          @"camera": @((mask & CEF_PERMISSION_TYPE_CAMERA_STREAM) != 0),
                          @"microphone": @((mask & CEF_PERMISSION_TYPE_MIC_STREAM) != 0)},
    [callback, tabID = tab->id, origin, mask](NSDictionary* p) {
      const std::string outer = answeringPrompt;
      answeringPrompt = tabID;
      callback->Continue([p[@"allow"] boolValue] ? CEF_PERMISSION_RESULT_ACCEPT : CEF_PERMISSION_RESULT_DENY);
      answeringPrompt = outer;
      if (![p[@"keep"] boolValue]) ForgetGrant(tabID, origin, PromptTypes(mask));
    }, prompt, true);
  return true;
}
static void AskAuthentication(CefRefPtr<CefBrowser> browser, NSString* origin, bool proxy,
                             NSString* host, int port, NSString* realm, NSString* scheme,
                             CefRefPtr<CefAuthCallback> callback) {
  // GetAuthCredentials originates on CEF's IO thread. Never touch the tab or
  // wire registries until this block reaches the browser UI thread.
  dispatch_async(dispatch_get_main_queue(), ^{
    auto tab = Find(browser);
    if (!tab) { callback->Cancel(); return; }
    std::string key = tab->id + "|" + Key(JSON(@[host, @(port), realm, scheme]));
    int failures = authAttempts[key];
    auto proxyPreference = browser->GetHost()->GetRequestContext()->GetPreference("proxy");
    NSString* proxyConfiguration = proxyPreference ? Str(CefWriteJSON(proxyPreference, JSON_WRITER_DEFAULT)) : @"";
    AskQuestion(tab, @"auth", @{@"origin": origin, @"host": host, @"port": @(port), @"proxy": @(proxy),
                               @"realm": realm, @"scheme": scheme, @"failures": @(failures),
                               @"proxyConfiguration": proxyConfiguration},
      [callback, key](NSDictionary* p) {
        if (![p[@"allow"] boolValue]) { callback->Cancel(); return; }
        authAttempts[key] += 1;
        callback->Continue(Key(S(p, @"user")), Key(S(p, @"password")));
      });
  });
}
