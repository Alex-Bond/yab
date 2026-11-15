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
  NSString* documentURL = nil;
  uint64_t generation = 0;
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
static bool PDFSourceCurrent(const Tab& tab,uint64_t generation,NSString* url) {
  if(tab.closing || !tab.browser || tab.documentGeneration!=generation)return false;
  auto frame=tab.browser->GetMainFrame();
  return frame && [Str(frame->GetURL()) isEqual:url];
}
static bool PrintFindRequest(Tab& tab, NSString* method, NSDictionary* p, NSString* request) {
  if ([method isEqual:@"page.pdf.source"]) {
    const std::string id = tab.id;
    const uint64_t generation = tab.documentGeneration;
    NSString* token=S(p,@"stream");
    if(![[NSUUID alloc] initWithUUIDString:token] || pdfStreams.count(Key(token))) {
      Reply(request,nil,@"PDF source requires a fresh stream identity");return true;
    }
    auto frame=tab.browser ? tab.browser->GetMainFrame() : nullptr;
    if(!frame || tab.closing) { Reply(request,nil,@"PDF document is no longer available");return true; }
    NSString* url = Str(frame->GetURL());
    NSURL* address = [NSURL URLWithString:url];
    NSString* scheme = address.scheme.lowercaseString;
    if ([scheme isEqual:@"file"]) {
      NSError* error = nil;
      NSFileHandle* file = [NSFileHandle fileHandleForReadingFromURL:address error:&error];
      NSNumber* size = nil;
      [address getResourceValue:&size forKey:NSURLFileSizeKey error:&error];
      if (!file || error || !size) { [file closeFile]; Reply(request,nil,error.localizedDescription ?: @"PDF file is unavailable"); return true; }
      PDFStream stream{id,nil}; stream.file=file; stream.size=size.unsignedLongLongValue;
      stream.documentURL=url; stream.generation=generation;
      pdfStreams.emplace(Key(token),std::move(stream));
      Reply(request,@{@"stream":token,@"url":url}); return true;
    }
    if ((! [scheme isEqual:@"https"] && ![scheme isEqual:@"http"]) || address.user || address.password) {
      Reply(request,nil,@"The PDF source must be the current HTTP(S) document or local file"); return true;
    }
    if(!tab.scripts.mainFrame.length) { Reply(request,nil,@"PDF document has no current network frame");return true; }
    PDFStream pending{id,nil};pending.documentURL=url;pending.generation=generation;pending.request=request;
    pdfStreams.emplace(Key(token),std::move(pending));
    CDP(tab,@"Network.loadNetworkResource",@{@"frameId":tab.scripts.mainFrame,
        @"url":url,@"options":@{@"disableCache":@NO,@"includeCredentials":@YES}},
      [id,generation,url,token,request](NSDictionary* result,NSString* error) {
        auto current=tabs.find(id);
        NSDictionary* resource=result[@"resource"];
        NSString* handle=S(resource,@"stream");
        bool live=current!=tabs.end() && PDFSourceCurrent(current->second,generation,url);
        auto stream=pdfStreams.find(Key(token));
        if(stream==pdfStreams.end()) {
          if(handle.length && current!=tabs.end())CDP(current->second,@"IO.close",@{@"handle":handle},Ignore);
          return; // Closing/navigation already retired the pending reply.
        }
        stream->second.request=nil;
        if(error || !live || ![resource[@"success"] boolValue] || !handle.length) {
          if(handle.length && current!=tabs.end())CDP(current->second,@"IO.close",@{@"handle":handle},Ignore);
          ClosePDFStream(Key(token));
          Reply(request,nil,error ?: @"PDF source changed or its network response is unavailable"); return;
        }
        stream->second.handle=handle;
        Reply(request,@{@"stream":token,@"url":url});
      });
    return true;
  }
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
    // No count of streams: each belongs to its tab and goes when read, closed
    // or the tab closes; DevTools' IO streams have no count either.
    // As Chromium prints by default: the sheet's paper (Letter when unsaid),
    // 1 cm margins and 100% scale. Half an inch here, then the sheet's own
    // inch around a page fitted inside it, cut the edges of a receipt (#2001).
    auto inches = [&](NSString* key, double fallback) {
      NSNumber* value = [p[key] isKindOfClass:NSNumber.class] ? p[key] : nil;
      double v = value ? value.doubleValue : fallback;
      return std::isfinite(v) && v >= 1 && v <= 50 ? v : fallback;
    };
    const double paperWidth = inches(@"paperWidth", 8.5), paperHeight = inches(@"paperHeight", 11), margin = 1 / 2.54;
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
      CefPdfPrintSettings settings;settings.print_background=true;settings.paper_width=paperWidth;settings.paper_height=paperHeight;
      settings.margin_type=PDF_PRINT_MARGIN_CUSTOM;settings.margin_top=margin;settings.margin_bottom=margin;
      settings.margin_left=margin;settings.margin_right=margin;
      bool accepted=tab.browser->GetHost()->PrintNativeSourceToPDF(Key(source),Key(path),settings,new NativePDFDone(Key(token)));
      if(!accepted)ClosePDFStream(Key(token));
#else
      Reply(request,nil,@"Native print source is unavailable in this SDK/API mode");
#endif
      return true;
    }
    std::string id = tab.id;
    CDP(tab, @"Page.printToPDF", @{@"transferMode": @"ReturnAsStream", @"printBackground": @YES,
        @"paperWidth": @(paperWidth), @"paperHeight": @(paperHeight), @"marginTop": @(margin), @"marginBottom": @(margin),
        @"marginLeft": @(margin), @"marginRight": @(margin), @"scale": @1, @"preferCSSPageSize": @NO},
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
  if (stream->second.documentURL && !PDFSourceCurrent(tab,stream->second.generation,stream->second.documentURL)) {
    ClosePDFStream(token);Reply(request,nil,@"PDF document changed during its read");return true;
  }
  if(stream->second.documentURL && stream->second.request) {
    Reply(request,nil,@"PDF source is still opening");return true;
  }
  if(stream->second.directory || stream->second.file) {
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
      if(stream->second.documentURL) {
        auto tab=tabs.find(stream->second.tab);
        if(tab==tabs.end() || !PDFSourceCurrent(tab->second,stream->second.generation,stream->second.documentURL)) {
          ClosePDFStream(token);Reply(request,nil,@"PDF document changed during its read");return;
        }
      }
      stream->second.bytes += [S(result, @"data") length];
      if (error || stream->second.bytes > 90 * 1024 * 1024) {
        ClosePDFStream(token); Reply(request, nil, error ?: @"Printed PDF exceeds the stream limit"); return;
      }
      Reply(request, result);
      if ([result[@"eof"] boolValue]) ClosePDFStream(token);
    });
  return true;
}
