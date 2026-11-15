#pragma once
#import <AppKit/AppKit.h>

// In-process Chrome toolbar diagnostics for the opt-in normal-window path.
// No external Accessibility client or system permission is involved. Name
// matching is experimental; it is not yet the production action-ID mapping.
static NSString* ExtensionAXText(id value) {
  return [value isKindOfClass:NSString.class] ? value : @"";
}
static void ExtensionAXWalk(id element, NSMutableArray* rows, NSMutableArray* matches,
                            NSString* name, NSMutableSet* seen, int depth = 0) {
  if (!element || depth > 30 || seen.count >= 5000) return;
  NSValue* identity = [NSValue valueWithPointer:(__bridge const void*)element];
  if ([seen containsObject:identity]) return;
  [seen addObject:identity];
  NSString* role = [element respondsToSelector:@selector(accessibilityRole)] ? ExtensionAXText([element accessibilityRole]) : @"";
  // Never search a web page for a toolbar action with the same name.
  if ([role isEqual:@"AXWebArea"]) return;
  if ([role isEqual:NSAccessibilityButtonRole] || [role isEqual:NSAccessibilityPopUpButtonRole] || [role isEqual:NSAccessibilityMenuButtonRole]) {
    NSString* label = [element respondsToSelector:@selector(accessibilityLabel)] ? ExtensionAXText([element accessibilityLabel]) : @"";
    NSString* title = [element respondsToSelector:@selector(accessibilityTitle)] ? ExtensionAXText([element accessibilityTitle]) : @"";
    NSString* help = [element respondsToSelector:@selector(accessibilityHelp)] ? ExtensionAXText([element accessibilityHelp]) : @"";
    NSString* identifier = [element respondsToSelector:@selector(accessibilityIdentifier)] ? ExtensionAXText([element accessibilityIdentifier]) : @"";
    id value = [element respondsToSelector:@selector(accessibilityValue)] ? [element accessibilityValue] : nil;
    NSRect frame = [element respondsToSelector:@selector(accessibilityFrame)] ? [element accessibilityFrame] : NSZeroRect;
    [rows addObject:@{@"role": role, @"label": label, @"title": title, @"help": help, @"identifier": identifier,
      @"value": ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) ? value : NSNull.null,
      @"frame": NSStringFromRect(frame)}];
    if (name.length && ([label caseInsensitiveCompare:name] == NSOrderedSame ||
                        [title caseInsensitiveCompare:name] == NSOrderedSame)) {
      if ([element respondsToSelector:@selector(accessibilityPerformPress)]) [matches addObject:element];
    }
  }
  NSArray* children = [element respondsToSelector:@selector(accessibilityChildren)] ? [element accessibilityChildren] : nil;
  for (id child in children) ExtensionAXWalk(child, rows, matches, name, seen, depth + 1);
}
static NSArray* ExtensionActionButtons(NSWindow* window) {
  NSMutableArray* rows = [NSMutableArray new];
  NSMutableSet* seen = [NSMutableSet new];
  ExtensionAXWalk(window.contentView.superview ?: window.contentView, rows, [NSMutableArray new], @"", seen);
  for (NSWindow* child in window.childWindows) {
    if (child.isVisible) ExtensionAXWalk(child.contentView, rows, [NSMutableArray new], @"", seen);
  }
  return rows;
}
static bool ExtensionPressNamedAction(NSWindow* window, NSString* name, NSString** error) {
  if (!window || !name.length || name.length > 256) { *error = @"A native window and a short action name are required"; return false; }
  // Making the parent key dismisses its open Extensions menu. Preserve the
  // menu's focus when pressing an action found inside that owned child.
  bool hasChild = false;
  for (NSWindow* child in window.childWindows) if (child.isVisible) hasChild = true;
  if (!hasChild) {
    [NSApp activateIgnoringOtherApps:YES];
    [window orderFront:nil]; [window makeKeyWindow];
  }
  NSMutableArray* matches = [NSMutableArray new];
  NSMutableSet* seen = [NSMutableSet new];
  ExtensionAXWalk(window.contentView.superview ?: window.contentView, [NSMutableArray new], matches, name, seen);
  for (NSWindow* child in window.childWindows) {
    if (child.isVisible) ExtensionAXWalk(child.contentView, [NSMutableArray new], matches, name, seen);
  }
  if (matches.count != 1) { *error = [NSString stringWithFormat:@"Expected one native toolbar match, found %lu", (unsigned long)matches.count]; return false; }
  if (![matches.firstObject accessibilityPerformPress]) { *error = @"Native action refused the press"; return false; }
  return true;
}
static NSArray* ExtensionActionWidgets(NSWindow* owner, uint32_t (*context)(NSWindow*)) {
  NSMutableArray* widgets = [NSMutableArray new];
  for (NSWindow* window in NSApp.windows) {
    if (window.parentWindow != owner || !window.isVisible) continue;
    uint32_t cid = context(window);
    if (cid) [widgets addObject:@{@"window": @(window.windowNumber), @"contextId": @(cid),
      @"frame": NSStringFromRect(window.frame), @"class": NSStringFromClass(window.class)}];
  }
  return widgets;
}
