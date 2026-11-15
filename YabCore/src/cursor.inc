// The cursor of a page. A process with no window on screen can't set one: it
// is handed to the client, whose view is what the pointer is over. Chromium's own NSCursor comes along as a picture, once for each kind,
// so every cursor it has, a page's custom ones too, looks as it does in Chrome.
// Keys whose picture went to the client, most recent last. A page that draws
// a new custom cursor for every frame grew this and the client's copy without
// end; past kSentCursors the least recent is forgotten here, so it comes with
// its picture again if a page uses it again. The client keeps twice as many
// (ChromiumCursors.kept), so all of these are still there.
static std::set<std::string> sentCursors;
static std::deque<std::string> sentCursorOrder;
static constexpr size_t kSentCursors = 512;
static void TouchCursor(const std::string& key) {
  auto at = std::find(sentCursorOrder.begin(), sentCursorOrder.end(), key);
  if (at != sentCursorOrder.end()) sentCursorOrder.erase(at);
  sentCursorOrder.push_back(key);
  while (sentCursorOrder.size() > kSentCursors) { sentCursors.erase(sentCursorOrder.front()); sentCursorOrder.pop_front(); }
}
static void CursorChanged(Tab* t, cef_cursor_handle_t handle, int type, const CefCursorInfo& custom) {
  NSCursor* cursor = CAST_CEF_CURSOR_HANDLE_TO_NSCURSOR(handle);
  std::string key = std::to_string(type);
  if (custom.buffer && custom.size.width > 0 && custom.size.height > 0 && custom.size.width <= 256 && custom.size.height <= 256) {
    size_t hash = 5381, bytes = size_t(custom.size.width) * custom.size.height * 4;
    auto pixels = static_cast<const unsigned char*>(custom.buffer);
    for (size_t i = 0; i < bytes; ++i) hash = hash * 33 + pixels[i];
    key = "c" + std::to_string(hash) + "." + std::to_string(custom.hotspot.x) + "." + std::to_string(custom.hotspot.y);
  }
  // Chromium's CT_NONE is a 1x1 NSImage with no representations. It has
  // no TIFF to send: preserve the semantic cursor instead of asking the
  // client to recover it from an absent picture (which means arrow fallback).
  NSMutableDictionary* p = [@{@"key": @(key.c_str()), @"hidden": @(type == CT_NONE)} mutableCopy];
  if (cursor && !sentCursors.count(key)) {
    NSData* picture = cursor.image.TIFFRepresentation;
    if (picture.length && picture.length < 1 << 20) {
      sentCursors.insert(key);
      TouchCursor(key);
      p[@"picture"] = [picture base64EncodedStringWithOptions:0];
      p[@"hotX"] = @(cursor.hotSpot.x); p[@"hotY"] = @(cursor.hotSpot.y);
      // A TIFF of every representation comes back at its largest without this.
      p[@"width"] = @(cursor.image.size.width); p[@"height"] = @(cursor.image.size.height);
    }
  }
  if (sentCursors.count(key) && !p[@"picture"]) TouchCursor(key);
  Event(@"page.cursor", t, p);
}
