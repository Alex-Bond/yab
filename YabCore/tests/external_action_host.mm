// Separate-process pixel acceptance host. The test client writes only the
// context metadata received over IPC; this host links AppKit, never CEF.
#include "owncef_layer_host.h"
@interface YCExternalActionWindow : NSWindow
@end
@implementation YCExternalActionWindow
- (BOOL)canBecomeKeyWindow { return YES; }
@end
static NSWindow* window;
static CALayer* parent;
static CALayerHost* host;
static NSString* directory;
static NSString* lastToken;
static NSString* exitToken;
static void ForegroundReceipt() {
  static bool recorded = false, lastKey = false, lastActive = false;
  const bool key = window.isKeyWindow, active = NSApp.isActive;
  if (recorded && key == lastKey && active == lastActive) return;
  recorded = true; lastKey = key; lastActive = active;
  [[NSJSONSerialization dataWithJSONObject:@{@"window": @(window.windowNumber), @"pid": @(getpid()),
    @"key": @(key), @"active": @(active), @"exitToken": exitToken} options:0 error:nil]
    writeToFile:[directory stringByAppendingPathComponent:@"host-window.json"] atomically:YES];
}
static void Capture(NSDictionary* state) {
  NSString* token = state[@"token"];
  NSString* file = [directory stringByAppendingPathComponent:[token stringByAppendingString:@".png"]];
  NSString* own = YCWindowPixels(window, file);
  NSBitmapImageRep* image = [[NSBitmapImageRep alloc] initWithData:[NSData dataWithContentsOfFile:file]];
  NSUInteger green = 0, red = 0, magenta = 0, total = 0;
  for (NSInteger y = 20; image && y < image.pixelsHigh - 20; y += 10) {
    for (NSInteger x = 20; x < image.pixelsWide - 20; x += 10) {
      NSColor* c = [[image colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
      if (c.greenComponent > 0.3 && c.greenComponent > c.redComponent * 1.5 && c.greenComponent > c.blueComponent * 1.3) ++green;
      if (c.redComponent > 0.5 && c.redComponent > c.greenComponent * 1.5) ++red;
      if (c.redComponent > 0.8 && c.blueComponent > 0.8 && c.greenComponent < 0.15) ++magenta;
      ++total;
    }
  }
  NSDictionary* result = @{@"contextId": state[@"contextId"], @"own": own, @"width": @(image.pixelsWide), @"height": @(image.pixelsHigh),
    @"key": @(window.isKeyWindow), @"active": @(NSApp.isActive), @"green": @(green), @"red": @(red), @"magenta": @(magenta), @"total": @(total)};
  [[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil]
    writeToFile:[directory stringByAppendingPathComponent:[token stringByAppendingString:@".json"]] atomically:YES];
}
int main(int argc, char** argv) { @autoreleasepool {
  if (argc != 2) return 2;
  directory = @(argv[1]);
  exitToken = NSUUID.UUID.UUIDString;
  NSApplication* app = NSApplication.sharedApplication;
  [app setActivationPolicy:NSApplicationActivationPolicyRegular];
  window = [[YCExternalActionWindow alloc] initWithContentRect:NSMakeRect(100, 100, 800, 600) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
  window.title = @(getenv("YAB_TASK_NAME") ?: "External action acceptance"); window.releasedWhenClosed = NO;
  NSView* view = window.contentView; view.wantsLayer = YES;
  view.layer.backgroundColor = CGColorCreateSRGB(1, 0, 1, 1);
  parent = [CALayer layer]; parent.geometryFlipped = YES; parent.frame = view.bounds;
  parent.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable; [view.layer addSublayer:parent];
  [app finishLaunching];
  [app activateIgnoringOtherApps:YES];
  [window makeKeyAndOrderFront:nil];
  ForegroundReceipt();
  NSTimer* timer = [NSTimer timerWithTimeInterval:0.05 repeats:YES block:^(NSTimer*) {
    // App activation completes asynchronously. Publish current state after
    // the event loop runs, not a permanently false launch-time receipt.
    ForegroundReceipt();
    NSData* exitData = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"host-exit.json"]];
    NSDictionary* exitRequest = exitData ? [NSJSONSerialization JSONObjectWithData:exitData options:0 error:nil] : nil;
    if ([exitRequest[@"pid"] isEqual:@(getpid())] && [exitRequest[@"exitToken"] isEqual:exitToken]) {
      [[NSJSONSerialization dataWithJSONObject:@{@"pid": @(getpid()), @"exitToken": exitToken,
        @"naturalAppKitTerminate": @YES} options:0 error:nil]
        writeToFile:[directory stringByAppendingPathComponent:@"host-exit-result.json"] atomically:YES];
      [host removeFromSuperlayer]; host = nil;
      [window close];
      [NSApp terminate:nil];
      return;
    }
    NSData* data = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"host-state.json"]];
    NSDictionary* state = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (!state || [state[@"token"] isEqual:lastToken]) return;
    lastToken = state[@"token"];
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    [window setContentSize:NSMakeSize([state[@"width"] doubleValue], [state[@"height"] doubleValue])];
    CALayerHost* layer = [CALayerHost new]; layer.contextId = [state[@"contextId"] unsignedIntValue];
    layer.anchorPoint = CGPointZero; layer.position = CGPointMake(-[state[@"pageX"] doubleValue], -[state[@"pageY"] doubleValue]); // native page crop, zero bounds
    [parent addSublayer:layer]; [host removeFromSuperlayer]; host = layer;
    [CATransaction commit]; [CATransaction flush];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 700 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ Capture(state); });
  }];
  [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
  [app run];
}}
