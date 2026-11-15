// AppKit's bridge for an element in another process, private, as Chromium's
// ui/base/cocoa/remote_accessibility_api.h declares it.
#import <AppKit/AppKit.h>
@interface NSAccessibilityRemoteUIElement : NSObject
+ (void)registerRemoteUIProcessIdentifier:(int)pid;
+ (NSData*)remoteTokenForLocalUIElement:(id)element;
- (id)initWithRemoteToken:(NSData*)token;
@end
@interface NSView (YabAccessibilityParent)
- (void)setAccessibilityParentElement:(id)parent;
@end
