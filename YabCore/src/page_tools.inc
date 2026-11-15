// What Yab's page tools need of a Chromium tab beyond scripts: the connection
// Site Controls describes and device mode. Included in core.mm after scripts.inc.

// The certificate the page in front was served with, leaf first.
static NSDictionary* PageCertificate(Tab& t) {
  if (!t.browser) return @{};
  auto entry = t.browser->GetHost()->GetVisibleNavigationEntry();
  auto status = entry ? entry->GetSSLStatus() : nullptr;
  auto certificate = status ? status->GetX509Certificate() : nullptr;
  if (!certificate) return @{};
  CefX509Certificate::IssuerChainBinaryList chain;
  certificate->GetDEREncodedIssuerChain(chain);
  chain.insert(chain.begin(), certificate->GetDEREncoded());
  NSMutableArray* encoded = [NSMutableArray array];
  for (auto bytes : chain) {
    if (!bytes || !bytes->GetSize() || bytes->GetSize() > 65536 || encoded.count >= 16) break;
    NSMutableData* data = [NSMutableData dataWithLength:bytes->GetSize()];
    if (bytes->GetData(data.mutableBytes, data.length, 0) != data.length) break;
    [encoded addObject:[data base64EncodedStringWithOptions:0]];
  }
  return @{@"chain": encoded, @"url": Str(entry->GetURL()), @"status": @((int)status->GetCertStatus())};
}

// Device mode: the size the page lays out at, the scale it is drawn at, and
// what it is told it runs in. Nothing in the parameters clears each.
static void PageEmulate(Tab& t, NSDictionary* p, NSString* request) {
  auto commands = std::make_shared<ScriptCommands>();
  double width = [p[@"width"] doubleValue], height = [p[@"height"] doubleValue];
  if (width > 0 && height > 0) {
    bool mobile = [p[@"mobile"] boolValue];
    commands->push_back({@"Emulation.setDeviceMetricsOverride", @{@"width": @((int)width), @"height": @((int)height),
      @"deviceScaleFactor": @0, @"mobile": @(mobile), @"scale": p[@"scale"] ?: @1}});
    commands->push_back({@"Emulation.setTouchEmulationEnabled", @{@"enabled": @(mobile)}});
  } else {
    commands->push_back({@"Emulation.clearDeviceMetricsOverride", @{}});
    commands->push_back({@"Emulation.setTouchEmulationEnabled", @{@"enabled": @NO}});
  }
  commands->push_back({@"Emulation.setUserAgentOverride", @{@"userAgent": S(p, @"userAgent")}});
  ScriptRun(t.id, @"", commands, 0, [request](NSDictionary*, NSString* error) { Reply(request, @{}, error); });
}

// The profile's own preference: PrefsTabHelper hands it to the renderers.
static void PageMinimumFont(Tab& t, int size) {
  if (!t.browser) return;
  auto value = CefValue::Create();
  value->SetInt(size);
  CefString error;
  t.browser->GetHost()->GetRequestContext()->SetPreference("webkit.webprefs.minimum_font_size", value, error);
}

// Settings › Websites › Fonts as Chromium's own font settings, the profile's
// generic families: a page that asks for serif, sans-serif or monospace, or
// says nothing, gets the face chosen with no script in the page looking at its
// elements (#1889: that look cost 14% of Speedometer). An empty name puts
// Chrome's default back. PrefsTabHelper hands a changed one to the renderers;
// the same value again changes nothing.
static void PageFamilies(Tab& t, NSDictionary* p) {
  if (!t.browser) return;
  auto context = t.browser->GetHost()->GetRequestContext();
  const std::pair<NSString*, const char*> kinds[] = {
      {@"standard", "webkit.webprefs.fonts.standard.Zyyy"},
      {@"serif", "webkit.webprefs.fonts.serif.Zyyy"},
      {@"sans", "webkit.webprefs.fonts.sansserif.Zyyy"},
      {@"fixed", "webkit.webprefs.fonts.fixed.Zyyy"}};
  for (const auto& [key, pref] : kinds) {
    NSString* name = S(p, key);
    CefRefPtr<CefValue> value;
    if (name.length) {
      value = CefValue::Create();
      value->SetString(name.UTF8String);
    }
    CefString error;
    if (!context->SetPreference(pref, value, error))
      fprintf(stderr, "YabCore page.fonts %s: %s\n", pref, error.ToString().c_str());
  }
  // The generic monospace family's size: the default size while a
  // fixed-width face is chosen, Chromium's own (null) otherwise.
  CefRefPtr<CefValue> size;
  if ([p[@"fixedSize"] isKindOfClass:NSNumber.class]) {
    size = CefValue::Create();
    size->SetInt([p[@"fixedSize"] intValue]);
  }
  CefString error;
  if (!context->SetPreference("webkit.webprefs.default_fixed_font_size", size, error))
    fprintf(stderr, "YabCore page.fonts default_fixed_font_size: %s\n", error.ToString().c_str());
}

// The page's pixels are drawn at the scale of the screen its hidden window is
// on, whatever screen Yab shows them on: a window moved to a Retina display
// from a plain one would stay soft. The hidden window follows to a screen of
// that scale; Chromium hears it as any window changing screens.
static void PageFollowScale(Tab& t, double scale) {
  if (!t.native || fabs(t.native.backingScaleFactor - scale) < 0.01) return;
  for (NSScreen* screen in NSScreen.screens) {
    if (fabs(screen.backingScaleFactor - scale) >= 0.01) continue;
    [t.native setFrameOrigin:screen.frame.origin];
    return;
  }
}
