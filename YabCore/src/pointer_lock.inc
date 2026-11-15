// A page's pointer lock, as Chromium has it (R2472, feedback #1921).
//
// Chrome reads a locked pointer's moves in RenderWidgetHostViewCocoa: the
// NSEvent's deltaX/deltaY (or, for unadjustedMovement, the CGEvent's
// unaccelerated fields) become movement_x/y, and the screen position grows by
// them while the widget position stays put, so Blink's movementX/Y (taken from
// screen positions) carry the hand's motion. The page's own process hides and
// freezes the pointer (CGAssociateMouseAndMouseCursorPosition, NSCursor hide).
//
// Here the page's view lives in a hidden window of a background process, and
// its moves came through CDP as positions alone: under a frozen pointer every
// position is the same, so movementX/Y were 0, and the freeze and hide asked
// in this process changed nothing on screen (only the front app's count).
//
// So the client (the front app) freezes and hides the pointer when told
// (page.pointerLock), and while a page holds the lock its mouse events cross
// as their own CGEvents, whole, and go to the view as AppKit would hand them:
// Chrome's own code reads the deltas and keeps the positions. CDP still
// carries every pointer event of an unlocked page.
static IMP pointerLockSetOriginal = nullptr, pointerLockIgnoreOriginal = nullptr;
static bool pointerLockDelivering = false;

static Tab* PointerLockTab(NSView* view) {
  NSWindow* window = view.window;
  if (!window) return nullptr;
  for (auto& [id, t] : tabs) if (t.native == window && !t.closing) return &t;
  return nullptr;
}

// The view's own route for a mouse event: BaseView passes each of these to
// -mouseEvent:. -shouldIgnoreMouseEvent: says no to a move in a window that
// isn't key, and this producer window never is; for an event Yab hands it
// while the page holds the pointer it answers as Chromium's key window would.
static void PointerLockDeliver(NSView* view, NSEvent* event) {
  SEL action = nullptr;
  switch (event.type) {
    case NSEventTypeMouseMoved: action = @selector(mouseMoved:); break;
    case NSEventTypeLeftMouseDragged: action = @selector(mouseDragged:); break;
    case NSEventTypeRightMouseDragged: action = @selector(rightMouseDragged:); break;
    case NSEventTypeOtherMouseDragged: action = @selector(otherMouseDragged:); break;
    case NSEventTypeLeftMouseDown: action = @selector(mouseDown:); break;
    case NSEventTypeLeftMouseUp: action = @selector(mouseUp:); break;
    case NSEventTypeRightMouseDown: action = @selector(rightMouseDown:); break;
    case NSEventTypeRightMouseUp: action = @selector(rightMouseUp:); break;
    case NSEventTypeOtherMouseDown: action = @selector(otherMouseDown:); break;
    case NSEventTypeOtherMouseUp: action = @selector(otherMouseUp:); break;
    default: return;
  }
  if (![view respondsToSelector:action]) return;
  pointerLockDelivering = true;
  ((void (*)(id, SEL, NSEvent*))objc_msgSend)(view, action, event);
  pointerLockDelivering = false;
}

static BOOL PointerLockShouldIgnore(id self, SEL command, NSEvent* event) {
  if (pointerLockDelivering) return NO;
  return ((BOOL (*)(id, SEL, NSEvent*))pointerLockIgnoreOriginal)(self, command, event);
}

static void PointerLockSet(NSView* self, SEL command, BOOL locked) {
  Tab* t = PointerLockTab(self);
  if (locked && t && !t->pointerLocked && t->pointerPointKnown) {
    // Chrome's view has seen every move before the lock and counts locked
    // positions on from the last; this one saw none (they went through
    // CDP). One move where the pointer is now, before the lock, gives it
    // that place, so the first locked move is the hand's alone.
    NSEvent* here = [NSEvent mouseEventWithType:NSEventTypeMouseMoved location:t->pointerPoint
      modifierFlags:0 timestamp:Now() windowNumber:self.window.windowNumber context:nil
      eventNumber:0 clickCount:0 pressure:0];
    PointerLockDeliver(self, here);
  }
  ((void (*)(id, SEL, BOOL))pointerLockSetOriginal)(self, command, locked);
  if (!t || t->pointerLocked == (bool)locked) return;
  t->pointerLocked = locked;
  Event(@"page.pointerLock", t, @{@"locked": @((bool)locked)});
}

static void InstallPointerLockHooks() {
  static bool tried = false;
  if (tried) return;
  Class view = NSClassFromString(@"RenderWidgetHostViewCocoa");
  if (!view) return;
  tried = true;
  Method set = class_getInstanceMethod(view, NSSelectorFromString(@"setCursorLocked:"));
  Method ignore = class_getInstanceMethod(view, NSSelectorFromString(@"shouldIgnoreMouseEvent:"));
  // Both or neither: without the first nobody hears of a lock and the CDP
  // route stays, as before.
  if (!set || !ignore || method_getNumberOfArguments(set) != 3 || method_getNumberOfArguments(ignore) != 3) {
    fprintf(stderr, "YabCore pointer lock: RenderWidgetHostViewCocoa hooks unavailable\n");
    return;
  }
  pointerLockIgnoreOriginal = method_setImplementation(ignore, (IMP)PointerLockShouldIgnore);
  pointerLockSetOriginal = method_setImplementation(set, (IMP)PointerLockSet);
}

static bool PointerLockKind(NSString* kind, NSEventType* type, CGEventType* cgType, CGMouseButton* button) {
  static NSDictionary* const kinds = @{
    @"mouseMove": @[@(NSEventTypeMouseMoved), @(kCGEventMouseMoved), @(kCGMouseButtonLeft)],
    @"mouseDrag": @[@(NSEventTypeLeftMouseDragged), @(kCGEventLeftMouseDragged), @(kCGMouseButtonLeft)],
    @"mouseDown": @[@(NSEventTypeLeftMouseDown), @(kCGEventLeftMouseDown), @(kCGMouseButtonLeft)],
    @"mouseUp": @[@(NSEventTypeLeftMouseUp), @(kCGEventLeftMouseUp), @(kCGMouseButtonLeft)],
    @"rightDrag": @[@(NSEventTypeRightMouseDragged), @(kCGEventRightMouseDragged), @(kCGMouseButtonRight)],
    @"rightDown": @[@(NSEventTypeRightMouseDown), @(kCGEventRightMouseDown), @(kCGMouseButtonRight)],
    @"rightUp": @[@(NSEventTypeRightMouseUp), @(kCGEventRightMouseUp), @(kCGMouseButtonRight)],
    @"middleDrag": @[@(NSEventTypeOtherMouseDragged), @(kCGEventOtherMouseDragged), @(kCGMouseButtonCenter)],
    @"middleDown": @[@(NSEventTypeOtherMouseDown), @(kCGEventOtherMouseDown), @(kCGMouseButtonCenter)],
    @"middleUp": @[@(NSEventTypeOtherMouseUp), @(kCGEventOtherMouseUp), @(kCGMouseButtonCenter)]};
  NSArray* row = kinds[kind];
  if (!row) return false;
  *type = (NSEventType)[row[0] unsignedIntegerValue];
  *cgType = (CGEventType)[row[1] unsignedIntValue];
  *button = (CGMouseButton)[row[2] unsignedIntValue];
  return true;
}

static bool IsPointerLockKind(NSString* kind) {
  NSEventType type; CGEventType cgType; CGMouseButton button;
  return PointerLockKind(kind, &type, &cgType, &button);
}

// A locked page's mouse event at `point` (window base coordinates) of its
// hidden window: the client's own CGEvent when it sent one (`event`, from
// CGEventCreateData), so its deltas and unaccelerated movement are the
// hand's; else one made from the fields, which moves nothing. Nil when the
// bytes are not an event of this kind.
static NSEvent* PointerLockEvent(NSDictionary* p, NSString* kind, NSWindow* window, NSPoint point, NSEventModifierFlags flags) {
  NSEventType type; CGEventType cgType; CGMouseButton button;
  if (!PointerLockKind(kind, &type, &cgType, &button)) return nil;
  CGEventRef cg = nullptr;
  id bytes = p[@"event"];
  if (bytes) {
    if (![bytes isKindOfClass:NSString.class] || [bytes length] > 16384) return nil;
    NSData* data = [[NSData alloc] initWithBase64EncodedString:bytes options:0];
    cg = data.length ? CGEventCreateFromData(kCFAllocatorDefault, (__bridge CFDataRef)data) : nullptr;
    if (cg && CGEventGetType(cg) != cgType) { CFRelease(cg); cg = nullptr; }
    if (!cg) return nil;
    const double now = Now() * 1e9;
    if (CGEventGetTimestamp(cg) == 0 || CGEventGetTimestamp(cg) > now) CGEventSetTimestamp(cg, static_cast<CGEventTimestamp>(now));
  } else {
    cg = CGEventCreateMouseEvent(nullptr, cgType, CGPointZero, button);
    if (!cg) return nil;
    CGEventSetFlags(cg, static_cast<CGEventFlags>(flags));
    if (p[@"clickCount"] && cgType != kCGEventMouseMoved)
      CGEventSetIntegerValueField(cg, kCGMouseEventClickState, std::max(1, [p[@"clickCount"] intValue]));
    CGEventSetTimestamp(cg, static_cast<CGEventTimestamp>(Now() * 1e9));
  }
  const CGFloat top = NSScreen.screens.firstObject.frame.size.height;
  NSPoint screen = [window convertPointToScreen:point];
  CGEventSetLocation(cg, CGPointMake(screen.x, top - screen.y));
  CGEventSetIntegerValueField(cg, kCGMouseEventWindowUnderMousePointer, window.windowNumber);
  CGEventSetIntegerValueField(cg, kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent, window.windowNumber);
  NSEvent* event = [NSEvent eventWithCGEvent:cg];
  if (!event.window) {
    // A windowless NSEvent reports a screen point as locationInWindow; the
    // view is called directly, so give it its window-base point instead.
    CGEventSetLocation(cg, CGPointMake(point.x, top - point.y));
    event = [NSEvent eventWithCGEvent:cg];
  }
  CFRelease(cg);
  return event.type == type ? event : nil;
}
