// An OnAfterCreated notification identifies a browser, not a request to add a
// Yab tab. Chrome can also restore its own bookkeeping/previous-session tabs.
// Only OnBeforePopup and the native chrome.tabs.create receipt authorize
// adoption. Never classify a document by its URL (about:blank is legitimate).
static bool HasNativeCreationRequest(const Tab& tab) {
  return (tab.popupSource && !tab.opener.empty()) || ExtensionValidID(S(tab.extensionCreation, @"extensionId"));
}
static void PublishNativeCreation(Tab& tab) {
  if (tab.adopted || tab.closing || tab.creationAnnounced || !HasNativeCreationRequest(tab)) return;
  tab.creationAnnounced = true;
  Event(@"tab.created", &tab, CreatedState(tab));
}
static void FinishNativeCreation(std::string id) {
  auto found = tabs.find(id);
  if (found == tabs.end()) return;
  if (HasNativeCreationRequest(found->second)) { PublishNativeCreation(found->second); return; }
  // chrome.tabs.create calls its native hook after OnAfterCreated, before
  // returning from the same UI task. Leave that creation stack before deciding
  // whether a default-client browser has an owner. This is no timed URL probe.
  dispatch_async(dispatch_get_main_queue(), ^{
    auto current = tabs.find(id);
    if (current == tabs.end() || current->second.closing || current->second.adopted) return;
    auto& tab = current->second;
    if (HasNativeCreationRequest(tab)) { PublishNativeCreation(tab); return; }
    fprintf(stderr, "YabCore retiring unrequested native browser: tab=%s browser=%d\n",
            id.c_str(), tab.browser->GetIdentifier());
    tab.closing = true;
    tab.browser->GetHost()->CloseBrowser(true);
  });
}
