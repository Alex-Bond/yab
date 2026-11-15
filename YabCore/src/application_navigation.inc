// Chrome's native beforeunload Cancel calls this NSApplication selector even
// for an ordinary navigation. CefAppProtocol does not declare it. Mirror the
// pinned Chrome implementation, keeping this private compatibility seam here.
@interface NSObject (YabNavigationTerminationController)
+ (id)sharedController;
- (void)stopTryingToTerminateApplication;
@end
@implementation YabCoreApplication (NavigationTermination)
- (void)cancelTerminate:(id)sender {
  id controller = self.delegate;
  if (![controller respondsToSelector:@selector(stopTryingToTerminateApplication)]) {
    Class nativeController = NSClassFromString(@"AppController");
    controller = [nativeController respondsToSelector:@selector(sharedController)] ?
      [nativeController sharedController] : nil;
  }
  if ([controller respondsToSelector:@selector(stopTryingToTerminateApplication)]) {
    [controller stopTryingToTerminateApplication];
  }
  // The helper's socket-owned forced shutdown has no cancellable quit state.
  // CEF continues its original dialog OnCancel after this method returns.
}
@end
