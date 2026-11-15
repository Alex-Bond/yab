// A page's window is never on screen, so AppKit can neither start a drag from
// it nor deliver one to it. Chromium hands over both ends: a drag a page starts
// comes here as Input.dragIntercepted, and whatever the client's view is
// dragged over goes back in through Input.dispatchDragEvent. The drag itself
// is AppKit's, in the client's view. Trusted CDP input from an agent keeps
// DevTools' own drag controller, which interception would turn off.
static void DragAttach(Tab& tab) {
  CDP(tab, @"Input.setInterceptDrags", @{@"enabled": @YES}, Ignore);
}
static void DragScriptInput(NSString* kind, std::vector<std::pair<NSString*, NSDictionary*>>& commands, bool before) {
  if (before && [kind isEqual:@"mousePressed"]) commands.push_back({@"Input.setInterceptDrags", @{@"enabled": @NO}});
  if (!before && [kind isEqual:@"mouseReleased"]) commands.push_back({@"Input.setInterceptDrags", @{@"enabled": @YES}});
}
static void DragIntercepted(Tab& tab, NSDictionary* params) {
  if (tab.internal) return;
  Event(@"page.dragStart", &tab, @{@"data": params[@"data"] ?: @{}});
}
static bool DragRequest(Tab& tab, NSString* method, NSDictionary* p, NSString* request) {
  if (![method isEqual:@"input.drag"]) return false;
  NSString* type = S(p, @"type");
  NSDictionary* data = p[@"data"];
  double x = [p[@"x"] doubleValue], y = [p[@"y"] doubleValue];
  if (![@[@"dragEnter", @"dragOver", @"drop", @"dragCancel"] containsObject:type] ||
      ![data isKindOfClass:NSDictionary.class] || !std::isfinite(x) || !std::isfinite(y)) {
    Reply(request, nil, @"Invalid drag event"); return true;
  }
  for (id path in [data[@"files"] isKindOfClass:NSArray.class] ? data[@"files"] : @[]) {
    if (![path isKindOfClass:NSString.class] || ![path isAbsolutePath]) { Reply(request, nil, @"Dragged paths must be absolute"); return true; }
  }
  std::string tabID = tab.id;
  // CDP multiplies a drag's point by the page's zoom and its pinch scale;
  // the page says both (WithPageZoom, page_zoom.h).
  WithPageZoom(tab, request, [=](double zoom, double pinch) {
    auto live = tabs.find(tabID);
    if (live == tabs.end()) { Reply(request, nil, @"Page closed during a drag"); return; }
    CDP(live->second, @"Input.dispatchDragEvent", @{@"type": type, @"x": @(x / zoom / pinch), @"y": @(y / zoom / pinch), @"data": data,
      @"modifiers": p[@"modifiers"] ?: @0}, [request, type, x, y](NSDictionary* value, NSString* error) {
        if (error || getenv("YAB_CEF_TRACE_INPUT")) fprintf(stderr, "YabCore drag %s at %.0f,%.0f: %s\n", type.UTF8String, x, y, error.UTF8String ?: "ok");
        Reply(request, value, error);
      });
  });
  return true;
}
