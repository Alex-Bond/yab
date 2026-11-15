// The production transport (src/transport.mm) without CEF, over a real Unix
// socket, for the client's FlowControlTests. Each request makes the helper do
// what a busy Chromium does to the wire; "pause" stops the helper's loop as a
// busy main thread does. Built by YabCore/tests/transport_flow.sh, also from
// an older tree's transport (BASELINE: no flow control, no Metrics).
#define YABCORE_TRANSPORT_FAKE 1
#ifdef BASELINE
#include "baseline-transport.mm"
#else
#include "../src/transport.mm"
#endif
#include <set>
#include <sys/resource.h>
static NSString* Padding(NSUInteger bytes) { return [@"" stringByPaddingToLength:bytes withString:@"x" startingAtIndex:0]; }
int main(int argc, char** argv) { @autoreleasepool {
  if (argc != 2) return 2;
  yc::Transport wire;
  if (!wire.Start(@(argv[1]))) return 3;
  bool running = true;
  double pauseUntil = 0;
  int definitions = 0, installs = 0;
  NSMutableDictionary* bundles = [NSMutableDictionary new];
  NSMutableArray* shed = [NSMutableArray new];
  wire.onDisconnect = [&] {
    // The real owner ends the helper here, and with it every Chromium page.
    struct rusage usage = {}; getrusage(RUSAGE_SELF, &usage);
    fprintf(stderr, "transport fake: client lost, every page ends; peak_rss=%ld\n", usage.ru_maxrss);
    running = false;
  };
  auto event = [&](NSString* name, NSDictionary* params) { wire.Send(@{@"v": @1, @"event": name, @"params": params}); };
#ifndef BASELINE
  wire.onShed = [&](const std::string& tab, size_t bytes) {
    // As core.mm's ShedPage: that page ends and says so, nothing else does.
    [shed addObject:@(tab.c_str())];
    yc::Transport* owner = &wire;  // a block would copy the object itself
    NSString* name = @(tab.c_str());
    dispatch_async(dispatch_get_main_queue(), ^{
      owner->Send(@{@"v": @1, @"event": @"page.eventsShed", @"params": @{@"tab": name, @"bytes": @(bytes)}});
    });
  };
#endif
  auto metrics = [&]() -> NSMutableDictionary* {
#ifdef BASELINE
    NSMutableDictionary* m = [NSMutableDictionary new];
#else
    NSMutableDictionary* m = [wire.Metrics() mutableCopy];
#endif
    struct rusage usage = {}; getrusage(RUSAGE_SELF, &usage);
    m[@"definitions"] = @(definitions); m[@"installs"] = @(installs); m[@"bundles"] = @(bundles.count);
    m[@"shedTabs"] = shed; m[@"peakRSS"] = @(usage.ru_maxrss);
    return m;
  };
  wire.onRequest = [&](NSDictionary* request) {
    NSString* method = request[@"method"], *identity = request[@"id"];
    NSDictionary* p = [request[@"params"] isKindOfClass:NSDictionary.class] ? request[@"params"] : @{};
    id result = @{};
    NSString* error = nil;
    if ([method isEqual:@"hello"]) {
#ifdef BASELINE
      result = @{@"version": @1};
#else
      result = @{@"version": @1, @"eventFlow": @(wire.Flowing() ? 1 : 0), @"scriptBundles": @1};
#endif
    } else if ([method isEqual:@"burst"]) {
      // Ordered events of one tab, numbered: none of them may be lost.
      int count = [p[@"count"] intValue];
      NSString* tab = p[@"tab"] ?: @"a", *name = p[@"event"] ?: @"page.committed";
      NSString* pad = Padding([p[@"pad"] unsignedIntegerValue]);
      for (int i = 0; i < count; ++i) { @autoreleasepool {
        event(name, @{@"tab": tab, @"sequence": @(i), @"pad": pad});
      } }
      result = metrics();
    } else if ([method isEqual:@"states"]) {
      // A page loading: thousands of progress patches, a title, then a
      // commit, more progress, and the tab's end.
      int count = [p[@"count"] intValue];
      for (int i = 0; i < count; ++i) { @autoreleasepool { event(@"page.state", @{@"tab": @"a", @"progress": @(i)}); } }
      event(@"page.state", @{@"tab": @"a", @"title": @"before"});
      event(@"layer.changed", @{@"tab": @"a", @"contextId": @1});
      event(@"page.committed", @{@"tab": @"a", @"url": @"https://example.com/next"});
      for (int i = 0; i < count; ++i) { @autoreleasepool { event(@"page.state", @{@"tab": @"a", @"progress": @(count + i)}); } }
      event(@"page.state", @{@"tab": @"a", @"title": @"after"});
      event(@"layer.changed", @{@"tab": @"a", @"contextId": @2});
      event(@"dialog.open", @{@"tab": @"b", @"dialog": @"1"});
      event(@"tab.closed", @{@"tab": @"a"});
      result = metrics();
    } else if ([method isEqual:@"flood"]) {
      // One page producing notifications far past the budget while nobody
      // consumes, an ask of its own among them, and a calm page beside it.
      int count = [p[@"count"] intValue];
      NSString* pad = Padding([p[@"pad"] unsignedIntegerValue]);
      event(@"page.committed", @{@"tab": @"calm", @"sequence": @0});
      for (int i = 0; i < count; ++i) { @autoreleasepool {
        event(@"page.started", @{@"tab": @"flood", @"sequence": @(i), @"pad": pad});
        if (i == count / 2) {
          event(@"dialog.open", @{@"tab": @"flood", @"dialog": @"asks"});
          event(@"page.committed", @{@"tab": @"calm", @"sequence": @1});
        }
      } }
      event(@"page.committed", @{@"tab": @"calm", @"sequence": @2});
      result = metrics();
    } else if ([method isEqual:@"pause"]) {
      // A busy main thread: nothing is read or written for this long.
      pauseUntil = CFAbsoluteTimeGetCurrent() + [p[@"seconds"] doubleValue];
    } else if ([method isEqual:@"large"]) {
      result = @{@"blob": Padding([p[@"bytes"] unsignedIntegerValue] ?: 1024 * 1024)};
    } else if ([method isEqual:@"scripts.define"]) {
      ++definitions; bundles[p[@"bundle"]] = p[@"scripts"];
    } else if ([method isEqual:@"scripts.forget"]) {
      [bundles removeObjectForKey:p[@"bundle"]];
    } else if ([method isEqual:@"scripts.install"]) {
      if (p[@"scripts"] || !bundles[p[@"bundle"]]) error = @"install without its bundle";
      else ++installs;
    } else if ([method isEqual:@"metrics"]) {
      result = metrics();
    } else if ([method isEqual:@"echo"]) {
      result = p;
    }
    NSMutableDictionary* reply = [@{@"v": @1, @"id": identity} mutableCopy];
    if (error) reply[@"error"] = @{@"code": @"operation_failed", @"message": error};
    else reply[@"result"] = result;
    wire.Send(reply);
  };
  while (running) { @autoreleasepool {
    double now = CFAbsoluteTimeGetCurrent();
    if (now < pauseUntil) { usleep((useconds_t)MIN(100000, (pauseUntil - now) * 1e6)); continue; }
    wire.Poll(); CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.001, true);
  } }
  wire.Close(); return 0;
} }
