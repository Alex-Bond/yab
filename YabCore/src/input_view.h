#ifndef YABCORE_INPUT_VIEW_H_
#define YABCORE_INPUT_VIEW_H_
#import <AppKit/AppKit.h>

// BFCache keeps old RenderWidgetHostViewCocoa children in this hierarchy.
// The first match can belong to a hidden cached document rather than the
// current page. Keep native input on the visible view, including when its
// producer NSWindow is intentionally hidden by the external embedder.
static NSView* FindView(NSView* view, NSString* name) {
  if (!view || view.isHiddenOrHasHiddenAncestor) return nil;
  if ([NSStringFromClass(view.class) isEqual:name]) return view;
  for (NSView* child in view.subviews) {
    if (NSView* found = FindView(child, name)) return found;
  }
  return nil;
}
#endif
