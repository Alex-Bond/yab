#ifndef YABCORE_WHEEL_EVENT_H_
#define YABCORE_WHEEL_EVENT_H_
#import <AppKit/AppKit.h>
#include <cmath>

// A wheel for a Chromium page's view, as Chromium has it from AppKit (R2566).
// The client sends the scroll's own CGEvent, whole (CGEventCreateData), so
// WebMouseWheelEventBuilder reads what it reads in Chrome: the continuous bit,
// a precise device's point deltas, a notch's accelerated lines and its ticks,
// phases, momentum, flags and the clock, as the Mac's driver made them. Only
// where it is changes (the caller places it in this process's window), and
// Chrome's own wheel code and cc decide how far and how smoothly it scrolls.
//
// Rebuilt from a few numbers instead, as before, every field the client did
// not name was lost, and a notch it had turned into pixels (Reduce Motion,
// smooth scrolling off) lost its tick and its fraction of a point.
//
// Without the bytes (YabCoreProbe, a caller with no CGEvent) a wheel is still
// made from the fields: ticks and lines for a notch, else whole points.
static CGEventRef WheelEventCreate(NSDictionary* p, double now) {
  CGEventRef cg = nullptr;
  id bytes = p[@"event"];
  if (bytes) {
    if (![bytes isKindOfClass:NSString.class]) return nullptr;
    NSData* data = [[NSData alloc] initWithBase64EncodedString:bytes options:0];
    cg = data.length ? CGEventCreateFromData(kCFAllocatorDefault, (__bridge CFDataRef)data) : nullptr;
    if (cg && CGEventGetType(cg) != kCGEventScrollWheel) { CFRelease(cg); cg = nullptr; }
    if (!cg) return nullptr;
  } else {
    bool notch = [p[@"notch"] boolValue];
    cg = notch ? CGEventCreateScrollWheelEvent(nullptr, kCGScrollEventUnitLine, 2, [p[@"ticksY"] intValue], [p[@"ticksX"] intValue])
               : CGEventCreateScrollWheelEvent(nullptr, kCGScrollEventUnitPixel, 2, (int32_t)[p[@"deltaY"] doubleValue], (int32_t)[p[@"deltaX"] doubleValue]);
    if (!cg) return nullptr;
    if (notch) {
      CGEventSetDoubleValueField(cg, kCGScrollWheelEventFixedPtDeltaAxis1, [p[@"deltaY"] doubleValue]);
      CGEventSetDoubleValueField(cg, kCGScrollWheelEventFixedPtDeltaAxis2, [p[@"deltaX"] doubleValue]);
    }
    CGEventSetIntegerValueField(cg, kCGScrollWheelEventScrollPhase, [p[@"phase"] longLongValue]);
    CGEventSetIntegerValueField(cg, kCGScrollWheelEventMomentumPhase, [p[@"momentumPhase"] longLongValue]);
    CGEventSetFlags(cg, static_cast<CGEventFlags>([p[@"modifiers"] unsignedLongLongValue]));
    CGEventSetTimestamp(cg, 0);
  }
  // Chromium times wheel animation and latency by this clock (system uptime
  // in both processes). A made event has none, and zero makes a fresh notch
  // ancient; a stamp from the future is not believed either.
  const double latest = now * 1e9;
  CGEventTimestamp stamp = CGEventGetTimestamp(cg);
  if (stamp == 0 || stamp > latest) {
    double timestamp = [p[@"timestamp"] doubleValue];
    if (!std::isfinite(timestamp) || timestamp <= 0 || timestamp > now) timestamp = now;
    stamp = static_cast<CGEventTimestamp>(llround(timestamp * 1e9));
  }
  CGEventSetTimestamp(cg, stamp);
  return cg;
}

// `cg` at `point` (window base coordinates) of `window`, this process's
// hidden page window, as AppKit would have delivered it there.
static NSEvent* WheelEventPlace(CGEventRef cg, NSWindow* window, NSPoint point) {
  const CGFloat top = NSScreen.screens.firstObject.frame.size.height;
  NSPoint screen = [window convertPointToScreen:point];
  CGEventSetLocation(cg, CGPointMake(screen.x, top - screen.y));
  CGEventSetIntegerValueField(cg, kCGMouseEventWindowUnderMousePointer, window.windowNumber);
  CGEventSetIntegerValueField(cg, kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent, window.windowNumber);
  NSEvent* event = [NSEvent eventWithCGEvent:cg];
  if (!event.window) {
    // A windowless NSEvent reports a screen point as locationInWindow.
    // The view is invoked directly, so supply its window-base point instead.
    CGEventSetLocation(cg, CGPointMake(point.x, top - point.y));
    event = [NSEvent eventWithCGEvent:cg];
  }
  return event;
}
#endif
