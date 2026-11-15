// Included by core.mm before scripts.inc, which gives a frame's field the same way.
// An agent's files go to a page the way Chromium's own automation gives them
// (Puppeteer's uploadFile, Playwright's setInputFiles), never through the
// person's chooser. Chrome opens no chooser for a hidden or inactive tab
// (WebContentsImpl::RunFileChooser) and Yab's native one needs the page shown
// and focused: an agent's tab working out of sight is neither, so its picker
// was refused and upload() failed (feedback #1963). By path, DOM.setFileInputFiles,
// so a video is not copied through the 4 MiB wire either.
static NSArray* AgentFilePaths(id value) {
  if (![value isKindOfClass:NSArray.class] || ![value count] || [value count] > 1024) return nil;
  for (id path in value) {
    if (![path isKindOfClass:NSString.class] || ![path isAbsolutePath]) return nil;
    NSData* bytes = [path dataUsingEncoding:NSUTF8StringEncoding];
    if (!bytes || memchr(bytes.bytes, 0, bytes.length)) return nil;
  }
  return value;
}
// The field an agent world's function returned: a node, given the paths.
static void AgentSetFiles(Tab& tab, NSDictionary* result, NSString* error, NSArray* paths, NSString* session, NSString* request) {
  NSString* object = S(result[@"result"], @"objectId");
  if (error || result[@"exceptionDetails"]) {
    Reply(request, nil, error ?: [@"JavaScript exception: " stringByAppendingString:JSON(result[@"exceptionDetails"])]);
  } else if (!object.length || ![S(result[@"result"], @"subtype") isEqual:@"node"]) {
    Reply(request, @{@"set": @NO});
  } else {
    CDP(tab, @"DOM.setFileInputFiles", @{@"files": paths, @"objectId": object}, [request](NSDictionary*, NSString* e) {
      Reply(request, e ? nil : @{@"set": @YES}, e);
    }, session);
  }
  if (object.length) CDP(tab, @"Runtime.releaseObject", @{@"objectId": object}, Ignore, session);
}
// A picker the page opens itself from a press (a hidden field behind an
// "Add video" button): offered, the next one is intercepted in the renderer
// (Page.setInterceptFileChooserDialog) and answered with the offer's paths.
static void AgentInterceptFiles(Tab& tab, bool enabled) {
  CDP(tab, @"Page.setInterceptFileChooserDialog", @{@"enabled": @(enabled)}, Ignore);
  for (const auto& session : tab.scripts.sessions)
    CDP(tab, @"Page.setInterceptFileChooserDialog", @{@"enabled": @(enabled)}, Ignore, @(session.c_str()));
}
static bool AgentFilesRequest(Tab& tab, NSString* method, NSDictionary* p, NSString* request) {
  if (![method isEqual:@"files.offer"]) return false;
  if ([p[@"withdraw"] boolValue]) {
    // Never taken: the press opened no picker. Chooser interception goes off.
    if (tab.offeredFiles) { tab.offeredFiles = nil; AgentInterceptFiles(tab, false); }
    Reply(request);
    return true;
  }
  NSArray* paths = AgentFilePaths(p[@"paths"]);
  if (!paths) { Reply(request, nil, @"paths must be absolute file paths"); return true; }
  tab.offeredFiles = paths;
  AgentInterceptFiles(tab, true);
  Reply(request);
  return true;
}
// Page.fileChooserOpened: on the main target's session or a frame's own.
static void AgentFilesEvent(Tab& tab, NSString* method, NSDictionary* params, NSString* session) {
  if (![method isEqual:@"Page.fileChooserOpened"]) return;
  std::string id = tab.id;
  NSNumber* node = params[@"backendNodeId"];
  bool single = ![S(params, @"mode") isEqual:@"selectMultiple"];
  // Out of the observer's notification: the answer sends commands.
  dispatch_async(dispatch_get_main_queue(), ^{
    auto found = tabs.find(id);
    if (found == tabs.end()) return;
    Tab& t = found->second;
    NSArray* paths = t.offeredFiles;
    if (!paths) { AgentInterceptFiles(t, false); return; }
    t.offeredFiles = nil;
    AgentInterceptFiles(t, false);
    if (![node isKindOfClass:NSNumber.class]) { Event(@"files.taken", &t, @{@"error": @"The picker has no file field"}); return; }
    NSArray* given = single ? @[paths.firstObject] : paths;
    CDP(t, @"DOM.setFileInputFiles", @{@"files": given, @"backendNodeId": node}, [id, given](NSDictionary*, NSString* e) {
      auto current = tabs.find(id);
      if (current == tabs.end()) return;
      Event(@"files.taken", &current->second, e ? @{@"error": e} : @{@"count": @(given.count)});
    }, session);
  });
}
