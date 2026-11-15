#include <string_view>
#include "core.h"
#include "core_lifetime.h"
#include "original_caller.h"
#include <limits.h>
#include <stdlib.h>
#include <errno.h>
#include "include/cef_application_mac.h"
#include "include/cef_command_line.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"
@interface YabCoreApplication : NSApplication <CefAppProtocol>
@property(nonatomic) BOOL handlingSendEvent;
@end
@implementation YabCoreApplication
- (BOOL)isHandlingSendEvent { return self.handlingSendEvent; }
- (void)sendEvent:(NSEvent*)event { CefScopedSendingEvent scope; [super sendEvent:event]; }
- (void)terminate:(id)sender { yc::Shutdown(); }
@end
#include "application_navigation.inc"
int main(int argc, char* argv[]) {
  yc::OwnerWatch owner;
  if (!owner.Start()) { fprintf(stderr, "YabCore client is unavailable\n"); return 2; }
  @autoreleasepool {
    bool observeOriginalCaller = false, deadlineOriginalCaller = false;
    for (int i = 1; i < argc; ++i) {
      if (std::string_view(argv[i]) == "--observe-original-caller") observeOriginalCaller = true;
      if (std::string_view(argv[i]) == "--original-caller-deadline-gate") deadlineOriginalCaller = true;
    }
    yc::original_caller::CaptureBeforeCEF(STDIN_FILENO, observeOriginalCaller, deadlineOriginalCaller);
  }
  CefScopedLibraryLoader loader;
  if (!loader.LoadInMain()) return 1;
  @autoreleasepool {
    [YabCoreApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    auto command = CefCommandLine::CreateCommandLine(); command->InitFromArgv(argc, argv);
    NSString* root = @(command->GetSwitchValue("data-root").ToString().c_str());
    NSString* socket = @(command->GetSwitchValue("socket").ToString().c_str());
    if (!root.isAbsolutePath || !socket.isAbsolutePath) {
      fprintf(stderr, "YabCore requires absolute --data-root and --socket paths\n"); return 2;
    }
    NSError* directoryError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES
          attributes:@{NSFilePosixPermissions: @0700} error:&directoryError]) {
      fprintf(stderr, "Cannot create YabCore data root: %s\n", directoryError.localizedDescription.UTF8String); return 2;
    }
    // Chromium canonicalizes --user-data-dir. Match it for request contexts,
    // including macOS's /tmp -> /private/tmp symlink.
    char canonicalRoot[PATH_MAX];
    if (!realpath(root.fileSystemRepresentation, canonicalRoot)) {
      fprintf(stderr, "Cannot resolve YabCore data root: %s\n", strerror(errno)); return 2;
    }
    root = @(canonicalRoot);
    // After a helper crash Chrome offers "Restore pages?" from a window Yab
    // never shows; building that bubble has also killed the helper again.
    // Yab restores its own tabs, so every profile starts as if it exited
    // cleanly. Only the exit type changes; a malformed file is left alone.
    NSDirectoryEnumerator* walk = [NSFileManager.defaultManager enumeratorAtPath:root];
    for (NSString* name in walk) {
      if (walk.level >= 3) { [walk skipDescendants]; continue; }
      if (![name.lastPathComponent isEqualToString:@"Preferences"]) continue;
      NSString* path = [root stringByAppendingPathComponent:name];
      NSData* data = [NSData dataWithContentsOfFile:path];
      id prefs = data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil] : nil;
      if (![prefs isKindOfClass:NSMutableDictionary.class]) continue;
      NSMutableDictionary* profile = prefs[@"profile"];
      if (![profile isKindOfClass:NSMutableDictionary.class] || [profile[@"exit_type"] isEqual:@"Normal"]) continue;
      profile[@"exit_type"] = @"Normal";
      profile[@"exited_cleanly"] = @YES;
      NSData* written = [NSJSONSerialization dataWithJSONObject:prefs options:0 error:nil];
      if (written) [written writeToFile:path atomically:YES];
    }
    CefSettings settings;
    // The owning app's executable is yab, not YabCore. Do not let CEF
    // derive a nonexistent yab Helper from its top-level Info.plist.
    NSString* bundle = NSBundle.mainBundle.bundlePath;
    NSString* subprocess = [bundle stringByAppendingPathComponent:
      @"Contents/Frameworks/YabCore Helper.app/Contents/MacOS/YabCore Helper"];
    CefString(&settings.browser_subprocess_path) = subprocess.UTF8String;
#if !defined(CEF_USE_SANDBOX)
    settings.no_sandbox = true;
#endif
    settings.use_views_default_popup = true;
    CefString(&settings.root_cache_path) = root.UTF8String;
    CefString(&settings.cache_path) = root.UTF8String;
    auto app = yc::MakeApp(root, socket);
    if (!CefInitialize(CefMainArgs(argc, argv), settings, app, nullptr)) return CefGetExitCode();
    CefRunMessageLoop();
    // Release all browser references before CefShutdown, including observers.
    yc::TearDown();
    app = nullptr;
    CefShutdown();
  }
  return 0;
}
