// Original loaded engine bytes only. Default-disabled independently of SDK API.

static OriginalPDFBudget originalPDFBudget(8);
struct OriginalPDFBuffer {
  // Declared first: released LAST, after the independent Foundation bytes.
  std::shared_ptr<OriginalPDFBudget::Credit> credit;
  NSData* bytes = nil;
};
struct OriginalPDFFile {
  // FD destructor body runs before this last credit reference is released.
  std::shared_ptr<OriginalPDFBudget::Credit> credit;
  int descriptor = -1;
  size_t size = 0, offset = 0;
  ~OriginalPDFFile() { if (credit) credit->CloseDescriptor(descriptor); }
};
struct OriginalPDFTransfer {
  // Callback, queued UI, writer and file owners retain this actual work credit
  // independently of logical cancellation/map erasure.
  std::shared_ptr<OriginalPDFBudget::Credit> credit;
  std::string lease, tab, profile, call;
  int browser = 0;
  uintptr_t browserIdentity = 0;
  uint64_t generation = 0, connection = 0;
  int phase = 1;  // state=1, source=2, export=3, copying=4, stream=5, closed=0
  double deadline = 0;
  NSString* request = nil;
  NSDictionary* native = nil;
  std::shared_ptr<OriginalPDFFile> file;
  std::atomic<bool> cancelled{false};
};
static uint64_t originalPDFConnection = 1;
static std::map<std::string, std::shared_ptr<OriginalPDFTransfer>> originalPDFTransfers;
static bool OriginalPDFLive(const std::shared_ptr<OriginalPDFTransfer>& item) {
  auto found = originalPDFTransfers.find(item->lease);
  auto tab = tabs.find(item->tab);
  return originalPDFConnection && item->connection == originalPDFConnection && hello && !stopping &&
      !item->cancelled.load() && found != originalPDFTransfers.end() && found->second == item &&
      tab != tabs.end() && tab->second.browser && !tab->second.closing && !tab->second.crashed &&
      tab->second.adopted && !tab->second.internal && tab->second.profile == item->profile &&
      tab->second.documentGeneration == item->generation &&
      tab->second.browser->GetIdentifier() == item->browser &&
      reinterpret_cast<uintptr_t>(tab->second.browser.get()) == item->browserIdentity;
}
static NSDictionary* OriginalPDFEnvelope(const std::shared_ptr<OriginalPDFTransfer>& item) {
  return @{@"tab": @(item->tab.c_str()), @"profile": @(item->profile.c_str()),
           @"call": @(item->call.c_str()), @"lease": @(item->lease.c_str()),
           @"nativeAcknowledged": @YES, @"native": item->native ?: @{}};
}
static void OriginalPDFClose(const std::shared_ptr<OriginalPDFTransfer>& item, NSString* reason, bool reply) {
  item->cancelled.store(true); item->phase = 0;
  NSString* request = item->request; item->request = nil;
  auto found = originalPDFTransfers.find(item->lease);
  if (found != originalPDFTransfers.end() && found->second == item) originalPDFTransfers.erase(found);
  item->file.reset();
  if (reply && request && item->connection == originalPDFConnection && hello && !stopping)
    Reply(request, nil, reason ?: @"Original PDF transfer retired");
}
static void OriginalPDFBrowserClosed(int browser, NSString* reason) {
  std::vector<std::shared_ptr<OriginalPDFTransfer>> items;
  for (const auto& [lease, item] : originalPDFTransfers) if (item->browser == browser) items.push_back(item);
  for (const auto& item : items) OriginalPDFClose(item, reason, true);
}
static void ClearOriginalPDF() {
  // Retire before any callbacks can write to a replacement peer.
  originalPDFConnection = originalPDFConnection == UINT64_MAX ? 0 : originalPDFConnection + 1;
  std::vector<std::shared_ptr<OriginalPDFTransfer>> items;
  for (const auto& [lease, item] : originalPDFTransfers) items.push_back(item);
  for (const auto& item : items) OriginalPDFClose(item, @"Original connection retired", false);
}
static void OriginalPDFPoll() {
  std::vector<std::shared_ptr<OriginalPDFTransfer>> expired;
  for (const auto& [lease, item] : originalPDFTransfers)
    if (item->deadline <= Now()) expired.push_back(item);
  for (const auto& item : expired) OriginalPDFClose(item, @"Original PDF transfer timed out", true);
}
static bool OriginalPDFIdentity(const std::shared_ptr<OriginalPDFTransfer>& item, NSDictionary* p) {
  return [S(p, @"tab") isEqual:@(item->tab.c_str())] &&
      [S(p, @"profile") isEqual:@(item->profile.c_str())] &&
      [S(p, @"call") isEqual:@(item->call.c_str())];
}
static bool OriginalPDFGlobalRequest(NSString* method, NSDictionary* p, NSString* request) {
  if (![method isEqual:@"page.originalPDF.cancel"] && ![method isEqual:@"page.originalPDF.close"]) return false;
  std::vector<std::shared_ptr<OriginalPDFTransfer>> items;
  for (const auto& [lease, item] : originalPDFTransfers)
    if (item->connection == originalPDFConnection && OriginalPDFIdentity(item, p) &&
        (![method isEqual:@"page.originalPDF.close"] || [S(p, @"lease") isEqual:@(lease.c_str())])) items.push_back(item);
  for (const auto& item : items) OriginalPDFClose(item, @"Original PDF transfer cancelled", true);
  Reply(request, @{@"closed": @(!items.empty())}); return true;
}
#if YABCORE_ORIGINAL_PDF_API
static NSDictionary* OriginalPDFNative(CefRefPtr<CefDictionaryValue> value,
                                       const std::shared_ptr<OriginalPDFTransfer>& item, NSString* operation) {
  if (!value || value->GetType("version") != VTYPE_INT || value->GetInt("version") != 1 ||
      value->GetType("browserId") != VTYPE_INT || value->GetInt("browserId") != item->browser ||
      value->GetType("size") != VTYPE_INT || value->GetInt("size") < 0 || value->GetInt("size") > 64*1024*1024)
    return nil;
  NSMutableDictionary* native = [NSMutableDictionary dictionary];
  for (NSString* key in @[@"kind", @"operation", @"request", @"status", @"source", @"rootDocument", @"rootFrameId", @"pdfDocument", @"pdfFrameId", @"listener", @"pluginSource"]) {
    const std::string name = Key(key);
    if (value->GetType(name) != VTYPE_STRING) return nil;
    NSString* text = Str(value->GetString(name));
    if (text.length > 256) return nil;
    native[key] = text;
  }
  for (NSString* key in @[@"available", @"complete"]) {
    if (value->GetType(Key(key)) != VTYPE_BOOL) return nil;
    native[key] = @(value->GetBool(Key(key)));
  }
  native[@"version"] = @1; native[@"browserId"] = @(item->browser); native[@"size"] = @(value->GetInt("size"));
  if (![native[@"kind"] isEqual:@"originalLoadedPDF"] || ![native[@"operation"] isEqual:operation] ||
      !S(native,@"request").length || ![@[@"ready",@"unavailable",@"unknown"] containsObject:native[@"status"]]) return nil;
  return native;
}
static bool OriginalPDFReady(NSDictionary* native, bool exporting) {
  if (!native || ![S(native,@"status") isEqual:@"ready"] || ![native[@"available"] isEqual:@YES] ||
      ![native[@"complete"] isEqual:@(exporting)] || [native[@"size"] unsignedLongLongValue] < 1) return false;
  for (NSString* key in @[@"source",@"rootDocument",@"rootFrameId",@"pdfDocument",@"pdfFrameId",@"listener",@"pluginSource"])
    if (!S(native,key).length) return false;
  return true;
}
static bool OriginalPDFSameSource(NSDictionary* a, NSDictionary* b) {
  for (NSString* key in @[@"browserId",@"size",@"source",@"rootDocument",@"rootFrameId",@"pdfDocument",@"pdfFrameId",@"listener",@"pluginSource"])
    if (![a[key] isEqual:b[key]]) return false;
  return ![a[@"request"] isEqual:b[@"request"]];
}
static std::shared_ptr<OriginalPDFFile> OriginalPDFWrite(const std::shared_ptr<OriginalPDFBuffer>& buffer,
    size_t size, const std::shared_ptr<OriginalPDFTransfer>& item, NSString* __autoreleasing* failure) {
  NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"yab-original-pdf-" stringByAppendingString:NSUUID.UUID.UUIDString]];
  std::string name = Key(path);
  int descriptor = open(name.c_str(),O_CREAT|O_EXCL|O_RDWR|O_CLOEXEC,0600);
  if (descriptor < 0) { *failure = @"Original PDF temporary file unavailable"; return {}; }
  auto file = std::make_shared<OriginalPDFFile>(); file->credit = buffer->credit; file->descriptor = descriptor;
  // Anonymous descriptor: process loss cannot leave original/private PDF bytes
  // in a named temporary file. Every exit closes it through the owner object.
  if (unlink(name.c_str())) {
    buffer->credit->Poison();
    *failure = @"Original PDF temporary file cannot be secured"; return {};
  }
  const uint8_t* bytes = static_cast<const uint8_t*>(buffer->bytes.bytes);
  for (size_t offset = 0; offset < size;) {
    if (item->cancelled.load()) { *failure = @"Original PDF transfer cancelled"; return {}; }
    size_t amount = std::min<size_t>(65536, size-offset);
    size_t written = 0;
    while (written < amount) {
      ssize_t count = write(descriptor, bytes+offset+written, amount-written);
      if (count < 0 && errno == EINTR) continue;
      if (count <= 0) { *failure = @"Original PDF temporary write failed"; return {}; }
      written += static_cast<size_t>(count);
    }
    offset += amount;
  }
  file->size = size; return file;
}
static void OriginalPDFCopy(const std::shared_ptr<OriginalPDFTransfer>& item,
                            NSDictionary* native, std::shared_ptr<OriginalPDFBuffer> bytes) {
  const size_t size = [native[@"size"] unsignedLongLongValue];
  item->phase = 4; item->native = native; item->deadline = Now()+15;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
    @autoreleasepool {
      NSString* failure = nil;
      auto file = OriginalPDFWrite(bytes, size, item, &failure);
      dispatch_async(dispatch_get_main_queue(), ^{
        if (!OriginalPDFLive(item)) { OriginalPDFClose(item,@"Original PDF owner retired",true); return; }
        if (!file || failure || file->size != size) { OriginalPDFClose(item,failure ?: @"Original PDF binary incomplete",true); return; }
        item->file = file; item->phase = 5; item->deadline = Now()+30;
        NSString* request = item->request; item->request = nil;
        Reply(request, OriginalPDFEnvelope(item));
      });
    }
  });
}
class OriginalPDFDone final : public CefOriginalPdfCallback {
  std::shared_ptr<OriginalPDFTransfer> item_;
  const int phase_;
 public:
  OriginalPDFDone(std::shared_ptr<OriginalPDFTransfer> item, int phase):item_(std::move(item)),phase_(phase) {}
  void OnOriginalPdfResult(CefRefPtr<CefDictionaryValue> result, CefRefPtr<CefBinaryValue> binary) override {
    auto item = item_; const int phase = phase_;
    NSDictionary* native = OriginalPDFNative(result,item,phase == 1 ? @"state" : @"export");
    NSDictionary* trace = @{@"call": @(item->call.c_str()), @"browserId": @(item->browser),
      @"phase": @(phase), @"nativeRequest": S(native,@"request"), @"status": S(native,@"status"),
      @"afterHelperTerminal": @(item->phase != phase || item->cancelled.load())};
    fprintf(stderr,"YAB_NATIVE_ORIGINAL_PDF_ACK %s\n",JSON(trace).UTF8String);
    if (item->phase != phase || item->cancelled.load()) return;
    // Consume EVERY CEF value synchronously in the actual SDK callback. No
    // queued main/utility block can retain a CEF value across framework unload.
    std::shared_ptr<OriginalPDFBuffer> bytes;
    bool valid = OriginalPDFReady(native,phase == 3) && (phase != 1 || !binary);
    if (valid && phase == 3) {
      const size_t size = [native[@"size"] unsignedLongLongValue];
      valid = binary && binary->GetSize() == size && OriginalPDFSameSource(item->native,native);
      if (valid) {
        bytes = std::make_shared<OriginalPDFBuffer>(); bytes->credit = item->credit;
        NSMutableData* copy = [NSMutableData dataWithLength:size];
        valid = copy && binary->GetData(copy.mutableBytes,size,0) == size;
        if (valid) bytes->bytes = copy;
      }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      if (item->phase != phase || item->cancelled.load()) return;
      if (!OriginalPDFLive(item)) { OriginalPDFClose(item,@"Original PDF owner retired",true); return; }
      if (!valid || (phase == 3 && (!bytes || bytes->bytes.length != [native[@"size"] unsignedLongLongValue]))) {
        OriginalPDFClose(item,@"Original native PDF source unavailable or unknown",true); return;
      }
      if (phase == 1) {
        item->native = native; item->phase = 2; item->deadline = Now()+30;
        NSString* request = item->request; item->request = nil;
        Reply(request, OriginalPDFEnvelope(item));
      } else OriginalPDFCopy(item,native,bytes);
    });
  }
  IMPLEMENT_REFCOUNTING(OriginalPDFDone);
};
#endif
static bool OriginalPDFRequest(Tab& tab, NSString* method, NSDictionary* p, NSString* request) {
  if (![method isEqual:@"page.originalPDF.state"] && ![method isEqual:@"page.originalPDF.export"] && ![method isEqual:@"page.originalPDF.read"]) return false;
#if YABCORE_ORIGINAL_PDF_API
  if (!YABCORE_ORIGINAL_PDF) { Reply(request,nil,@"Original native PDF adapter is disabled"); return true; }
  if (!tab.browser || tab.closing || tab.crashed || tab.internal || !tab.adopted ||
      ![S(p,@"profile") isEqual:@(tab.profile.c_str())] || !S(p,@"call").length ||
      [S(p,@"call") lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 128) {
    Reply(request,nil,@"Exact original PDF owner required"); return true;
  }
  if ([method isEqual:@"page.originalPDF.state"]) {
    if (!originalPDFConnection || originalPDFTransfers.size() >= 8) { Reply(request,nil,@"Original PDF transfer limit"); return true; }
    for (const auto& [lease,item] : originalPDFTransfers) if (item->tab == tab.id) { Reply(request,nil,@"Original PDF transfer already active"); return true; }
    // Retired native callbacks/writers/files still consume these credits.
    auto credit = originalPDFBudget.Acquire(tab.id);
    if (!credit) { Reply(request,nil,@"Original PDF native work still owns this budget"); return true; }
    auto item = std::make_shared<OriginalPDFTransfer>(); item->credit = std::move(credit);
    item->lease = Key(NSUUID.UUID.UUIDString); item->tab = tab.id; item->profile = tab.profile; item->call = Key(S(p,@"call"));
    item->browser = tab.browser->GetIdentifier(); item->browserIdentity = reinterpret_cast<uintptr_t>(tab.browser.get());
    item->generation = tab.documentGeneration; item->connection = originalPDFConnection;
    item->request = request; item->deadline = Now()+10;
    originalPDFTransfers.emplace(item->lease,item);
    if (!tab.browser->GetHost()->RequestOriginalPdfState(new OriginalPDFDone(item,1))) OriginalPDFClose(item,@"Original native PDF unavailable before dispatch",true);
    return true;
  }
  auto found = originalPDFTransfers.find(Key(S(p,@"lease")));
  if (found == originalPDFTransfers.end() || !OriginalPDFIdentity(found->second,p) || !OriginalPDFLive(found->second)) {
    Reply(request,nil,@"Original PDF lease is stale or foreign"); return true;
  }
  auto item = found->second;
  if ([method isEqual:@"page.originalPDF.export"]) {
    if (item->phase != 2 || ![S(p,@"source") isEqual:S(item->native,@"source")]) { Reply(request,nil,@"Original PDF source does not match"); return true; }
    item->phase = 3; item->request = request; item->deadline = Now()+10;
    if (!tab.browser->GetHost()->ExportOriginalPdf(Key(S(item->native,@"source")),64*1024*1024,new OriginalPDFDone(item,3)))
      OriginalPDFClose(item,@"Original PDF export unavailable before dispatch",true);
    return true;
  }
  if (item->phase != 5 || !item->file) { Reply(request,nil,@"Original PDF binary stream not ready"); return true; }
  auto file = item->file;
  size_t offset = file->offset, amount = std::min<size_t>(196608,file->size-offset);
  std::vector<uint8_t> bytes(amount);
  ssize_t count;
  do { count = pread(file->descriptor,bytes.data(),amount,offset); } while (count < 0 && errno == EINTR);
  if (count < 0 || static_cast<size_t>(count) != amount) { OriginalPDFClose(item,@"Original PDF stream ended early",true); Reply(request,nil,@"Original PDF stream ended early"); return true; }
  file->offset += amount; bool eof = file->offset == file->size;
  NSMutableDictionary* reply = [OriginalPDFEnvelope(item) mutableCopy];
  reply[@"offset"] = @(offset); reply[@"size"] = @(file->size); reply[@"eof"] = @(eof);
  reply[@"base64Encoded"] = @YES; reply[@"data"] = [[NSData dataWithBytes:bytes.data() length:amount] base64EncodedStringWithOptions:0];
  if (eof) OriginalPDFClose(item,nil,false); else item->deadline = Now()+30;
  Reply(request,reply); return true;
#else
  Reply(request,nil,@"Original PDF API is unavailable in this SDK/API mode"); return true;
#endif
}
