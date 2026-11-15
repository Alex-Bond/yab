// Chrome's DevToolsFileHelper protocol, on the ordinary-page frontend.
// Paths come only from CEF's native chooser, never from the frontend's URL.
static void DevToolsFileResult(const std::shared_ptr<DevToolsRelay>& relay,
                              NSString* event, NSArray* arguments, NSString* error = nil) {
  auto front = tabs.find(relay->front);
  if (relay->stopped || front == tabs.end() || front->second.closing) return;
  NSString* expression = [NSString stringWithFormat:@"globalThis.InspectorFrontendAPI?.[%@](...%@)",
      JSON(event), JSON(arguments)];
  if (error) expression = [expression stringByAppendingFormat:@";console.error(%@)", JSON(error)];
  CDP(front->second, @"Runtime.evaluate", @{@"expression": expression}, Ignore);
}
static void DevToolsWriteFile(std::shared_ptr<DevToolsRelay> relay, NSString* url,
                             NSString* content, bool base64, NSString* path, bool append) {
  // Own the relay by value: both asynchronous blocks must outlive the
  // dialog callback and the caller's map iterator.
  // Like Chromium's sequenced file task runner, acknowledge only after the
  // write: FileOutputStream waits for each append before sending the next.
  dispatch_async(relay->fileQueue, ^{
    NSError* error = nil;
    NSData* data = base64 ? [[NSData alloc] initWithBase64EncodedString:content options:0]
                          : [content dataUsingEncoding:NSUTF8StringEncoding];
    BOOL written = NO;
    if (!data) error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteInapplicableStringEncodingError userInfo:nil];
    else if (!append) written = [data writeToFile:path options:NSDataWritingAtomic error:&error];
    else {
      NSFileHandle* file = [NSFileHandle fileHandleForWritingToURL:[NSURL fileURLWithPath:path] error:&error];
      if (file) {
        written = [file seekToEndReturningOffset:nullptr error:&error] && [file writeData:data error:&error];
        NSError* closeError = nil;
        if (![file closeAndReturnError:&closeError]) { written = NO; error = error ?: closeError; }
      }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      if (relay->stopped) return;
      if (written) {
        if (!append) relay->savedFiles[Key(url)] = path;
        DevToolsFileResult(relay, append ? @"appendedToURL" : @"savedURL", append ? @[url] : @[url, path]);
      } else {
        relay->savedFiles.erase(Key(url));
        DevToolsFileResult(relay, @"canceledSaveURL", @[url],
            [NSString stringWithFormat:@"DevTools could not write %@: %@", path.lastPathComponent, error.localizedDescription ?: @"Write failed"]);
      }
    });
  });
}
class DevToolsSaveDialog : public CefRunFileDialogCallback {
  std::shared_ptr<DevToolsRelay> relay_;
  NSString* url_;
  NSString* content_;
  bool base64_;
 public:
  DevToolsSaveDialog(std::shared_ptr<DevToolsRelay> relay, NSString* url, NSString* content, bool base64)
      : relay_(relay), url_(url), content_(content), base64_(base64) {}
  void OnFileDialogDismissed(const std::vector<CefString>& paths) override {
    if (relay_->stopped) return;
    if (paths.empty()) DevToolsFileResult(relay_, @"canceledSaveURL", @[url_]);
    else DevToolsWriteFile(relay_, url_, content_, base64_, Str(paths.front()), false);
  }
  IMPLEMENT_REFCOUNTING(DevToolsSaveDialog);
};
static bool DevToolsFileMessage(CefRefPtr<CefBrowser> browser, NSDictionary* message) {
  if (![S(message, @"method") isEqual:@"Runtime.bindingCalled"] ||
      ![S(message[@"params"], @"name") isEqual:@"yabDevToolsFile"]) return false;
  auto tab = Find(browser);
  auto relay = tab ? devToolsRelays.find(tab->id) : devToolsRelays.end();
  if (!tab || !tab->devToolsFrontend || relay == devToolsRelays.end() || relay->second->stopped) return true;
  // Extension frames and isolated worlds must never save as the frontend.
  bool trusted = false;
  for (const auto& [key, context] : tab->scripts.contexts) {
    if (context.id != [message[@"params"][@"executionContextId"] intValue] ||
        ![context.session isEqual:S(message, @"sessionId")]) continue;
    trusted = context.isDefault && [context.frame isEqual:tab->scripts.mainFrame] &&
              [context.origin isEqual:@"devtools://devtools"];
    break;
  }
  if (!trusted || ![Str(browser->GetMainFrame()->GetURL()) hasPrefix:@"devtools://devtools/bundled/"]) return true;
  NSData* bytes = [S(message[@"params"], @"payload") dataUsingEncoding:NSUTF8StringEncoding];
  id value = [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
  if (![value isKindOfClass:NSDictionary.class] || ![value[@"url"] isKindOfClass:NSString.class] ||
      ![value[@"content"] isKindOfClass:NSString.class]) return true;
  NSString* method = S(value, @"method"), *url = S(value, @"url"), *content = S(value, @"content");
  auto saved = relay->second->savedFiles.find(Key(url));
  if ([method isEqual:@"append"]) {
    if (saved != relay->second->savedFiles.end()) DevToolsWriteFile(relay->second, url, content, false, saved->second, true);
  } else if ([method isEqual:@"save"]) {
    bool base64 = [value[@"isBase64"] boolValue];
    if (saved != relay->second->savedFiles.end() && ![value[@"forceSaveAs"] boolValue])
      DevToolsWriteFile(relay->second, url, content, base64, saved->second, false);
    else {
      // Only a suggested basename reaches the chooser, never a disk path.
      NSString* name = [NSURL URLWithString:url].lastPathComponent;
      if (!name.length) name = url.lastPathComponent;
      name = [[name componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/\\\\:"]] componentsJoinedByString:@"_"];
      name = [[name componentsSeparatedByCharactersInSet:NSCharacterSet.controlCharacterSet] componentsJoinedByString:@"_"];
      if (!name.length || [name isEqual:@"."] || [name isEqual:@".."]) name = @"download";
      browser->GetHost()->RunFileDialog(FILE_DIALOG_SAVE, "", Key(name), {},
          new DevToolsSaveDialog(relay->second, url, content, base64));
    }
  }
  return true;
}
