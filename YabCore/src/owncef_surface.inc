// Included inside namespace yc after the wire event helpers.
#if YABCORE_OWNCEF_SURFACES
static void PublishOwnCEFSurface(Tab& tab) {
  const auto& frame = tab.surface;
  const bool nativePage = tab.externalPage && [tab.nativePageReceipt[@"rendererBound"] boolValue];
  NSDictionary* state = @{
    @"contextId": @(frame.context),
    @"width": nativePage ? tab.nativePageReceipt[@"pageWidth"] : @(frame.context ? frame.pixelWidth / (double)frame.scale : tab.width),
    @"height": nativePage ? tab.nativePageReceipt[@"pageHeight"] : @(frame.context ? frame.pixelHeight / (double)frame.scale : tab.height),
    @"pageX": nativePage ? tab.nativePageReceipt[@"pageX"] : @0,
    @"pageY": nativePage ? tab.nativePageReceipt[@"pageY"] : @0,
    @"pixelWidth": @(frame.pixelWidth), @"pixelHeight": @(frame.pixelHeight),
    @"scale": @(frame.scale), @"requestedScale": @(tab.scale),
    @"visible": @(tab.visible), @"source": @"cefCallback"
  };
  NSString* encoded = JSON(state);
  if (![encoded isEqual:tab.lastLayer]) {
    tab.lastLayer = encoded;
    if (!tab.internal) Event(@"layer.changed", &tab, state);
  }
}

// tab.resize with a serial is acknowledged by the first window-compositor CA
// frame at that DIP size. Externally hosted views use Chrome's bounded resize
// deadline (patch 0009), so that root frame waits for the page's new-size
// frame instead of aggregating stale pixels. This is not a display fence.
static void AcknowledgeResize(Tab& tab) {
  const auto& frame = tab.surface;
  if (!tab.resizeSerial || !frame.context || frame.scale <= 0) return;
  const double pageWidth = tab.externalPage ? [tab.nativePageReceipt[@"pageWidth"] doubleValue] : frame.pixelWidth / frame.scale;
  const double pageHeight = tab.externalPage ? [tab.nativePageReceipt[@"pageHeight"] doubleValue] : frame.pixelHeight / frame.scale;
  if (std::lround(pageWidth) != tab.resizeWidth ||
      std::lround(pageHeight) != tab.resizeHeight) return;
  NSString* serial = tab.resizeSerial;
  tab.resizeSerial = nil;
  if (!tab.internal) Event(@"tab.resized", &tab, @{@"serial": serial,
      @"width": @(tab.resizeWidth), @"height": @(tab.resizeHeight),
      @"contextId": @(frame.context), @"pixelWidth": @(frame.pixelWidth),
      @"pixelHeight": @(frame.pixelHeight), @"scale": @(frame.scale)});
}

static void OwnCEFFrame(const std::string& id, uint32_t context,
                        const CefSize& pixels, float scale) {
  auto found = tabs.find(id);
  if (found == tabs.end() || found->second.closing) return;
  auto& tab = found->second;
  if (tab.surface.Update(context, pixels.width, pixels.height, scale))
    PublishOwnCEFSurface(tab);
  AcknowledgeResize(tab);
}
#endif
