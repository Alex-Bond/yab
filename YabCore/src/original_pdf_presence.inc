// Metadata only. Explicit opt-in; original engine bytes use original_pdf.inc.
struct OriginalPDFPresenceOwner : OriginalPDFPresenceIdentity {
  bool active=true;
};
// This existing synchronous native getter reads the actual primary RFH's
// DocumentToken/frame. It neither creates an observer nor invokes client UI.
// CDP execution-context generations are correlation, never document authority.
[[maybe_unused]] static bool OriginalPDFPresenceCurrent(Tab& tab,OriginalPDFPresenceIdentity& current) {
#if YABCORE_ORIGINAL_PDF_PRESENCE_API
  if(!tab.browser)return false;
  auto native=tab.browser->GetHost()->GetNativeCaptureState();
  if(!native||native->GetType("version")!=VTYPE_INT||native->GetInt("version")!=1||
      native->GetType("browserId")!=VTYPE_INT||native->GetInt("browserId")!=tab.browser->GetIdentifier()||
      native->GetType("scope")!=VTYPE_STRING||native->GetString("scope")!="browser"||
      native->GetType("known")!=VTYPE_BOOL||!native->GetBool("known")||
      native->GetType("primaryDocument")!=VTYPE_STRING||native->GetType("primaryFrameId")!=VTYPE_STRING)return false;
  current.document=native->GetString("primaryDocument").ToString();
  current.frame=native->GetString("primaryFrameId").ToString();
  if(current.document.empty()||current.document.size()>256||current.frame.empty()||current.frame.size()>256)return false;
  current.tab=tab.id;current.profile=tab.profile;current.connection=originalPDFConnection;
  current.generation=tab.documentGeneration;current.browser=tab.browser->GetIdentifier();
  current.browserIdentity=reinterpret_cast<uintptr_t>(tab.browser.get());
  return true;
#else
  (void)tab;(void)current;return false;
#endif
}
static std::map<int,std::shared_ptr<OriginalPDFPresenceOwner>> originalPDFPresence;
static std::map<int,OriginalPDFPresenceOwner> originalPDFPresenceWanted;
[[maybe_unused]] static bool OriginalPDFPresenceLive(const std::shared_ptr<OriginalPDFPresenceOwner>& owner) {
  auto found=originalPDFPresence.find(owner->browser);auto tab=tabs.find(owner->tab);
  return owner->active&&hello&&!stopping&&originalPDFConnection&&
      owner->connection==originalPDFConnection&&found!=originalPDFPresence.end()&&
      found->second==owner&&tab!=tabs.end()&&tab->second.browser&&
      tab->second.adopted&&!tab->second.internal&&!tab->second.closing&&!tab->second.crashed&&
      tab->second.profile==owner->profile&&tab->second.browser->GetIdentifier()==owner->browser&&
      reinterpret_cast<uintptr_t>(tab->second.browser.get())==owner->browserIdentity&&
      [&] {OriginalPDFPresenceIdentity current;
        return OriginalPDFPresenceCurrent(tab->second,current)&&owner->MatchesNativeOwner(current);}();
}
#if YABCORE_ORIGINAL_PDF_PRESENCE_API
static NSDictionary* OriginalPDFPresenceNative(CefRefPtr<CefDictionaryValue> value,int browser) {
  if(!value||value->GetType("version")!=VTYPE_INT||value->GetInt("version")!=1||
      value->GetType("browserId")!=VTYPE_INT||value->GetInt("browserId")!=browser)return nil;
  NSMutableDictionary* native=[NSMutableDictionary dictionary];
  for(NSString* key in @[@"kind",@"operation",@"status",@"request",@"generation",@"source",
      @"rootDocument",@"rootFrameId",@"pdfDocument",@"pdfFrameId",@"listener",@"pluginSource"]) {
    auto type=value->GetType(Key(key));
    if(type==VTYPE_INVALID)continue;
    if(type!=VTYPE_STRING)return nil;
    NSString* text=Str(value->GetString(Key(key)));if(text.length>256)return nil;
    native[key]=text;
  }
  for(NSString* key in @[@"available",@"complete",@"loadedAtMetadataAck"]) {
    if(value->GetType(Key(key))!=VTYPE_BOOL)return nil;
    native[key]=@(value->GetBool(Key(key)));
  }
  if(![S(native,@"kind") isEqual:@"originalLoadedPDFPresence"]||
      ![S(native,@"operation") isEqual:@"presence"]||
      ![@[@"ready",@"unavailable",@"unknown"] containsObject:native[@"status"]]||
      !S(native,@"generation").length||!S(native,@"rootDocument").length||
      !S(native,@"rootFrameId").length||[native[@"complete"] isEqual:@YES])return nil;
  const bool ready=[S(native,@"status") isEqual:@"ready"];
  if(![native[@"available"] isEqual:@(ready)]||![native[@"loadedAtMetadataAck"] isEqual:@(ready)])return nil;
  int size=0;if(value->GetType("size")==VTYPE_INT)size=value->GetInt("size");
  if(size<0||size>64*1024*1024)return nil;
  if(ready) {
    if(!size||S(native,@"source").length||!S(native,@"request").length)return nil;
    for(NSString* key in @[@"pdfDocument",@"pdfFrameId",@"listener",@"pluginSource"])
      if(!S(native,key).length)return nil;
  }
  native[@"version"]=@1;native[@"browserId"]=@(browser);native[@"size"]=@(size);
  return [native copy];
}
class OriginalPDFPresenceDone final : public CefOriginalPdfPresenceCallback {
  const std::shared_ptr<OriginalPDFPresenceOwner> owner_;
 public:
  explicit OriginalPDFPresenceDone(std::shared_ptr<OriginalPDFPresenceOwner> owner):owner_(std::move(owner)) {}
  void OnOriginalPdfPresence(CefRefPtr<CefDictionaryValue> value) override {
    auto owner=owner_;if(!OriginalPDFPresenceLive(owner))return;
    // Detach ALL metadata inside the SDK call. Queued blocks own no CEF values,
    // callback/binary/browser references or code that can reconnect a helper.
    NSDictionary* native=OriginalPDFPresenceNative(value,owner->browser);
    if(!native||!owner->MatchesNativeDocument(Key(S(native,@"rootDocument")),Key(S(native,@"rootFrameId"))))return;
    NSDictionary* packet=@{@"tab":@(owner->tab.c_str()),@"profile":@(owner->profile.c_str()),
        @"documentGeneration":@(owner->generation),@"native":native};
    dispatch_async(dispatch_get_main_queue(),^{
      if(OriginalPDFPresenceLive(owner))Event(@"page.originalPDF.changed",nullptr,packet);
    });
  }
  IMPLEMENT_REFCOUNTING(OriginalPDFPresenceDone);
};
#endif
static void OriginalPDFPresenceSuspend(int browser) {
  auto it=originalPDFPresence.find(browser);if(it==originalPDFPresence.end())return;
  auto owner=it->second;owner->active=false;originalPDFPresence.erase(it);
#if YABCORE_ORIGINAL_PDF_PRESENCE_API
  auto tab=tabs.find(owner->tab);
  if(tab!=tabs.end()&&tab->second.browser&&
      tab->second.browser->GetIdentifier()==browser&&
      reinterpret_cast<uintptr_t>(tab->second.browser.get())==owner->browserIdentity)
    tab->second.browser->GetHost()->SetOriginalPdfPresenceCallback(nullptr);
#endif
}
static void OriginalPDFPresenceClosed(int browser) {
  originalPDFPresenceWanted.erase(browser);OriginalPDFPresenceSuspend(browser);
}
static void ClearOriginalPDFPresence() {
  originalPDFPresenceWanted.clear();std::vector<int> browsers;
  for(const auto& [browser,owner]:originalPDFPresence)browsers.push_back(browser);
  for(int browser:browsers)OriginalPDFPresenceSuspend(browser);
}
static bool OriginalPDFPresenceRegister(Tab& tab) {
#if YABCORE_ORIGINAL_PDF_PRESENCE_API
  if(!YABCORE_ORIGINAL_PDF_PRESENCE||!tab.browser||!tab.adopted||tab.internal||
      tab.closing||tab.crashed||!hello||stopping||!originalPDFConnection)return false;
  OriginalPDFPresenceIdentity current;if(!OriginalPDFPresenceCurrent(tab,current))return false;
  auto owner=std::make_shared<OriginalPDFPresenceOwner>();
  static_cast<OriginalPDFPresenceIdentity&>(*owner)=std::move(current);
  // Freeze this admission stamp for the existing V2 ACK mapping. A later CDP
  // clear does not replace the native document or mutate an admitted scope.
  OriginalPDFPresenceSuspend(owner->browser);originalPDFPresence[owner->browser]=owner;
  if(!tab.browser->GetHost()->SetOriginalPdfPresenceCallback(new OriginalPDFPresenceDone(owner))) {
    owner->active=false;originalPDFPresence.erase(owner->browser);return false;
  }
  return true;
#else
  return false;
#endif
}
static void OriginalPDFPresenceDocumentEnded(CefRefPtr<CefBrowser> browser) {
  auto wanted=originalPDFPresenceWanted.find(browser->GetIdentifier());
  if(wanted==originalPDFPresenceWanted.end())return;
  auto tab=tabs.find(wanted->second.tab);
  if(tab==tabs.end()||!tab->second.browser||tab->second.profile!=wanted->second.profile||
      originalPDFConnection!=wanted->second.connection||
      reinterpret_cast<uintptr_t>(tab->second.browser.get())!=wanted->second.browserIdentity) {
    OriginalPDFPresenceClosed(browser->GetIdentifier());return;
  }
  OriginalPDFPresenceRegister(tab->second);
}
static bool OriginalPDFPresenceRequest(Tab& tab,NSString* method,NSDictionary* p,NSString* request) {
  if(![method isEqual:@"page.originalPDF.observe"])return false;
  id enabled=p[@"enabled"];
  if(!enabled||CFGetTypeID((__bridge CFTypeRef)enabled)!=CFBooleanGetTypeID()) {
    Reply(request,nil,@"Original PDF observe requires a boolean");return true;
  }
  int browser=tab.browser->GetIdentifier();
  if(![enabled boolValue]) {OriginalPDFPresenceClosed(browser);Reply(request,@{@"observing":@NO});return true;}
  if(!OriginalPDFPresenceRegister(tab)) {Reply(request,nil,@"Native original PDF presence unavailable");return true;}
  auto owner=originalPDFPresence[browser];
  if(!OriginalPDFPresenceLive(owner)) {
    OriginalPDFPresenceClosed(browser);Reply(request,nil,@"Original PDF owner retired during subscription");return true;
  }
  originalPDFPresenceWanted[browser]=*owner;
  Reply(request,@{@"observing":@YES,@"documentGeneration":@(owner->generation),
      @"nativeBrowserId":@(owner->browser)});return true;
}
