// Private navigation capabilities, included after the shared CDP dispatcher.
struct NativeFind {
  NSString* request = nil;
  NSString* text = nil;
  int identifier = -1;
  int finished = -1;
};
static std::map<std::string, NativeFind> nativeFinds;
#if defined(CEF_YAB_NATIVE_PRINT_SOURCE_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_NATIVE_PRINT_SOURCE 1
#else
#define YABCORE_NATIVE_PRINT_SOURCE 0
#endif
struct PDFStream {
  std::string tab;
  NSString* handle;
  size_t bytes = 0;
  NSString* source = nil;
  NSString* directory = nil;
  NSString* path = nil;
  NSFileHandle* file = nil;
  NSString* request = nil;
  unsigned long long size = 0;
};
static std::map<std::string, PDFStream> pdfStreams;
static void ClosePDFStream(std::string token, bool dispatch = true) {
  auto stream = pdfStreams.find(token);
  if (stream == pdfStreams.end()) return;
  auto tab = tabs.find(stream->second.tab);
  NSString* handle = stream->second.handle;
  NSString* pending = stream->second.request;
  NSString* directory = stream->second.directory;
  [stream->second.file closeFile];
  pdfStreams.erase(stream);
  if (directory) [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
  if (pending) Reply(pending, nil, @"Native PDF export was retired");
  if (dispatch && handle && tab != tabs.end()) CDP(tab->second, @"IO.close", @{@"handle": handle}, Ignore);
}
static void ClearPDFStreams() {
  std::vector<std::string> tokens;
  for(const auto& [token,stream]:pdfStreams)tokens.push_back(token);
  for(const auto& token:tokens)ClosePDFStream(token,false);
}
static void CancelNativePrintSource(Tab& tab,const std::string& source) {
  std::vector<std::string> tokens;
  for(const auto& [token,stream]:pdfStreams)
    if(stream.tab==tab.id && stream.source && Key(stream.source)==source)tokens.push_back(token);
  for(const auto& token:tokens)ClosePDFStream(token);
}
static void CancelNativeFind(Tab& tab, NSString* reason) {
  auto find = nativeFinds.find(tab.id);
  if (find != nativeFinds.end()) {
    NSString* request = find->second.request;
    find->second.request = nil; find->second.text = nil;
    find->second.finished = std::max(find->second.finished, find->second.identifier);
    if (request) Reply(request, nil, reason);
  }
}
static void CancelPrintFind(Tab& tab, NSString* reason) {
  CancelNativeFind(tab, reason);
  std::vector<std::string> streams;
  for (const auto& [token, stream] : pdfStreams) if (stream.tab == tab.id) streams.push_back(token);
  for (const auto& token : streams) ClosePDFStream(token);
}
static void NativeFindResult(Tab* tab, int identifier, int count, int ordinal, bool final) {
  if (!tab) return;
  auto found = nativeFinds.find(tab->id);
  if (found == nativeFinds.end()) return;
  auto& find = found->second;
  if (!find.request || identifier <= find.finished) return;
  if (find.identifier < 0) find.identifier = identifier;
  if (find.identifier != identifier || !final) return;
  NSString* request = find.request;
  find.request = nil; find.finished = identifier; find.identifier = -1;
  Reply(request, @{@"count": @(count), @"ordinal": @(ordinal)});
}
#if YABCORE_NATIVE_PRINT_SOURCE
class NativePDFDone final : public CefPdfPrintCallback {
 public:
  explicit NativePDFDone(std::string token):token_(std::move(token)) {}
  void OnPdfPrintFinished(const CefString&,bool ok) override {
    auto found=pdfStreams.find(token_);if(found==pdfStreams.end())return;
    auto& stream=found->second;
    auto current=tabs.find(stream.tab);
    NSString* request=stream.request;stream.request=nil;
    NSDictionary* attributes=[NSFileManager.defaultManager attributesOfItemAtPath:stream.path error:nil];
    unsigned long long size=[attributes[NSFileSize] unsignedLongLongValue];
    if(!ok || current==tabs.end() || current->second.closing || !size || ((size+2)/3)*4>90*1024*1024) {
      ClosePDFStream(token_);Reply(request,nil,@"Native source PDF export failed or was retired");return;
    }
    NSError* error=nil;
    stream.file=[NSFileHandle fileHandleForReadingFromURL:[NSURL fileURLWithPath:stream.path] error:&error];
    if(!stream.file) {ClosePDFStream(token_);Reply(request,nil,error.localizedDescription?:@"Native PDF cannot be read");return;}
    stream.size=size;Reply(request,@{@"stream":@(token_.c_str())});
  }
 private:
  std::string token_;
  IMPLEMENT_REFCOUNTING(NativePDFDone);
};
#endif
static bool PrintFindRequest(Tab& tab, NSString* method, NSDictionary* p, NSString* request) {
  if ([method isEqual:@"print.source.release"]) {
#if YABCORE_NATIVE_PRINT_SOURCE
    NSString* source=S(p,@"source");
    bool released=source.length && tab.browser->GetHost()->ReleaseNativePrintSource(Key(source));
    if(source.length)CancelNativePrintSource(tab,Key(source));
    Reply(request,released?@{}:nil,released?nil:@"Native print source is stale or foreign");
#else
    Reply(request,nil,@"Native print source is unavailable in this SDK/API mode");
#endif
    return true;
  }
  if ([method isEqual:@"page.find.stop"]) {
    CancelNativeFind(tab, @"Find stopped");
    tab.browser->GetHost()->StopFinding(true); Reply(request); return true;
  }
  if ([method isEqual:@"page.find"]) {
    auto& find = nativeFinds[tab.id];
    if (find.request) { Reply(request, nil, @"A native find is already pending"); return true; }
    NSString* text = S(p, @"text");
    if (!text.length) {
      tab.browser->GetHost()->StopFinding(true); find.text = nil;
      Reply(request, @{@"count": @0, @"ordinal": @0}); return true;
    }
    find.text = text; find.request = request; find.identifier = -1;
    // CEF 156 passes findNext to Chromium's find_match, including the first
    // query. Chromium starts a new session itself when the text changes.
    tab.browser->GetHost()->Find(Key(text), [p[@"forward"] boolValue], false, true);
    return true;
  }
  if ([method isEqual:@"page.printPDF"]) {
    if (pdfStreams.size() >= 16) { Reply(request, nil, @"Too many open PDF streams"); return true; }
    if (p[@"printSource"]) {
#if YABCORE_NATIVE_PRINT_SOURCE
      NSString* source=S(p,@"printSource");
      if(!source.length) {Reply(request,nil,@"Native print source is required");return true;}
      NSString* token=NSUUID.UUID.UUIDString;
      NSString* directory=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"yab-native-pdf-" stringByAppendingString:token]];
      NSError* error=nil;
      if(![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:NO
          attributes:@{NSFilePosixPermissions:@0700} error:&error]) {
        Reply(request,nil,error.localizedDescription?:@"Native PDF temporary directory unavailable");return true;
      }
      NSString* path=[directory stringByAppendingPathComponent:@"original.pdf"];
      PDFStream stream{tab.id,nil};stream.source=source;stream.directory=directory;stream.path=path;stream.request=request;
      pdfStreams.emplace(Key(token),std::move(stream));
      CefPdfPrintSettings settings;settings.print_background=true;settings.paper_width=8.5;settings.paper_height=11;
      settings.margin_type=PDF_PRINT_MARGIN_CUSTOM;settings.margin_top=.5;settings.margin_bottom=.5;
      settings.margin_left=.5;settings.margin_right=.5;
      bool accepted=tab.browser->GetHost()->PrintNativeSourceToPDF(Key(source),Key(path),settings,new NativePDFDone(Key(token)));
      if(!accepted)ClosePDFStream(Key(token));
#else
      Reply(request,nil,@"Native print source is unavailable in this SDK/API mode");
#endif
      return true;
    }
    std::string id = tab.id;
    CDP(tab, @"Page.printToPDF", @{@"transferMode": @"ReturnAsStream", @"printBackground": @YES,
        @"paperWidth": @8.5, @"paperHeight": @11, @"marginTop": @0.5, @"marginBottom": @0.5,
        @"marginLeft": @0.5, @"marginRight": @0.5, @"preferCSSPageSize": @NO},
      [id, request](NSDictionary* result, NSString* error) {
        auto current = tabs.find(id);
        NSString* handle = S(result, @"stream");
        if (error || !handle.length || current == tabs.end()) { Reply(request, nil, error ?: @"PDF stream missing"); return; }
        NSString* token = NSUUID.UUID.UUIDString;
        pdfStreams.emplace(Key(token), PDFStream{id, handle});
        Reply(request, @{@"stream": token});
      });
    return true;
  }
  if (![method isEqual:@"page.pdf.read"] && ![method isEqual:@"page.pdf.close"]) return false;
  std::string token = Key(S(p, @"stream"));
  auto stream = pdfStreams.find(token);
  if (stream == pdfStreams.end() || stream->second.tab != tab.id) { Reply(request, nil, @"Unknown PDF stream"); return true; }
  if ([method isEqual:@"page.pdf.close"]) { ClosePDFStream(token); Reply(request); return true; }
  if(stream->second.directory) {
    auto& file=stream->second;
    if(!file.file || file.request) {Reply(request,nil,@"Native PDF export has not completed");return true;}
    NSError* error=nil;
    NSData* data=[file.file readDataUpToLength:196608 error:&error];
    if(!data || error) {ClosePDFStream(token);Reply(request,nil,error.localizedDescription?:@"Native PDF read failed");return true;}
    file.bytes+=data.length;
    bool eof=file.bytes>=file.size;
    if(!data.length && !eof) {ClosePDFStream(token);Reply(request,nil,@"Native PDF stream ended early");return true;}
    Reply(request,@{@"data":[data base64EncodedStringWithOptions:0],@"base64Encoded":@YES,@"eof":@(eof)});
    if(eof)ClosePDFStream(token);
    return true;
  }
  CDP(tab, @"IO.read", @{@"handle": stream->second.handle, @"size": @196608},
    [token, request](NSDictionary* result, NSString* error) {
      auto stream = pdfStreams.find(token);
      if (stream == pdfStreams.end()) { Reply(request, nil, @"PDF stream closed"); return; }
      stream->second.bytes += [S(result, @"data") length];
      if (error || stream->second.bytes > 90 * 1024 * 1024) {
        ClosePDFStream(token); Reply(request, nil, error ?: @"Printed PDF exceeds the stream limit"); return;
      }
      Reply(request, result);
      if ([result[@"eof"] boolValue]) ClosePDFStream(token);
    });
  return true;
}
