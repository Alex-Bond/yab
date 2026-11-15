// Native default-client page endpoints. No native window/view-tree polling.
#if YABCORE_NATIVE_PAGE
static NSDictionary* NativePageReceipt(CefRefPtr<CefDictionaryValue> source) {
  if (!source || !source->GetBool("bound")) return nil;
  NSMutableDictionary* result = [NSMutableDictionary dictionary];
  for (const char* key : {"bound", "rendererBound", "visible", "nativeTabModel", "active", "frameMatchesGeometry"})
    result[@(key)] = @(source->GetBool(key));
  for (const char* key : {"browserId", "windowNumber", "index", "logicalWindowId", "openerBrowserId"})
    result[@(key)] = @(source->GetInt(key));
  for (const char* key : {"contextId", "pixelWidth", "pixelHeight", "scale", "pageX", "pageY", "pageWidth", "pageHeight"}) {
    auto value = source->GetValue(key);
    double number = value && value->GetType() == VTYPE_INT ? source->GetInt(key) : source->GetDouble(key);
    if (!std::isfinite(number)) return nil;
    result[@(key)] = @(number);
  }
  result[@"token"] = Str(source->GetString("token"));
  return result;
}
static bool AcceptNativePageReceipt(Tab& tab, CefRefPtr<CefDictionaryValue> source) {
  NSDictionary* state = NativePageReceipt(source);
  if (!state || !tab.browser || [state[@"browserId"] intValue] != tab.browser->GetIdentifier() ||
      ![state[@"token"] length] || (tab.nativePageToken && ![tab.nativePageToken isEqual:state[@"token"]])) return false;
  NSWindow* window = [NSApp windowWithWindowNumber:[state[@"windowNumber"] intValue]];
  if (!window || (tab.externalPage && tab.native != window)) return false;
  tab.nativePageToken = state[@"token"]; tab.nativePageReceipt = state;
  tab.externalPage = true; tab.externallyHosted = true; tab.fitPage = false;
  tab.native = window;
  tab.native.ignoresMouseEvents = YES;
  return true;
}
static bool AttachNativePage(Tab& tab) {
  if (!tab.browser || !AcceptNativePageReceipt(tab, tab.browser->GetHost()->GetExternalPageState())) return false;
  if ([tab.nativePageReceipt[@"nativeTabModel"] boolValue]) {
    tab.foreground = [tab.nativePageReceipt[@"active"] boolValue];
    // This receipt authenticates compositor geometry, not creation intent.
    // Keep the OnBeforePopup source and native extension creation receipt
    // separate so a restored/default-client page cannot manufacture admission.
  }
  return true;
}
static void NativePageFrame(Tab* tab, CefRefPtr<CefDictionaryValue> state) {
  if (!tab || tab->closing || !AcceptNativePageReceipt(*tab, state)) return;
  const auto receipt = tab->nativePageReceipt;
  const bool hasPage = [receipt[@"rendererBound"] boolValue];
  if (hasPage && [receipt[@"contextId"] unsignedIntValue] &&
      ![receipt[@"frameMatchesGeometry"] boolValue]) return;
  OwnCEFFrame(tab->id, hasPage ? [receipt[@"contextId"] unsignedIntValue] : 0,
      CefSize([receipt[@"pixelWidth"] intValue], [receipt[@"pixelHeight"] intValue]),
      [receipt[@"scale"] floatValue]);
}
#endif
