// Own CEF native hooks (patches 0004, 0007, 0008). Included inside namespace
// yc after downloads.inc. Each hook is compiled only against a source-built
// SDK that advertises it and only when the helper uses the experimental API;
// official CEF and the stable API keep the previous wire behavior.
#if defined(CEF_YAB_AUDIBLE_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_NATIVE_AUDIBLE 1
#else
#define YABCORE_NATIVE_AUDIBLE 0
#endif
#if defined(CEF_YAB_DOWNLOAD_PROVENANCE_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_DOWNLOAD_PROVENANCE 1
#else
#define YABCORE_DOWNLOAD_PROVENANCE 0
#endif
#if defined(CEF_YAB_EXTERNAL_FOCUS_VERSION) && YABCORE_EXTERNAL_HOST
#define YABCORE_EXTERNAL_FOCUS 1
#else
#define YABCORE_EXTERNAL_FOCUS 0
#endif
#if defined(CEF_YAB_BACKGROUND_COLOR_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_BACKGROUND_COLOR 1
#else
#define YABCORE_BACKGROUND_COLOR 0
#endif
#if defined(CEF_YAB_SELECT_MENU_VERSION) && defined(CEF_YAB_EXTERNAL_SELECT_VERSION) && YABCORE_EXTERNAL_HOST
#define YABCORE_SELECT_MENU 1
#else
#define YABCORE_SELECT_MENU 0
#endif
#if defined(CEF_YAB_EXTENSION_HOOKS_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_EXTENSION_HOOKS 1
#else
#define YABCORE_EXTENSION_HOOKS 0
#endif
#if defined(CEF_YAB_EXTERNAL_ACTION_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_EXTERNAL_ACTION 1
#else
#define YABCORE_EXTERNAL_ACTION 0
#endif
#if defined(CEF_YAB_DISCARD_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_DISCARD 1
#else
#define YABCORE_DISCARD 0
#endif
#if defined(CEF_YAB_NATIVE_PRINT_VERSION) && defined(CEF_YAB_NATIVE_PRINT_NOTIFY_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_NATIVE_PRINT 1
#else
#define YABCORE_NATIVE_PRINT 0
#endif
#if defined(CEF_YAB_EXTENSION_CONSENT_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_EXTENSION_CONSENT 1
#else
#define YABCORE_EXTENSION_CONSENT 0
#endif
#if defined(CEF_YAB_DISCARD_NOTIFY_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_DISCARD_NOTIFY 1
#else
#define YABCORE_DISCARD_NOTIFY 0
#endif
#if defined(CEF_YAB_TEXT_INPUT_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_TEXT_INPUT 1
#else
#define YABCORE_TEXT_INPUT 0
#endif

// API presence is negotiated separately from the legacy text-state snapshot.
// Source60 has no such macro, so this route and capability remain unavailable.
#if defined(CEF_YAB_NATIVE_TEXT_FOCUS_VERSION) && CEF_YAB_NATIVE_TEXT_FOCUS_VERSION == 1 && YABCORE_TEXT_INPUT
#define YABCORE_NATIVE_TEXT_FOCUS_API 1
#else
#define YABCORE_NATIVE_TEXT_FOCUS_API 0
#endif
// Promotion requires the exact future SDK's actual native acceptance receipt.
// API shape/compilation alone must not enable a production capability.
#ifndef YABCORE_NATIVE_TEXT_FOCUS_ACCEPTED_VERSION
#define YABCORE_NATIVE_TEXT_FOCUS_ACCEPTED_VERSION 0
#endif
#define YABCORE_NATIVE_TEXT_FOCUS (YABCORE_NATIVE_TEXT_FOCUS_API && YABCORE_NATIVE_TEXT_FOCUS_ACCEPTED_VERSION == 1)

// Original native approval claims are a partial primitive, never switch commit.
#if defined(CEF_YAB_NATIVE_GROUP_APPROVAL_VERSION) && CEF_YAB_NATIVE_GROUP_APPROVAL_VERSION == 1 && defined(CEF_YAB_NATIVE_GROUP_OWNER_VERSION) && CEF_YAB_NATIVE_GROUP_OWNER_VERSION == 1 && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_NATIVE_GROUP_APPROVAL_API 1
#else
#define YABCORE_NATIVE_GROUP_APPROVAL_API 0
#endif
#ifndef YABCORE_NATIVE_GROUP_APPROVAL_ACCEPTED_VERSION
#define YABCORE_NATIVE_GROUP_APPROVAL_ACCEPTED_VERSION 0
#endif
#define YABCORE_NATIVE_GROUP_APPROVAL (YABCORE_NATIVE_GROUP_APPROVAL_API && YABCORE_NATIVE_GROUP_APPROVAL_ACCEPTED_VERSION == 1)
#ifndef YABCORE_NATIVE_GROUP_SNAPSHOT_ACCEPTED_VERSION
#define YABCORE_NATIVE_GROUP_SNAPSHOT_ACCEPTED_VERSION 0
#endif
#define YABCORE_NATIVE_GROUP_SNAPSHOTS (YABCORE_NATIVE_GROUP_APPROVAL && YABCORE_NATIVE_GROUP_SNAPSHOT_ACCEPTED_VERSION == 1)
#if YABCORE_NATIVE_GROUP_APPROVAL_API && defined(CEF_YAB_NATIVE_GROUP_SOURCES_VERSION) && CEF_YAB_NATIVE_GROUP_SOURCES_VERSION == 1
#define YABCORE_NATIVE_GROUP_SOURCES_API 1
#else
#define YABCORE_NATIVE_GROUP_SOURCES_API 0
#endif
#ifndef YABCORE_NATIVE_GROUP_SOURCES_ACCEPTED_VERSION
#define YABCORE_NATIVE_GROUP_SOURCES_ACCEPTED_VERSION 0
#endif
#define YABCORE_NATIVE_GROUP_SOURCES (YABCORE_NATIVE_GROUP_APPROVAL && YABCORE_NATIVE_GROUP_SOURCES_API && YABCORE_NATIVE_GROUP_SOURCES_ACCEPTED_VERSION == 1)


#if defined(CEF_YAB_VERIFIED_CRX_VERSION) && YABCORE_EXTENSION_CONSENT && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_VERIFIED_CRX 1
#else
#define YABCORE_VERIFIED_CRX 0
#endif

#if defined(CEF_YAB_EXTERNAL_TAB_GROUP_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_TAB_GROUP 1
#else
#define YABCORE_TAB_GROUP 0
#endif

#if defined(CEF_YAB_NATIVE_CLOSE_PREFLIGHT_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_CLOSE_PREFLIGHT 1
#else
#define YABCORE_CLOSE_PREFLIGHT 0
#endif

#if defined(CEF_YAB_NATIVE_MEDIA_SESSION_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_NATIVE_MEDIA_SESSION 1
#else
#define YABCORE_NATIVE_MEDIA_SESSION 0
#endif

#if defined(CEF_YAB_NATIVE_CAPTURE_ACTIVITY_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_NATIVE_CAPTURE_ACTIVITY 1
#else
#define YABCORE_NATIVE_CAPTURE_ACTIVITY 0
#endif

#if defined(CEF_YAB_NATIVE_VIDEO_PIP_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_NATIVE_VIDEO_PIP 1
#else
#define YABCORE_NATIVE_VIDEO_PIP 0
#endif

#ifndef YABCORE_ENABLE_ORIGINAL_PDF
#define YABCORE_ENABLE_ORIGINAL_PDF 0
#endif
#if defined(CEF_YAB_ORIGINAL_PDF_VERSION) && CEF_YAB_ORIGINAL_PDF_VERSION == 1 && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_ORIGINAL_PDF_API 1
#else
#define YABCORE_ORIGINAL_PDF_API 0
#endif
#define YABCORE_ORIGINAL_PDF (YABCORE_ORIGINAL_PDF_API && YABCORE_ENABLE_ORIGINAL_PDF)
#ifndef YABCORE_ENABLE_ORIGINAL_PDF_PRESENCE
#define YABCORE_ENABLE_ORIGINAL_PDF_PRESENCE 0
#endif
#if defined(CEF_YAB_ORIGINAL_PDF_PRESENCE_VERSION) && CEF_YAB_ORIGINAL_PDF_PRESENCE_VERSION == 1 && defined(CEF_YAB_NATIVE_CAPTURE_ACTIVITY_VERSION) && CEF_YAB_NATIVE_CAPTURE_ACTIVITY_VERSION == 1 && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_ORIGINAL_PDF_PRESENCE_API 1
#else
#define YABCORE_ORIGINAL_PDF_PRESENCE_API 0
#endif
#define YABCORE_ORIGINAL_PDF_PRESENCE (YABCORE_ORIGINAL_PDF && YABCORE_ORIGINAL_PDF_PRESENCE_API && YABCORE_ENABLE_ORIGINAL_PDF_PRESENCE)


static bool NativeSwitchApprovalsAvailable();
static bool NativeGroupSourcesAvailable();
static bool NativeSnapshotsAvailable();
static NSDictionary* NativeHookCapabilities() {
  return @{@"nativeOriginalPDFPresence": @(YABCORE_ORIGINAL_PDF_PRESENCE),
           @"nativeOriginalPDFPresenceVersion": @(YABCORE_ORIGINAL_PDF_PRESENCE ? 1 : 0),
           @"nativeOriginalPDF": @(YABCORE_ORIGINAL_PDF),
           @"nativeOriginalPDFVersion": @(YABCORE_ORIGINAL_PDF ? 1 : 0),
           @"nativeOriginalCallerAuthenticated": @(original_caller::Ready()),
           @"nativeOriginalCallerVersion": @(original_caller::Ready() ? 1 : 0),
           @"nativeRemoteRead": @NO,
           @"nativeAudible": @(YABCORE_NATIVE_AUDIBLE),
           @"nativeMediaSession": @(YABCORE_NATIVE_MEDIA_SESSION),
           @"nativeCaptureActivity": @(YABCORE_NATIVE_CAPTURE_ACTIVITY),
           @"nativeVideoPiP": @(YABCORE_NATIVE_VIDEO_PIP),
           @"downloadProvenance": @(YABCORE_DOWNLOAD_PROVENANCE),
           @"externalFocus": @(YABCORE_EXTERNAL_FOCUS),
           @"nativeTextInput": @(YABCORE_TEXT_INPUT),
           @"nativeTextFocus": @(YABCORE_NATIVE_TEXT_FOCUS),
           @"nativeTextFocusVersion": @(YABCORE_NATIVE_TEXT_FOCUS ? 1 : 0),
           @"nativeGroupApprovals": @(YABCORE_NATIVE_GROUP_APPROVAL && NativeSwitchApprovalsAvailable()),
           @"nativeGroupApprovalVersion": @(YABCORE_NATIVE_GROUP_APPROVAL && NativeSwitchApprovalsAvailable() ? 1 : 0),
           @"nativeGroupOwnerVersion": @(YABCORE_NATIVE_GROUP_APPROVAL && NativeSwitchApprovalsAvailable() ? 1 : 0),
           @"nativeGroupSources": @(NativeGroupSourcesAvailable()),
           @"nativeGroupSourcesVersion": @(NativeGroupSourcesAvailable() ? 1 : 0),
           @"nativeGroupSnapshots": @(NativeSnapshotsAvailable()),
           @"nativeGroupSnapshotVersion": @(NativeSnapshotsAvailable() ? 1 : 0),
           @"nativeFullMutationFence": @NO,
           @"nativeFullStorageFence": @NO,
           @"nativeMixedWKSwitch": @NO,
           @"nativeAtomicSwitchCommit": @NO,
           @"backgroundColor": @(YABCORE_BACKGROUND_COLOR),
           @"selectMenu": @(YABCORE_SELECT_MENU),
           @"extensionPopups": @(YABCORE_EXTENSION_HOOKS),
           @"extensionTabMetadata": @(YABCORE_EXTENSION_HOOKS),
           @"externalExtensionAction": @(YABCORE_EXTERNAL_ACTION),
           @"nativeExternalPages": @(YABCORE_NATIVE_PAGE),
           @"nativeTabModel": @(YABCORE_NATIVE_TAB_MODEL),
           @"nativeDiscard": @(YABCORE_DISCARD),
           @"extensionConsent": @(YABCORE_EXTENSION_CONSENT),
           @"verifiedCrxInstall": @(YABCORE_VERIFIED_CRX),
           @"nativePrint": @(YABCORE_NATIVE_PRINT),
           @"nativeClosePreflight": @(YABCORE_CLOSE_PREFLIGHT),
           @"resizeAck": @(YABCORE_OWNCEF_SURFACES)};
}

// Copies a CEF value tree into Foundation objects for the JSON wire.
[[maybe_unused]] static ::id NativeValue(CefRefPtr<CefValue> value);
[[maybe_unused]] static NSDictionary* NativeDictionary(CefRefPtr<CefDictionaryValue> value) {
  if (!value) return @{};
  CefDictionaryValue::KeyList keys;
  value->GetKeys(keys);
  NSMutableDictionary* result = [NSMutableDictionary dictionary];
  for (const auto& key : keys) result[Str(key)] = NativeValue(value->GetValue(key));
  return result;
}
[[maybe_unused]] static ::id NativeValue(CefRefPtr<CefValue> value) {
  if (!value) return NSNull.null;
  switch (value->GetType()) {
    case VTYPE_BOOL: return @(value->GetBool());
    case VTYPE_INT: return @(value->GetInt());
    case VTYPE_DOUBLE: return @(value->GetDouble());
    case VTYPE_STRING: return Str(value->GetString());
    case VTYPE_DICTIONARY: return NativeDictionary(value->GetDictionary());
    case VTYPE_LIST: {
      auto list = value->GetList();
      NSMutableArray* result = [NSMutableArray array];
      for (size_t i = 0; list && i < list->GetSize(); ++i) [result addObject:NativeValue(list->GetValue(i))];
      return result;
    }
    default: return NSNull.null;
  }
}

#include "owncef_media.inc"
#include "owncef_capture.inc"
#include "owncef_pip.inc"

[[maybe_unused]] static void NativeAudible(Tab* tab, bool audible) {
  if (!tab || tab->audible == audible) return;
  tab->audible = audible;
  State(tab, @{@"audible": @(audible), @"audibleSource": @"native"});
}

// The page's CSS background color, so the client can fill area the page has
// not yet drawn while resizing (Chrome's own NSView does the same).
[[maybe_unused]] static void NativeBackground(Tab* tab, cef_color_t color, bool has) {
  if (!tab) return;
  NSString* hex = has && CefColorGetA(color) == 255
      ? [NSString stringWithFormat:@"#%02x%02x%02x", CefColorGetR(color), CefColorGetG(color), CefColorGetB(color)] : nil;
  if (hex == tab->backgroundColor || [hex isEqual:tab->backgroundColor]) return;
  tab->backgroundColor = hex;
  State(tab, @{@"backgroundColor": hex ?: (::id)NSNull.null});
}

#if YABCORE_NATIVE_PRINT
// A page asked to print (window.print, the PDF viewer). Chromium suspends the
// script until the request finishes, so a request that cannot reach the client
// is finished at once instead of leaving the page stuck.
static void NativePrintRequest(Tab* tab, CefRefPtr<CefDictionaryValue> request) {
  if (!request) return;
  std::string token = request->GetString("request").ToString();
  if (!tab || tab->internal || !tab->adopted || !hello || !tab->browser) {
    if (tab && tab->browser) {
      tab->browser->GetHost()->FinishNativePrint(token);
#if YABCORE_NATIVE_PRINT_SOURCE
      tab->browser->GetHost()->ReleaseNativePrintSource(token);
#endif
    }
    return;
  }
  Event(@"print.request", tab, NativeDictionary(request));
}
static void NativePrintWithdrawn(Tab* tab, const std::string& token) {
  if (tab) CancelNativePrintSource(*tab, token);
  if (tab) Event(@"print.withdrawn", tab, @{@"request": @(token.c_str())});
}
#endif

#if YABCORE_EXTENSION_CONSENT
// Extension install/permission/uninstall consent. Chrome asks before any side
// effect; the callback is retained until the client answers, the request is
// withdrawn or the session ends, and a dropped callback cancels.
struct Consent { CefRefPtr<CefExtensionConsentCallback> callback; std::string profile; std::string extension; };
static std::map<std::string, Consent> consents;
static void ClearConsents() { consents.clear(); }  // Releasing a callback cancels.
// Profile of a request: the originating tab's, else the persistent profile whose
// directory it names. A private (off the record) request without a tab has no
// identity the client can verify, so it is refused.
static NSString* ConsentProfile(Tab* tab, NSDictionary* request) {
  if (tab) return @(tab->profile.c_str());
  if ([request[@"offTheRecord"] boolValue]) return nil;
  NSString* path = request[@"profilePath"];
  if (![path isKindOfClass:NSString.class]) return nil;
  NSString* wanted = path.stringByStandardizingPath.stringByResolvingSymlinksInPath;
  for (auto& [name, profile] : profiles) {
    if (profile.privateMode) continue;
    NSString* candidate = [dataRoot stringByAppendingFormat:@"/space-%s", name.c_str()];
    if ([candidate.stringByStandardizingPath.stringByResolvingSymlinksInPath isEqual:wanted]) return @(name.c_str());
  }
  return nil;
}
static void NativeConsentRequest(Tab* tab, CefRefPtr<CefDictionaryValue> request, CefRefPtr<CefExtensionConsentCallback> callback) {
  if (!callback) return;
  NSMutableDictionary* copy = [NativeDictionary(request) mutableCopy];
  std::string token = Key(copy[@"request"] ?: @""), extension = Key(copy[@"extensionId"] ?: @"");
  NSString* profile = ConsentProfile(tab, copy);
  // Fail closed: unknown identity, duplicate token or a full table cancel.
  if (!hello || token.empty() || extension.empty() || !profile || consents.count(token) || consents.size() >= 16) { callback->Respond(false); return; }
  consents[token] = {callback, Key(profile), extension};
  copy[@"profile"] = profile;
  [copy removeObjectForKey:@"profilePath"];
  if (tab && !tab->internal) copy[@"tab"] = @(tab->id.c_str());
  Event(@"extension.consent", nullptr, copy);
}
static void NativeConsentWithdrawn(const std::string& token) {
  if (consents.erase(token)) Event(@"extension.consent.withdrawn", nullptr, @{@"request": @(token.c_str())});
}
static bool ConsentReply(NSDictionary* p, NSString* request) {
  auto found = consents.find(Key(S(p, @"request") ?: @""));
  // A stale, duplicate or cross-profile answer has no effect.
  if (found == consents.end() || found->second.extension != Key(S(p, @"extension") ?: @"") || found->second.profile != Key(S(p, @"profile") ?: @"")) {
    Reply(request, nil, @"Unknown, stale or mismatched consent request"); return true;
  }
  auto callback = found->second.callback;
  consents.erase(found);
  bool accept = [p[@"accept"] boolValue];
  callback->Respond(accept);
  Reply(request, @{@"accepted": @(accept)});
  return true;
}
#else
static void ClearConsents() {}
#endif

[[maybe_unused]] static void NativeDiscarded(Tab* tab, bool discarded) {
  if (!tab) return;
  fprintf(stderr, "YabCore discarded tab=%s value=%d (was %d)\n", tab->id.c_str(), (int)discarded, (int)tab->discarded);
  if (tab->discarded == discarded) return;
  tab->discarded = discarded;
  if (discarded) { tab->rendererPID = 0; tab->rendererBorn = 0; }
  State(tab, @{@"discarded": @(discarded), @"rendererPID": @(tab->rendererPID)});
}

#if YABCORE_DISCARD
// Answers tab.discard once Chromium finished or refused the attempt. The tab
// may have closed meanwhile; success is the engine's own discarded state.
class DiscardDone : public CefCompletionCallback {
  std::string tab_;
  NSString* request_;
 public:
  DiscardDone(const std::string& tab, NSString* request) : tab_(tab), request_(request) {}
  void OnComplete() override {
    auto found = tabs.find(tab_);
    if (found == tabs.end() || !found->second.browser) { Reply(request_, nil, @"Tab closed"); return; }
    bool discarded = found->second.browser->GetHost()->IsPageDiscarded();
    NativeDiscarded(&found->second, discarded);
    Reply(request_, @{@"discarded": @(discarded)});
  }
  IMPLEMENT_REFCOUNTING(DiscardDone);
};
#endif

#if YABCORE_TEXT_INPUT
static void NativeTextState(Tab* tab, CefRefPtr<CefDictionaryValue> state) {
  if (!tab || !state) return;
  NSDictionary* copy = NativeDictionary(state);
  if (![copy[@"stateVersion"] isEqual:@1]) return;
  tab->textState = copy;
  if (!tab->internal) Event(@"page.textInput", tab, copy);
}
#endif

#if YABCORE_SELECT_MENU
// <select> popups of externally hosted tabs are drawn by the client. Only an
// adopted, visible page may present one; anything else is cancelled.
static bool NativeSelectOpen(Tab* tab, CefRefPtr<CefDictionaryValue> menu) {
  if (!tab || tab->internal || !tab->adopted || !tab->visible || !menu) return false;
  NSDictionary* copy = NativeDictionary(menu);
  tab->selectToken = [copy[@"token"] intValue];
  Event(@"select.open", tab, copy);
  return true;
}
static void NativeSelectClosed(Tab* tab, int token) {
  if (!tab || token != tab->selectToken) return;
  tab->selectToken = 0;
  Event(@"select.closed", tab, @{@"token": @(token)});
}
#endif

#if YABCORE_EXTENSION_HOOKS
// Extension action popups: identity is captured by Chromium when the action
// fires (owner page, extension, token). The popup's own compositor context is
// reported for the client to host beside its extension button; its native
// window stays transparent, and input reaches it through popup.input.
static std::map<std::string, std::pair<int, std::string>> extensionPopups;
struct NativePopupLease {
  std::string owner, extension, ownerDocument, document;
  bool closedDelivered = false;
};
static std::map<std::string, NativePopupLease> nativePopupLeases;
static std::map<std::string, NativePopupLease> retiredNativePopups;
static bool nativePopupAdmissionClosed = false;
static void RetireNativeExtensionPopup(const std::string& token) {
  auto active = nativePopupLeases.find(token);
  if (active != nativePopupLeases.end() && !retiredNativePopups.count(token)) {
    if (retiredNativePopups.size() >= 16384) nativePopupAdmissionClosed = true;
    else retiredNativePopups.emplace(token, active->second);
  }
  extensionPopups.erase(token);
  nativePopupLeases.erase(token);
}
static void NativeExtensionOwnerClosed(Tab* owner) {
  if (!owner) return;
  std::vector<std::string> owned;
  for (const auto& [token, lease] : nativePopupLeases)
    if (lease.owner == owner->id) owned.push_back(token);
  for (const auto& token : owned) RetireNativeExtensionPopup(token);
}
static void Input(Tab& tab, NSDictionary* p, NSString* request);
static void NativeExtensionPopup(Tab* owner, CefRefPtr<CefDictionaryValue> popup) {
  if (!owner || !popup) return;
  NSMutableDictionary* copy = [NativeDictionary(popup) mutableCopy];
  std::string token = Key(S(copy, @"token") ?: @"");
  std::string extension = Key(S(copy, @"extensionId") ?: @"");
  NSString* state = S(copy, @"state");
  const bool closed = [state isEqual:@"closed"];
  if (token.empty() || token.size() > 128 || extension.empty() || extension.size() > 128 ||
      (!closed && ![state isEqual:@"shown"] && ![state isEqual:@"frame"])) return;
  NativePopupLease source{owner->id, extension, "", "", false};
  if ([copy[@"nativeLeaseVersion"] intValue] == 1) {
    source.ownerDocument = Key(S(copy, @"ownerDocument") ?: @"");
    source.document = Key(S(copy, @"document") ?: @"");
    if (source.ownerDocument.empty() || source.document.empty() ||
        source.ownerDocument.size() > 128 || source.document.size() > 128) return;
  }
  auto matches = [&](const NativePopupLease& original) {
    return original.owner == source.owner && original.extension == source.extension &&
           original.ownerDocument == source.ownerDocument && original.document == source.document;
  };
  copy[@"profile"] = @(owner->profile.c_str());
  auto retired = retiredNativePopups.find(token);
  if (retired != retiredNativePopups.end()) {
    if (!closed || !matches(retired->second) || retired->second.closedDelivered) return;
    // A helper close request retires before native reentry; still deliver its
    // one ORIGINAL native terminal callback, never later frames or duplicates.
    retired->second.closedDelivered = true;
    if (!owner->internal) Event(@"popup.layer", owner, copy);
    return;
  }
  auto active = nativePopupLeases.find(token);
  if (active != nativePopupLeases.end() && !matches(active->second)) return;
  if (active == nativePopupLeases.end() && nativePopupAdmissionClosed) return;
  if (closed) {
    if (active == nativePopupLeases.end()) nativePopupLeases.emplace(token, source);
    RetireNativeExtensionPopup(token);
    auto terminal = retiredNativePopups.find(token);
    if (terminal != retiredNativePopups.end()) terminal->second.closedDelivered = true;
    if (!owner->internal) Event(@"popup.layer", owner, copy);
    return;
  }
  int number = [copy[@"windowNumber"] intValue];
  if (number <= 0 || (active == nativePopupLeases.end() && extensionPopups.size() >= 16)) return;
  auto originalWindow = extensionPopups.find(token);
  if (originalWindow != extensionPopups.end() &&
      (originalWindow->second.first != number || originalWindow->second.second != owner->id)) return;
  nativePopupLeases.emplace(token, source);
  extensionPopups[token] = {number, owner->id};
  CefRefPtr<CefBrowser> ownerBrowser = owner->browser;
  if (NSWindow* window = [NSApp windowWithWindowNumber:number]) Conceal(window);
  // NSWindow changes can synchronously reenter native close/navigation and the
  // helper transport. Revalidate the lease AFTER that effect before its event.
  owner = ownerBrowser ? Find(ownerBrowser) : nullptr;
  auto current = nativePopupLeases.find(token);
  if (!owner || owner->id != source.owner || retiredNativePopups.count(token) ||
      current == nativePopupLeases.end() || !matches(current->second)) return;
  if (!owner->internal) Event(@"popup.layer", owner, copy);
}
static void NativeExtensionTab(Tab* tab, CefRefPtr<CefDictionaryValue> info) {
  if (!tab || !info) return;
  NSMutableDictionary* copy = [NativeDictionary(info) mutableCopy];
  // chrome.tabs.update({active:true}): Yab selects, and lists the window again.
  if ([copy[@"requestedKind"] isEqual:@"activate"]) { Event(@"tab.extensionActivate", tab, @{}); return; }
  auto opener = browserTabs.find([copy[@"openerBrowserId"] intValue]);
  copy[@"openerTab"] = opener == browserTabs.end() ? (::id)NSNull.null : @(opener->second.c_str());
  [copy removeObjectForKey:@"openerBrowserId"];
  // The native hook runs after Attach's creation event. Retain the receipt
  // until tab.adopt answers so Swift installs the final metadata atomically,
  // even when its first tab.created event preceded this callback.
  tab->extensionCreation = copy;
  tab->foreground = [copy[@"active"] boolValue];
  tab->opener = opener == browserTabs.end() ? "" : opener->second;
  PublishNativeCreation(*tab);
  Event(@"tab.extensionCreated", tab, copy);
}
#endif

// Yab's window as extensions see it: its pages in order, one active. Pages
// not listed (management, side panel) are not tabs to them.
static void TabsGroupRequest(NSDictionary* p, NSString* request) {
#if YABCORE_TAB_GROUP
  NSArray* list = [p[@"tabs"] isKindOfClass:NSArray.class] ? p[@"tabs"] : @[];
  NSString* active = S(p, @"active");
  CefRefPtr<CefBrowser> lead;
  for (id value in list) {
    if (![value isKindOfClass:NSString.class]) continue;
    auto found = tabs.find(Key(value));
    if (found != tabs.end() && found->second.browser && !found->second.closing) { lead = found->second.browser; break; }
  }
  int index = 0, refused = 0;
  if (lead) for (id value in list) {
    if (![value isKindOfClass:NSString.class]) continue;
    auto found = tabs.find(Key(value));
    if (found == tabs.end() || !found->second.browser || found->second.closing) continue;
    if (!found->second.browser->GetHost()->SetExternalTabGroup(lead, index, [active isEqual:value])) refused++;
    else index++;
  }
  Reply(request, @{@"listed": @(index), @"refused": @(refused)});
#else
  (void)p;
  Reply(request, nil, @"Native tab groups are unavailable in this CEF build");
#endif
}

// Native provenance for download.open. Unavailable fields are reported as
// such; a recent local input time is never substituted for a user gesture.
static NSDictionary* DownloadProvenance(CefRefPtr<CefDownloadItem> item) {
#if YABCORE_DOWNLOAD_PROVENANCE
  NSString* initiator = Str(item->GetRequestInitiator());
  NSString* page = Str(item->GetTabURL());
  return @{@"provenance": @"native", @"userGesture": @(item->HasUserGesture()),
           @"initiator": initiator.length ? initiator : (::id)NSNull.null,
           @"tabURL": page.length ? page : (::id)NSNull.null,
           @"canResume": @(item->CanResume())};
#else
  (void)item;
  return @{@"provenance": @"unavailable"};
#endif
}

// tab.focus delegates key status for an externally hosted producer. The
// caller owns the real key window and must clear focus on hide or key loss.
#if YABCORE_VERIFIED_CRX
class VerifiedCrxDone final : public CefExtensionInstallCallback {
 public:
  VerifiedCrxDone(NSString* request, std::string profile, std::string expected)
      : request_(request), profile_(std::move(profile)), expected_(std::move(expected)) {}
  void OnComplete(CefRefPtr<CefDictionaryValue> native) override {
    if (done_) return;
    done_ = true;
    NSDictionary* result = NativeDictionary(native);
    NSString* status = S(result, @"status");
    if (![@[@"installed", @"cancelled", @"error"] containsObject:status] ||
        ![S(result, @"extensionId") isEqual:@(expected_.c_str())] ||
        ([status isEqual:@"installed"] && !S(result, @"version").length)) {
      Reply(request_, nil, @"Invalid native installer completion"); return;
    }
    NSMutableDictionary* copy = [result mutableCopy]; copy[@"profile"] = @(profile_.c_str());
    Reply(request_, copy);
  }
 private:
  NSString* request_;
  std::string profile_, expected_;
  bool done_ = false;
  IMPLEMENT_REFCOUNTING(VerifiedCrxDone);
};
#endif

static bool NativeHookRequest(Tab& t, NSString* method, NSDictionary* p, NSString* request) {
  if (NativePiPRequest(t, method, p, request)) return true;
  if (NativeCaptureRequest(t, method, p, request)) return true;
  if (NativeMediaRequest(t, method, p, request)) return true;
  if ([method isEqual:@"extension.installCrx"]) {
#if YABCORE_VERIFIED_CRX
    NSString* path = S(p, @"path"), *expected = S(p, @"extension");
    if (!t.internal || !t.browser || !t.browser->GetMainFrame() ||
        t.browser->GetMainFrame()->GetURL() != "chrome://extensions/" ||
        profiles.at(t.profile).privateMode ||
        (p[@"profile"] && ![S(p, @"profile") isEqual:@(t.profile.c_str())])) {
      Reply(request, nil, @"Verified installation requires this profile's native management owner"); return true;
    }
    NSData* bytes = [path dataUsingEncoding:NSUTF8StringEncoding];
    std::string file(bytes ? static_cast<const char*>(bytes.bytes) : "", bytes.length);
    const std::string extension = Key(expected);
    if (![path isAbsolutePath] || file.find('\0') != std::string::npos ||
        extension.size() != 32 || expected.length != 32 ||
        extension.find_first_not_of("abcdefghijklmnop") != std::string::npos) {
      Reply(request, nil, @"Expected an original absolute CRX path and extension ID"); return true;
    }
    requests[Key(request)] = Now() + 240;
    auto callback = new VerifiedCrxDone(request, t.profile, extension);
    if (!t.browser->GetHost()->GetRequestContext()->InstallVerifiedExtensionCrx(
          t.browser, file, extension, callback))
      Reply(request, nil, @"Native verified installer refused the request");
#else
    Reply(request, nil, @"Verified CRX installation is unavailable in this SDK/API mode");
#endif
    return true;
  }

  if ([method isEqual:@"tab.focus"]) {
#if YABCORE_EXTERNAL_FOCUS
    if (!t.externallyHosted || (!t.externalPage && (!t.window || !t.view))) { Reply(request, nil, @"External focus requires an externally hosted tab"); return true; }
    bool focused = [p[@"focused"] boolValue];
    if (focused && !t.visible) { Reply(request, nil, @"Cannot focus a hidden tab"); return true; }
    bool accepted = false;
#if YABCORE_NATIVE_PAGE
    if (t.externalPage) accepted = t.browser && t.browser->GetHost()->SetExternalPageFocus(focused);
    else
#endif
    accepted = t.window->SetExternalFocus(t.view, focused);
    if (!accepted) { Reply(request, nil, @"CEF refused external focus"); return true; }
    t.focused = focused;
    Reply(request, @{@"focused": @(focused)});
#else
    (void)t; (void)p;
    Reply(request, nil, @"External focus is unavailable in this CEF build");
#endif
    return true;
  }
  if ([method isEqual:@"select.reply"]) {
#if YABCORE_SELECT_MENU
    int token = [p[@"token"] intValue], index = p[@"index"] ? [p[@"index"] intValue] : -1;
    if (!token || token != t.selectToken || (!t.externalPage && (!t.window || !t.view))) { Reply(request, nil, @"Unknown or closed select menu"); return true; }
    t.selectToken = 0;
    bool accepted = false;
#if YABCORE_NATIVE_PAGE
    if (t.externalPage) accepted = t.browser && t.browser->GetHost()->ReplyExternalPageSelect(token, index);
    else
#endif
    accepted = t.window->ReplyExternalSelect(t.view, token, index);
    if (!accepted) { Reply(request, nil, @"CEF refused the select reply"); return true; }
    Reply(request, @{@"token": @(token), @"index": @(index)});
#else
    Reply(request, nil, @"Client-drawn select menus are unavailable in this CEF build");
#endif
    return true;
  }
  if ([method isEqual:@"extension.action.open"]) {
#if YABCORE_EXTERNAL_ACTION
    NSString* extension = S(p, @"extension");
    NSCharacterSet* invalid = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnop"] invertedSet];
    if (!t.browser || t.internal || !t.adopted || !t.visible || !t.externallyHosted ||
        extension.length != 32 || [extension rangeOfCharacterFromSet:invalid].location != NSNotFound) {
      Reply(request, nil, @"Action requires an enabled extension and a visible externally hosted owner"); return true;
    }
    NSDictionary* anchor = [p[@"anchor"] isKindOfClass:NSDictionary.class] ? p[@"anchor"] : @{};
    double x = [anchor[@"x"] doubleValue], y = [anchor[@"y"] doubleValue];
    double width = [anchor[@"width"] doubleValue], height = [anchor[@"height"] doubleValue];
    if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(width) || !std::isfinite(height) ||
        fabs(x) > 100000 || fabs(y) > 100000 || width < 0 || height < 0 || width > 16384 || height > 16384) {
      Reply(request, nil, @"Invalid action anchor"); return true;
    }
    bool opened = t.browser->GetHost()->OpenExtensionAction(Key(extension), CefRect(x, y, width, height));
    Reply(request, opened ? @{@"opened": @YES} : nil, opened ? nil : @"Chrome refused the external action");
#else
    Reply(request, nil, @"External extension actions are unavailable in this CEF build");
#endif
    return true;
  }
  if ([method isEqual:@"popup.input"] || [method isEqual:@"popup.close"] || [method isEqual:@"popup.focus"] || [method isEqual:@"popup.anchor"]) {
#if YABCORE_EXTENSION_HOOKS
    auto popup = extensionPopups.find(Key(S(p, @"token") ?: @""));
    // The token names the popup; only the tab it was opened for may drive it.
    NSWindow* window = popup == extensionPopups.end() || popup->second.second != t.id ? nil : [NSApp windowWithWindowNumber:popup->second.first];
    if (!window) { Reply(request, nil, @"Unknown or closed extension popup"); return true; }
#if YABCORE_EXTERNAL_ACTION
    NSDictionary* anchor = [p[@"anchor"] isKindOfClass:NSDictionary.class] ? p[@"anchor"] : @{};
    double x = [anchor[@"x"] doubleValue], y = [anchor[@"y"] doubleValue];
    double width = [anchor[@"width"] doubleValue], height = [anchor[@"height"] doubleValue];
    if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(width) || !std::isfinite(height) ||
        fabs(x) > 100000 || fabs(y) > 100000 || width < 0 || height < 0 || width > 16384 || height > 16384) {
      Reply(request, nil, @"Invalid popup anchor"); return true;
    }
    bool close = [method isEqual:@"popup.close"];
    bool focused = ![method isEqual:@"popup.focus"] || [p[@"focused"] boolValue];
    if (close) RetireNativeExtensionPopup(Key(S(p, @"token")));
    if (!t.browser || !t.browser->GetHost()->ControlExtensionPopup(Key(S(p, @"token")),
          CefRect(x, y, width, height), focused, close)) {
      RetireNativeExtensionPopup(Key(S(p, @"token")));
      Reply(request, nil, @"Native popup owner or document is no longer live"); return true;
    }
    if (close) RetireNativeExtensionPopup(Key(S(p, @"token")));
    if (close || [method isEqual:@"popup.focus"] || [method isEqual:@"popup.anchor"]) { Reply(request); return true; }
#else
    if ([method isEqual:@"popup.close"]) { RetireNativeExtensionPopup(Key(S(p, @"token"))); [window performClose:nil]; Reply(request); return true; }
    if (![method isEqual:@"popup.input"]) { Reply(request, nil, @"Native popup control is unavailable"); return true; }
#endif
    Tab target;  // Input() only reads the destination window.
    target.native = window;
    // This token names the original popup view, never a tab CDP session.
    // Deliver AppKit events directly while its producer stays concealed.
    target.externallyHosted = true;
    Input(target, p, request);
#else
    Reply(request, nil, @"Extension popup hosting is unavailable in this CEF build");
#endif
    return true;
  }
  if ([method isEqual:@"tab.discard"] || [method isEqual:@"tab.restore"] || [method isEqual:@"tab.freeze"]) {
#if YABCORE_DISCARD
    auto host = t.browser ? t.browser->GetHost() : nullptr;
    if (!host) { Reply(request, nil, @"Tab has no browser"); return true; }
    if (([method isEqual:@"tab.discard"] || ([method isEqual:@"tab.freeze"] && [p[@"frozen"] boolValue])) &&
        (p[@"captureToken"] || p[@"captureDocument"])) {
#if YABCORE_NATIVE_CAPTURE_ACTIVITY
      if (!NativeCaptureAllowsLifecycle(t, p)) {
        Reply(request, nil, @"Native capture snapshot retired or the page is active"); return true;
      }
#else
      Reply(request, nil, @"Native capture lifecycle guard is unavailable"); return true;
#endif
    }
    if ([method isEqual:@"tab.discard"]) {
#if YABCORE_NATIVE_PAGE
      // Chrome refuses to discard a VISIBLE WebContents. A page never shown
      // in Yab's window can still carry its creation-time visibility.
      if (!t.visible && t.externalPage) host->SetExternalPageVisibility(false);
#endif
      if (t.visible || !host->CanDiscardPage()) { Reply(request, @{@"discarded": @NO, @"refused": t.visible ? @"visible" : @"unavailable"}); return true; }
      host->DiscardPage(new DiscardDone(t.id, request));
    } else if ([method isEqual:@"tab.restore"]) {
      // Native restore of the selected entry only; history is untouched.
      bool restored = host->RestoreDiscardedPage();
      if (restored) { t.frozen = false; NativeDiscarded(&t, false); }
      Reply(request, @{@"restored": @(restored), @"discarded": @(restored ? false : host->IsPageDiscarded())});
    } else {
      bool frozen = [p[@"frozen"] boolValue];
      // A request to the renderer, never an acknowledgement or a discard.
      bool accepted = !t.visible && host->SetPageFrozen(frozen);
      if (accepted) { t.frozen = frozen; State(&t, @{@"frozen": @(frozen)}); }
      Reply(request, @{@"frozen": @(t.frozen), @"accepted": @(accepted)});
    }
#else
    (void)t; (void)p;
    Reply(request, nil, @"Native discard and freeze are unavailable in this CEF build");
#endif
    return true;
  }
  if ([method isEqual:@"print.finish"]) {
#if YABCORE_NATIVE_PRINT
    auto host = t.browser ? t.browser->GetHost() : nullptr;
    bool finished = host && host->FinishNativePrint(Key(S(p, @"request") ?: @""));
    Reply(request, @{@"finished": @(finished)});
#else
    (void)t; (void)p;
    Reply(request, nil, @"Native print requests are unavailable in this CEF build");
#endif
    return true;
  }
  if ([method isEqual:@"tab.textInput"]) {
    Reply(request, @{@"state": t.textState ?: (::id)NSNull.null,
                     @"available": @(YABCORE_TEXT_INPUT)});
    return true;
  }
  return false;
}
