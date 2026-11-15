#pragma once
#include <cstdlib>
#include <cstring>

// Opt-in prebuilt fallback from spike G. Keep it separate from path F until
// independent surfaces and active-tab ownership pass on the actual app.
static bool NativeExtensionWindows() {
  const char* value = getenv("YAB_CEF_EXTENSION_WINDOWS");
  return value && strcmp(value, "1") == 0;
}
static NSWindow* ExtensionBrowserWindow(CefRefPtr<CefBrowser> browser) {
  if (!browser) return nil;
  NSView* view = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
  return [(NSObject*)view isKindOfClass:NSWindow.class] ? (NSWindow*)(NSObject*)view : view.window;
}
static NSView* ExtensionPageView(NSView* view) {
  if ([NSStringFromClass(view.class) isEqual:@"RenderWidgetHostViewCocoa"]) return view;
  for (NSView* child in view.subviews) if (NSView* found = ExtensionPageView(child)) return found;
  return nil;
}
// The hosted compositor is the content view's, so page offsets are measured
// from it; a titled popup's title bar lies outside it.
static NSView* ExtensionPageRoot(NSWindow* window) {
  NSView* page = ExtensionPageView(window.contentView);
  return page ? window.contentView : (window.contentView.superview ?: window.contentView);
}
static NSRect ExtensionPageRect(NSWindow* window) {
  NSView* root = ExtensionPageRoot(window);
  NSView* page = ExtensionPageView(root);
  if (!page) return NSZeroRect;
  NSRect rect = [page convertRect:page.bounds toView:root];
  if (!root.isFlipped) rect.origin.y = root.bounds.size.height - NSMaxY(rect);
  return rect;
}
static void ResizeExtensionWindow(NSWindow* window, double width, double height) {
  NSView* page = ExtensionPageView(window.contentView.superview ?: window.contentView);
  if (!page) return;
  NSRect shown = [window convertRectToScreen:[page convertRect:page.bounds toView:nil]];
  NSRect frame = window.frame;
  double extraWidth = frame.size.width - shown.size.width;
  double extraHeight = frame.size.height - shown.size.height;
  NSSize size = NSMakeSize(width + extraWidth, height + extraHeight);
  if (fabs(frame.size.width - size.width) < 0.5 && fabs(frame.size.height - size.height) < 0.5) return;
  frame.origin.y += frame.size.height - size.height;
  frame.size = size;
  [window setFrame:frame display:YES];
}
