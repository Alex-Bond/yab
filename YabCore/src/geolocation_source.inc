// Where the device is, for Chromium pages, from Yab. With CEF patch 0120 the
// browser process makes no CoreLocation manager of its own (Chrome's would,
// at startup, under Yab's bundle but signed as YabCore, and macOS then put up
// no window for Yab's own question: #1971). Yab asks macOS, as it does for
// WebKit pages (Whereabouts), and hands over its answer and its fixes:
// "geolocation.permission" {status: 0 not determined, 1 denied, 2 allowed},
// "geolocation.position" {latitude, longitude, accuracy, altitude?,
// altitudeAccuracy?, heading?, speed?, timestamp? (ms)} and
// "geolocation.error" {code, message}. Chromium's side comes out as events:
// "geolocation.watch" {watching, highAccuracy} and "geolocation.ask" (a
// page's <geolocation> element wants macOS asked).
#if YABCORE_GEOLOCATION_SOURCE
static CefRefPtr<CefGeolocationSource> geolocationSource;
static bool GeolocationRequest(NSString* method, NSDictionary* p, NSString* request) {
  if (![method hasPrefix:@"geolocation."]) return false;
  if (!geolocationSource) { Reply(request, nil, @"No location source in this helper"); return true; }
  auto number = [&](NSString* key) -> NSNumber* {
    id value = p[key];
    return [value isKindOfClass:NSNumber.class] && std::isfinite([value doubleValue]) ? value : nil;
  };
  if ([method isEqual:@"geolocation.permission"]) {
    NSNumber* status = number(@"status");
    if (!status || [status intValue] < 0 || [status intValue] > 2) { Reply(request, nil, @"status is 0, 1 or 2"); return true; }
    geolocationSource->SetPermission([status intValue]);
  } else if ([method isEqual:@"geolocation.position"]) {
    if (!number(@"latitude") || !number(@"longitude") || !number(@"accuracy")) { Reply(request, nil, @"latitude, longitude and accuracy are numbers"); return true; }
    auto fix = CefDictionaryValue::Create();
    for (NSString* key in @[@"latitude", @"longitude", @"accuracy", @"altitude", @"altitudeAccuracy", @"heading", @"speed", @"timestamp"])
      if (NSNumber* value = number(key)) fix->SetDouble(Key(key), [value doubleValue]);
    geolocationSource->SetPosition(fix);
  } else if ([method isEqual:@"geolocation.error"]) {
    NSString* message = [p[@"message"] isKindOfClass:NSString.class] ? p[@"message"] : @"";
    geolocationSource->SetError([number(@"code") intValue] == 1 ? 1 : 2, CefString(message.length > 512 ? [message substringToIndex:512].UTF8String : message.UTF8String));
  } else {
    Reply(request, nil, @"Unknown geolocation request"); return true;
  }
  Reply(request);
  return true;
}
#else
static bool GeolocationRequest(NSString*, NSDictionary*, NSString*) { return false; }
#endif
