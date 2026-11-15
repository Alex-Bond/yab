// Yab owns every site decision (its card, its remembered sites, its Settings).
// Chromium's own settings hold Yab's answer, so what a page reads for a site
// Yab remembers, navigator.permissions.query and Notification.permission, is
// the truth: `permission.set` writes each remembered decision and takes it
// back. An answer given only to the request that asked ("keep": false, a box
// left unticked, a card that went away) was never Yab's to remember, and
// Chromium's copy of it is forgotten once it has been applied.
#include <optional>
#include "include/cef_request_context.h"

struct GrantKind { NSString* name; cef_content_setting_types_t type; };
static const GrantKind kGrantKinds[] = {
  {@"location", CEF_CONTENT_SETTING_TYPE_GEOLOCATION}, {@"microphone", CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_MIC},
  {@"camera", CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_CAMERA}, {@"notifications", CEF_CONTENT_SETTING_TYPE_NOTIFICATIONS},
  {@"pan-tilt-zoom", CEF_CONTENT_SETTING_TYPE_CAMERA_PAN_TILT_ZOOM}, {@"clipboard", CEF_CONTENT_SETTING_TYPE_CLIPBOARD_READ_WRITE},
  {@"storage", CEF_CONTENT_SETTING_TYPE_STORAGE_ACCESS}, {@"top-storage", CEF_CONTENT_SETTING_TYPE_TOP_LEVEL_STORAGE_ACCESS},
  {@"fonts", CEF_CONTENT_SETTING_TYPE_LOCAL_FONTS}, {@"windows", CEF_CONTENT_SETTING_TYPE_WINDOW_MANAGEMENT},
  {@"idle", CEF_CONTENT_SETTING_TYPE_IDLE_DETECTION}, {@"midi", CEF_CONTENT_SETTING_TYPE_MIDI_SYSEX},
  {@"pointer", CEF_CONTENT_SETTING_TYPE_POINTER_LOCK}, {@"keyboard", CEF_CONTENT_SETTING_TYPE_KEYBOARD_LOCK},
  {@"local-network", CEF_CONTENT_SETTING_TYPE_LOCAL_NETWORK}, {@"loopback-network", CEF_CONTENT_SETTING_TYPE_LOOPBACK_NETWORK},
  {@"surface", CEF_CONTENT_SETTING_TYPE_CAPTURED_SURFACE_CONTROL}, {@"sensors", CEF_CONTENT_SETTING_TYPE_SENSORS},
  {@"automatic-downloads", CEF_CONTENT_SETTING_TYPE_AUTOMATIC_DOWNLOADS}, {@"popups", CEF_CONTENT_SETTING_TYPE_POPUPS},
};
static std::optional<cef_content_setting_types_t> GrantType(NSString* name) {
  for (const auto& kind : kGrantKinds) if ([kind.name isEqualToString:name]) return kind.type;
  return std::nullopt;
}
// Each bit of a prompt's request by the name Yab decides it under. A bit with
// no name here is a feature with nothing to show on this Mac. "files" is File
// System Access asking to read or change a file or folder the page picked:
// Chromium's own tab-modal dialog for it has no host here, and CEF patch 0097
// sends it to OnShowPermissionPrompt instead (#1683). Its grant lives with the
// handle, so it has no content setting and nothing to forget.
struct GrantBit { uint32_t bit; NSString* name; };
static const GrantBit kGrantBits[] = {
  {CEF_PERMISSION_TYPE_CLIPBOARD, @"clipboard"}, {CEF_PERMISSION_TYPE_STORAGE_ACCESS, @"storage"},
  {CEF_PERMISSION_TYPE_TOP_LEVEL_STORAGE_ACCESS, @"top-storage"}, {CEF_PERMISSION_TYPE_LOCAL_FONTS, @"fonts"},
  {CEF_PERMISSION_TYPE_WINDOW_MANAGEMENT, @"windows"}, {CEF_PERMISSION_TYPE_IDLE_DETECTION, @"idle"},
  {CEF_PERMISSION_TYPE_MIDI_SYSEX, @"midi"}, {CEF_PERMISSION_TYPE_POINTER_LOCK, @"pointer"},
  {CEF_PERMISSION_TYPE_KEYBOARD_LOCK, @"keyboard"}, {CEF_PERMISSION_TYPE_LOCAL_NETWORK, @"local-network"},
  {CEF_PERMISSION_TYPE_LOOPBACK_NETWORK, @"loopback-network"}, {CEF_PERMISSION_TYPE_CAPTURED_SURFACE_CONTROL, @"surface"},
  {CEF_PERMISSION_TYPE_REGISTER_PROTOCOL_HANDLER, @"protocol"}, {CEF_PERMISSION_TYPE_FILE_SYSTEM_ACCESS, @"files"},
  {CEF_PERMISSION_TYPE_DISK_QUOTA, @"quota"},
};
static CefRefPtr<CefRequestContext> GrantContext(const std::string& tab) {
  auto found = tabs.find(tab);
  if (found == tabs.end() || found->second.closing || !found->second.browser) return nullptr;
  return found->second.browser->GetHost()->GetRequestContext();
}
static std::string GrantTopLevel(const std::string& tab) {
  auto found = tabs.find(tab);
  if (found == tabs.end() || !found->second.browser || !found->second.browser->GetMainFrame()) return "";
  return found->second.browser->GetMainFrame()->GetURL().ToString();
}
// The tab's id by value: a block holds a C++ reference as a reference, and the
// question's closure that owns the string is gone by the time this runs.
static void ForgetGrant(std::string tab, NSString* origin, std::vector<cef_content_setting_types_t> types) {
  std::string site = Key(origin), top = GrantTopLevel(tab);
  // Held here: the tab may close within the wait, and a grant left behind
  // would never ask Yab again.
  auto context = GrantContext(tab);
  if (!context) return;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 400 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    for (auto type : types) {
      context->SetContentSetting(site, site, type, CEF_CONTENT_SETTING_VALUE_DEFAULT);
      if (!top.empty()) context->SetContentSetting(site, top, type, CEF_CONTENT_SETTING_VALUE_DEFAULT);
    }
  });
}
// Yab's decisions, written into a profile's own settings: entries of
// {origin, top?, kind, value}, value "allow", "block" or "default".
static bool PermissionProfileRequest(NSString* method, NSDictionary* p, NSString* request) {
  if (![method isEqual:@"permission.set"]) return false;
  auto profile = profiles.find(Key(S(p, @"profile")));
  if (profile == profiles.end()) { Reply(request, nil, @"Unknown profile"); return true; }
  // A private profile keeps nothing, Yab's answers included.
  if (profile->second.privateMode) { Reply(request, @{@"written": @0}); return true; }
  NSArray* entries = [p[@"entries"] isKindOfClass:NSArray.class] ? p[@"entries"] : @[];
  int written = 0;
  for (NSDictionary* entry in entries) {
    if (![entry isKindOfClass:NSDictionary.class]) continue;
    auto type = GrantType(S(entry, @"kind"));
    NSString* origin = S(entry, @"origin"), * said = S(entry, @"value");
    if (!type || !origin.length) continue;
    auto value = [said isEqual:@"allow"] ? CEF_CONTENT_SETTING_VALUE_ALLOW :
      [said isEqual:@"block"] ? CEF_CONTENT_SETTING_VALUE_BLOCK : CEF_CONTENT_SETTING_VALUE_DEFAULT;
    NSString* top = S(entry, @"top");
    profile->second.context->SetContentSetting(Key(origin), Key(top.length ? top : origin), *type, value);
    ++written;
  }
  Reply(request, @{@"written": @(written)});
  return true;
}
// Test and diagnostic read of what Chromium holds for a site.
static bool PermissionRequest(Tab& tab, NSString* method, NSDictionary* p, NSString* request) {
  if (![method isEqual:@"permission.state"]) return false;
  auto context = GrantContext(tab.id);
  NSString* origin = S(p, @"origin");
  if (!context || !origin.length) { Reply(request, nil, @"No page or origin"); return true; }
  std::string site = Key(origin), top = GrantTopLevel(tab.id);
  NSMutableDictionary* values = [NSMutableDictionary new];
  for (const auto& kind : kGrantKinds) {
    values[kind.name] = @{@"origin": @((int)context->GetContentSetting(site, site, kind.type)),
                          @"top": @((int)context->GetContentSetting(site, top, kind.type))};
  }
  Reply(request, @{@"values": values});
  return true;
}
