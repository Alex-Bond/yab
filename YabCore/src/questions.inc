#include "media_permission_route.h"
// Native browser requests only. This registry is confined to the UI thread.
struct PageQuestion {
  std::string tab;
  std::function<void(NSDictionary*)> answer;
  uint64_t prompt = 0;
  bool isPrompt = false;
  bool isDialog = false;
  NSString* closeOwner = nil;
};
static std::map<std::string, PageQuestion> pageQuestions;
static std::map<std::string, int> authAttempts;
static void CancelQuestions(const std::string& tab) {
  std::vector<std::function<void(NSDictionary*)>> cancel;
  for (auto i = pageQuestions.begin(); i != pageQuestions.end();) {
    if (i->second.tab == tab) { cancel.push_back(i->second.answer); i = pageQuestions.erase(i); }
    else ++i;
  }
  for (auto& answer : cancel) answer(@{});
}
static void AskQuestion(Tab* tab, NSString* kind, NSDictionary* values,
                        std::function<void(NSDictionary*)> answer, uint64_t prompt = 0, bool isPrompt = false) {
  if (!tab || tab->closing || pageQuestions.size() >= 128) { answer(@{}); return; }
  NSString* token = NSUUID.UUID.UUIDString;
  pageQuestions.emplace(Key(token), PageQuestion{tab->id, answer, prompt, isPrompt});
  NSMutableDictionary* p = [values mutableCopy]; p[@"request"] = token; p[@"kind"] = kind;
  p[@"profile"] = @(tab->profile.c_str());
  Event(@"question.open", tab, p);
}
static bool QuestionRequest(Tab& tab, NSString* method, NSDictionary* p, NSString* request) {
  if (![method isEqual:@"question.reply"]) return false;
  auto i = pageQuestions.find(Key(S(p, @"request")));
  if (i == pageQuestions.end() || i->second.tab != tab.id || i->second.isDialog) {
    Reply(request, nil, @"No matching page question"); return true;
  }
  auto answer = i->second.answer;
  pageQuestions.erase(i);
  Reply(request);
  answer(p);
  return true;
}
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
    [callback, mask, tabID = tab->id, origin](NSDictionary* p) {
      callback->Continue([p[@"allow"] boolValue] ? mask : 0);
      std::vector<cef_content_setting_types_t> types;
      if (mask & CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE) types.push_back(CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_CAMERA);
      if (mask & CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE) types.push_back(CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_MIC);
      ForgetGrant(tabID, origin, types);
    });
  return true;
}
static bool AskPermission(Tab* tab, uint64_t prompt, NSString* origin, uint32_t mask,
                          CefRefPtr<CefPermissionPromptCallback> callback) {
  if (!callback) return true;
  if (!tab || tab->closing) { callback->Continue(CEF_PERMISSION_RESULT_DENY); return true; }
  NSString* kind = nil;
  if (mask == CEF_PERMISSION_TYPE_MULTIPLE_DOWNLOADS) {
    // Every native OnBeforeDownload still waits for Yab's destination/policy
    // callback. Delegate Chrome's additional gate to that existing per-file
    // decision, rather than suppressing the second Yab download question.
    callback->Continue(tab && !tab->closing && !tab->internal && tab->adopted ?
                       CEF_PERMISSION_RESULT_ACCEPT : CEF_PERMISSION_RESULT_DENY);
    return true;
  }
  if (mask == CEF_PERMISSION_TYPE_GEOLOCATION) kind = @"location";
  else if (mask == CEF_PERMISSION_TYPE_NOTIFICATIONS) kind = @"notifications";
  else if (mask && !(mask & ~(CEF_PERMISSION_TYPE_CAMERA_STREAM | CEF_PERMISSION_TYPE_MIC_STREAM))) kind = @"capture";
  if (!kind) { callback->Continue(CEF_PERMISSION_RESULT_DENY); return true; }
  AskQuestion(tab, kind, @{@"origin": origin, @"camera": @((mask & CEF_PERMISSION_TYPE_CAMERA_STREAM) != 0),
                          @"microphone": @((mask & CEF_PERMISSION_TYPE_MIC_STREAM) != 0)},
    [callback, tabID = tab->id, origin, kind, mask](NSDictionary* p) {
      callback->Continue([p[@"allow"] boolValue] ? CEF_PERMISSION_RESULT_ACCEPT : CEF_PERMISSION_RESULT_DENY);
      std::vector<cef_content_setting_types_t> types;
      if ([kind isEqual:@"location"]) types.push_back(CEF_CONTENT_SETTING_TYPE_GEOLOCATION);
      if (mask & CEF_PERMISSION_TYPE_CAMERA_STREAM) types.push_back(CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_CAMERA);
      if (mask & CEF_PERMISSION_TYPE_MIC_STREAM) types.push_back(CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_MIC);
      if (!types.empty()) ForgetGrant(tabID, origin, types);
    }, prompt, true);
  return true;
}
static void DismissPermission(Tab* tab, uint64_t prompt) {
  if (!tab) return;
  const bool emit = !IsReadTab(tab);
  NSMutableArray<NSDictionary*>* closed = [NSMutableArray array];
  std::vector<std::function<void(NSDictionary*)>> retained;
  for (auto i = pageQuestions.begin(); i != pageQuestions.end();) {
    if (i->second.tab == tab->id && i->second.prompt == prompt && i->second.isPrompt) {
      [closed addObject:@{@"request": @(i->first.c_str()), @"tab": @(tab->id.c_str()),
        @"profile": @(tab->profile.c_str()), @"prompt": @(std::to_string(prompt).c_str()),
        @"reason": @"native-dismissed"}];
      retained.push_back(i->second.answer);
      i = pageQuestions.erase(i);
    }
    else ++i;
  }
  // Erase every terminal native callback before wire delivery can reenter
  // shutdown and mutate the map or destroy the original Tab. Retain callback
  // references until then as well; their destructors must not reenter erase.
  if (emit) for (NSDictionary* packet in closed) Event(@"question.closed", nullptr, packet);
}
static void AskAuthentication(CefRefPtr<CefBrowser> browser, NSString* origin, bool proxy,
                             NSString* host, int port, NSString* realm, NSString* scheme,
                             CefRefPtr<CefAuthCallback> callback) {
  // GetAuthCredentials originates on CEF's IO thread. Never touch the tab or
  // wire registries until this block reaches the browser UI thread.
  dispatch_async(dispatch_get_main_queue(), ^{
    auto tab = Find(browser);
    if (!tab || proxy) { callback->Cancel(); return; }
    std::string key = tab->id + "|" + Key(JSON(@[host, @(port), realm, scheme]));
    int failures = authAttempts[key];
    AskQuestion(tab, @"auth", @{@"origin": origin, @"host": host, @"port": @(port),
                               @"realm": realm, @"scheme": scheme, @"failures": @(failures)},
      [callback, key](NSDictionary* p) {
        if (![p[@"allow"] boolValue]) { callback->Cancel(); return; }
        authAttempts[key] += 1;
        callback->Continue(Key(S(p, @"user")), Key(S(p, @"password")));
      });
  });
}
