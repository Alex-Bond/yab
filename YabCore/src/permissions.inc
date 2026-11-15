// Yab owns every camera, microphone and location decision (its card, its
// remembered sites, its Settings). Chromium would also keep an Allow or Block
// from a prompt in its own profile and then never ask Yab again, so a site
// the person turned off in Yab kept its access. Each decision is therefore
// forgotten by Chromium once it has been applied to the request that asked.
// Notifications are left alone: a page reads Notification.permission without
// asking, so Chromium's value has to keep following Yab's remembered answer.
#include "include/cef_request_context.h"

static const cef_content_setting_types_t kGrantTypes[] = {
  CEF_CONTENT_SETTING_TYPE_GEOLOCATION, CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_MIC,
  CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_CAMERA, CEF_CONTENT_SETTING_TYPE_NOTIFICATIONS,
};
static NSString* GrantName(cef_content_setting_types_t type) {
  switch (type) {
    case CEF_CONTENT_SETTING_TYPE_GEOLOCATION: return @"location";
    case CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_MIC: return @"microphone";
    case CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_CAMERA: return @"camera";
    default: return @"notifications";
  }
}
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
static void ForgetGrant(const std::string& tab, NSString* origin, std::vector<cef_content_setting_types_t> types) {
  std::string site = Key(origin), top = GrantTopLevel(tab);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 400 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    auto context = GrantContext(tab);
    if (!context) return;
    for (auto type : types) {
      context->SetContentSetting(site, site, type, CEF_CONTENT_SETTING_VALUE_DEFAULT);
      if (!top.empty()) context->SetContentSetting(site, top, type, CEF_CONTENT_SETTING_VALUE_DEFAULT);
    }
  });
}
// Test and diagnostic read of what Chromium holds for a site.
static bool PermissionRequest(Tab& tab, NSString* method, NSDictionary* p, NSString* request) {
  if (![method isEqual:@"permission.state"]) return false;
  auto context = GrantContext(tab.id);
  NSString* origin = S(p, @"origin");
  if (!context || !origin.length) { Reply(request, nil, @"No page or origin"); return true; }
  std::string site = Key(origin), top = GrantTopLevel(tab.id);
  NSMutableDictionary* values = [NSMutableDictionary new];
  for (auto type : kGrantTypes) {
    values[GrantName(type)] = @{@"origin": @((int)context->GetContentSetting(site, site, type)),
                                @"top": @((int)context->GetContentSetting(site, top, type))};
  }
  Reply(request, @{@"values": values});
  return true;
}
