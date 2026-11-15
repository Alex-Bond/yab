// Native identities only. The app owns logical placement, never a second URL.
static NSArray* ExtensionTabRows(const std::string& profile) {
  NSMutableArray* rows = [NSMutableArray array];
#if defined(CEF_YAB_EMBEDDED_TAB_OPERATIONS_VERSION)
  for (auto& [id, tab] : tabs) {
    if (tab.profile != profile || !tab.browser || tab.closing || tab.internal || !tab.adopted) continue;
    auto state = tab.browser->GetHost()->GetExternalPageState();
    if (!state || !state->HasKey("extensionTabId")) continue;
    [rows addObject:@{@"remote": @(id.c_str()), @"id": @(state->GetInt("extensionTabId")),
      @"windowId": @(state->GetInt("extensionWindowId")),
      @"windowType": Str(state->GetString("extensionWindowType"))}];
  }
#endif
  return rows;
}
static bool ExtensionTabOperationRequest(NSString* method, NSDictionary* p, NSString* request) {
  if (![method isEqual:@"extension.tabs.snapshot"] && ![method isEqual:@"extension.tabs.reply"]) return false;
  auto found = tabs.find(Key(S(p, @"tab")));
  if (found == tabs.end() || !found->second.browser || found->second.closing) {
    Reply(request, nil, @"The native tab-operation owner closed"); return true;
  }
#if defined(CEF_YAB_EMBEDDED_TAB_OPERATIONS_VERSION)
  if ([method isEqual:@"extension.tabs.snapshot"]) {
    Reply(request, ExtensionTabRows(found->second.profile)); return true;
  }
  auto state = CefDictionaryValue::Create();
  state->SetInt("operation", [p[@"operation"] intValue]);
  state->SetString("result", Key(S(p, @"result")));
  state->SetString("error", Key(S(p, @"error")));
  state->SetString("events", Key(S(p, @"events")));
  const bool accepted = found->second.browser->GetHost()->SetExternalTabState(state);
  Reply(request, @{@"accepted": @(accepted)});
#else
  Reply(request, nil, @"Embedded tab operations require the pinned SDK");
#endif
  return true;
}
