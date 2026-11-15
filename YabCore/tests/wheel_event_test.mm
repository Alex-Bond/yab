// A page's wheel, as YabCore hands it to RenderWidgetHostViewCocoa, against
// the original event the client had: what Chrome's WebMouseWheelEventBuilder
// reads off each must match (R2566). Device-shaped events: notches slow and
// fast, a free-spinning wheel, trackpad and Magic Mouse phases and momentum,
// a smooth-scrolling mouse, Shift. "before" is main's path (the client's few
// fields, rebuilt), printed for the record; "after" must match.
//   clang++ -std=c++20 -fobjc-arc -framework AppKit YabCore/tests/wheel_event_test.mm -o wheel-event
#import <AppKit/AppKit.h>
#include TEST_WHEEL_EVENT_HEADER
#include <cmath>
#include <cstdio>
#include <vector>

namespace {
struct Reads {  // web_input_event_builders_mac.mm, WebMouseWheelEventBuilder::Build
  bool continuous; double dx, dy; long long ticksX, ticksY;
  unsigned long phase, momentum, flags; double time; NSPoint at;
  bool operator==(const Reads& o) const {
    return continuous == o.continuous && dx == o.dx && dy == o.dy && ticksX == o.ticksX && ticksY == o.ticksY &&
           phase == o.phase && momentum == o.momentum && flags == o.flags && time == o.time;
  }
};
Reads Read(NSEvent* event) {
  CGEventRef cg = event.CGEvent;
  Reads r{};
  r.continuous = CGEventGetIntegerValueField(cg, kCGScrollWheelEventIsContinuous) != 0;
  r.dx = r.continuous ? CGEventGetIntegerValueField(cg, kCGScrollWheelEventPointDeltaAxis2) : event.deltaX * 40;
  r.dy = r.continuous ? CGEventGetIntegerValueField(cg, kCGScrollWheelEventPointDeltaAxis1) : event.deltaY * 40;
  r.ticksX = r.continuous ? (long long)(r.dx / 40) : CGEventGetIntegerValueField(cg, kCGScrollWheelEventDeltaAxis2);
  r.ticksY = r.continuous ? (long long)(r.dy / 40) : CGEventGetIntegerValueField(cg, kCGScrollWheelEventDeltaAxis1);
  r.phase = event.phase; r.momentum = event.momentumPhase;
  r.flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
  r.time = event.timestamp; r.at = event.locationInWindow;
  return r;
}
struct Case { const char* name; bool continuous; int ticks; double fixed; long long points; int phase, momentum; CGEventFlags flags; bool horizontal; double precise = 0; };

// The client's fields on main (ChromiumWheelInput before R2566).
NSDictionary* MainFields(NSEvent* e, NSPoint p, bool animateNotches) {
  auto gesture = [](NSEventPhase ph) {
    int v = 0;
    if (ph & NSEventPhaseBegan) v |= 1;
    if (ph & NSEventPhaseChanged) v |= 2;
    if (ph & NSEventPhaseEnded) v |= 4;
    if (ph & NSEventPhaseCancelled) v |= 8;
    if (ph & NSEventPhaseMayBegin) v |= 128;
    return v;
  };
  auto momentum = [](NSEventPhase ph) {
    if (ph & (NSEventPhaseEnded | NSEventPhaseCancelled)) return 3;
    if (ph & NSEventPhaseChanged) return 2;
    if (ph & NSEventPhaseBegan) return 1;
    return 0;
  };
  NSMutableDictionary* f = [@{@"x": @(p.x), @"y": @(p.y), @"deltaX": @(e.scrollingDeltaX), @"deltaY": @(e.scrollingDeltaY),
    @"timestamp": @(e.timestamp), @"phase": @(gesture(e.phase)), @"momentumPhase": @(momentum(e.momentumPhase)),
    @"modifiers": @(e.modifierFlags)} mutableCopy];
  if (!e.hasPreciseScrollingDeltas) {
    bool glides = e.phase == 0 && e.momentumPhase == 0 && !(e.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) &&
                  (e.scrollingDeltaX != 0 || e.scrollingDeltaY != 0);
    if (!animateNotches && glides) {
      f[@"deltaX"] = @(e.scrollingDeltaX * 40); f[@"deltaY"] = @(e.scrollingDeltaY * 40);
    } else {
      f[@"notch"] = @YES;
      f[@"ticksX"] = @(CGEventGetIntegerValueField(e.CGEvent, kCGScrollWheelEventDeltaAxis2));
      f[@"ticksY"] = @(CGEventGetIntegerValueField(e.CGEvent, kCGScrollWheelEventDeltaAxis1));
    }
  }
  return f;
}
// The client's fields now (ChromiumWheelInput).
NSDictionary* Fields(NSEvent* e, NSPoint p) {
  NSData* data = (__bridge_transfer NSData*)CGEventCreateData(kCFAllocatorDefault, e.CGEvent);
  return @{@"x": @(p.x), @"y": @(p.y), @"timestamp": @(e.timestamp), @"modifiers": @(e.modifierFlags),
           @"event": [data base64EncodedStringWithOptions:0]};
}
void Print(const char* label, const Reads& r) {
  printf("  %-14s continuous %d  dx %9.4f  dy %9.4f  ticks %lld,%lld  phase %lu  momentum %lu  flags %lx  t %.9f  at %.1f,%.1f\n",
         label, r.continuous, r.dx, r.dy, r.ticksX, r.ticksY, r.phase, r.momentum, r.flags, r.time, r.at.x, r.at.y);
}
}  // namespace

int main() {
  @autoreleasepool {
    [NSApplication sharedApplication];
    // The client's window, and YabCore's hidden page window somewhere else.
    NSWindow* client = [[NSWindow alloc] initWithContentRect:NSMakeRect(40, 60, 500, 400) styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered defer:NO];
    NSWindow* page = [[NSWindow alloc] initWithContentRect:NSMakeRect(700, 300, 800, 600) styleMask:NSWindowStyleMaskBorderless
                                                   backing:NSBackingStoreBuffered defer:NO];
    const double now = NSProcessInfo.processInfo.systemUptime;
    const std::vector<Case> cases = {
      {"slow notch", false, -1, -0.1, -1, 0, 0, 0, false},
      {"fast notch", false, -1, -2.3, -9, 0, 0, 0, false},
      {"free spin", false, -1, -6.4, -26, 0, 0, 0, false},
      {"notch up", false, 1, 0.3, 1, 0, 0, 0, false},
      {"shift notch", false, -1, -0.4, -2, 0, 0, kCGEventFlagMaskShift, true},
      {"control notch", false, -1, -0.1, -1, 0, 0, kCGEventFlagMaskControl, false},
      {"trackpad began", true, 0, -1.25, -1, 1, 0, 0, false},
      {"trackpad drag", true, 0, -6.6, -7, 2, 0, 0, false},
      {"trackpad slow", true, 0, -0.62, -1, 2, 0, 0, false},
      {"trackpad ended", true, 0, 0, 0, 4, 0, 0, false},
      {"momentum fast", true, 0, -23.7, -24, 0, 2, 0, false},
      {"momentum tail", true, 0, -0.6, -1, 0, 2, 0, false},
      {"momentum end", true, 0, 0, 0, 0, 3, 0, false},
      {"magic mouse", true, 0, -1.75, -2, 2, 0, 0, false},
      {"smooth mouse", true, 0, -3.5, -4, 0, 0, 0, false},
      // A device's points with their fraction kept (the double value of the
      // point delta field), as a trackpad's driver may report them.
      {"trackpad 2.75", true, 0, -2.75, -3, 2, 0, 0, false, -2.75},
      {"trackpad 0.6", true, 0, -0.6, -1, 2, 0, 0, false, -0.6},
      {"momentum 0.4", true, 0, -0.4, 0, 0, 2, 0, false, -0.4},
      {"smooth 1.5", true, 0, -1.5, -2, 0, 0, 0, false, -1.5},
    };
    int failed = 0, checks = 0, differedBefore = 0;
    for (const Case& c : cases) {
      CGEventRef cg = CGEventCreateScrollWheelEvent(nullptr, c.continuous ? kCGScrollEventUnitPixel : kCGScrollEventUnitLine, 2,
                                                    c.horizontal ? 0 : c.ticks, c.horizontal ? c.ticks : 0);
      CGEventSetIntegerValueField(cg, kCGScrollWheelEventIsContinuous, c.continuous);
      CGEventField fixed = c.horizontal ? kCGScrollWheelEventFixedPtDeltaAxis2 : kCGScrollWheelEventFixedPtDeltaAxis1;
      CGEventField point = c.horizontal ? kCGScrollWheelEventPointDeltaAxis2 : kCGScrollWheelEventPointDeltaAxis1;
      CGEventSetDoubleValueField(cg, fixed, c.fixed);
      CGEventSetIntegerValueField(cg, point, c.points);
      if (c.precise) CGEventSetDoubleValueField(cg, point, c.precise);
      CGEventSetIntegerValueField(cg, kCGScrollWheelEventScrollPhase, c.phase);
      CGEventSetIntegerValueField(cg, kCGScrollWheelEventMomentumPhase, c.momentum);
      CGEventSetFlags(cg, c.flags);
      CGEventSetTimestamp(cg, (CGEventTimestamp)((now - 0.004) * 1e9));
      // Where the client got it: its own window.
      NSPoint clientPoint = NSMakePoint(120.5, 80.25);
      NSEvent* clientEvent = WheelEventPlace(cg, client, clientPoint);
      Reads original = Read(clientEvent);
      NSPoint target = NSMakePoint(321.5, 210.25);
      printf("%s: NSEvent deltaY %.6f scrollingDeltaY %.6f precise %d; point field %lld / %.6f\n", c.name, clientEvent.deltaY,
             clientEvent.scrollingDeltaY, clientEvent.hasPreciseScrollingDeltas, CGEventGetIntegerValueField(cg, point),
             CGEventGetDoubleValueField(cg, point));
      Print("original", original);
      for (bool animate : {true, false}) {
        CGEventRef made = WheelEventCreate(MainFields(clientEvent, target, animate), now);
        Reads before = Read(WheelEventPlace(made, page, target));
        Print(animate ? "before" : "before, RM", before);
        if (!(before == original)) ++differedBefore;
        CFRelease(made);
      }
      CGEventRef made = WheelEventCreate(Fields(clientEvent, target), now);
      NSEvent* delivered = WheelEventPlace(made, page, target);
      Reads after = Read(delivered);
      Print("after", after);
      ++checks;
      if (!(after == original)) { ++failed; printf("FAIL %s: Chrome reads differ\n", c.name); }
      ++checks;
      // The page window is never on screen here, nor in YabCore, so AppKit
      // may leave the event windowless; then its point is the window's.
      if ((delivered.window && delivered.window != page) || fabs(after.at.x - target.x) > .01 || fabs(after.at.y - target.y) > .01) {
        ++failed; printf("FAIL %s: placed at %.2f,%.2f in window %ld, wanted %.2f,%.2f in %ld\n", c.name, after.at.x, after.at.y,
                         (long)delivered.window.windowNumber, target.x, target.y, (long)page.windowNumber);
      }
      // Every other field of the original stays, whatever AppKit or the
      // driver put there (location and the window under the pointer aside).
      int kept = 0, lost = 0;
      for (int field = 0; field < 256; ++field) {
        if (field == kCGMouseEventWindowUnderMousePointer || field == kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent) continue;
        int64_t a = CGEventGetIntegerValueField(cg, (CGEventField)field), b = CGEventGetIntegerValueField(made, (CGEventField)field);
        double x = CGEventGetDoubleValueField(cg, (CGEventField)field), y = CGEventGetDoubleValueField(made, (CGEventField)field);
        if (a == b && (x == y || (std::isnan(x) && std::isnan(y)))) ++kept;
        else { ++lost; printf("  field %d: %lld/%g became %lld/%g\n", field, a, x, b, y); }
      }
      ++checks;
      if (lost) { ++failed; printf("FAIL %s: %d fields changed\n", c.name, lost); }
      printf("  fields kept %d\n", kept);
      CFRelease(made); CFRelease(cg);
    }
    // A wheel without bytes (YabCoreProbe) still scrolls by its fields.
    CGEventRef probe = WheelEventCreate(@{@"x": @300, @"y": @250, @"deltaY": @-120, @"deltaX": @0}, now);
    ++checks;
    if (!probe || CGEventGetIntegerValueField(probe, kCGScrollWheelEventPointDeltaAxis1) != -120 ||
        CGEventGetTimestamp(probe) != (CGEventTimestamp)llround(now * 1e9)) { ++failed; printf("FAIL fields-only wheel\n"); }
    if (probe) CFRelease(probe);
    ++checks;
    if (WheelEventCreate(@{@"event": @"bm90IGFuIGV2ZW50"}, now) != nullptr) { ++failed; printf("FAIL garbage bytes made an event\n"); }
    printf("%d wheel-event checks, %d failed; main's path differed from the original in %d of %zu reads\n",
           checks, failed, differedBefore, cases.size() * 2);
    return failed ? 1 : 0;
  }
}
