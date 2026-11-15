#import "site_notice_center.h"
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#include <string>
#include <string_view>
#include <mutex>
#include <servers/bootstrap.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

namespace {
yc::notices::Sink sink;
NSString* Text(id value) { return [value isKindOfClass:NSString.class] ? value : @""; }
NSDictionary* Described(NSUserNotification* toast) {
  NSMutableDictionary* out = [NSMutableDictionary dictionary];
  NSDictionary* info = toast.userInfo ?: @{};
  out[@"op"] = @"show";
  out[@"key"] = Text(toast.identifier);
  out[@"id"] = Text(info[@"notificationId"]);
  out[@"profile"] = Text(info[@"notificationProfileId"]);
  out[@"incognito"] = @([info[@"notificationIncognito"] boolValue]);
  out[@"origin"] = Text(info[@"notificationOrigin"]);
  out[@"type"] = @([info[@"notificationType"] intValue]);
  out[@"directory"] = Text(info[@"notificationUserDataDir"]);
  out[@"title"] = Text(toast.title);
  out[@"subtitle"] = Text(toast.subtitle);
  out[@"body"] = Text(toast.informativeText);
  NSMutableArray* buttons = [NSMutableArray array];
  if ([toast respondsToSelector:NSSelectorFromString(@"_alternateActionButtonTitles")]) {
    NSArray* titles = [toast valueForKey:@"_alternateActionButtonTitles"];
    if ([titles isKindOfClass:NSArray.class]) [buttons addObjectsFromArray:titles];
  }
  if (!buttons.count && toast.hasActionButton && toast.actionButtonTitle.length) [buttons addObject:toast.actionButtonTitle];
  // The last one is Chrome's own Settings when the service added it.
  if ([info[@"notificationHasSettingsButton"] boolValue] && buttons.count) [buttons removeLastObject];
  out[@"buttons"] = buttons;
  if (toast.contentImage) {
    NSData* tiff = toast.contentImage.TIFFRepresentation;
    NSBitmapImageRep* bits = tiff ? [NSBitmapImageRep imageRepWithData:tiff] : nil;
    NSData* png = [bits representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (png.length) out[@"image"] = [png base64EncodedStringWithOptions:0];
  }
  return out;
}
}  // namespace

// What the delegate reads of a toast the person answered.
@interface YabAnsweredToast : NSObject
@property(nonatomic, copy) NSDictionary* userInfo;
@property(nonatomic) NSUserNotificationActivationType activationType;
@property(nonatomic, copy) NSArray* buttons;
@property(nonatomic) NSInteger pressed;
@end
@implementation YabAnsweredToast
- (NSArray*)_alternateActionButtonTitles { return _buttons; }
- (NSNumber*)_alternateActionIndex { return @(_pressed); }
@end

// Answers what MacNotificationServiceNS calls on NSUserNotificationCenter.
@interface YabNoticeCenter : NSObject
+ (instancetype)shared;
@property(atomic, weak) id delegate;
@property(atomic, strong) NSUserNotification* keep;
@end
@implementation YabNoticeCenter {
  NSMutableArray<NSUserNotification*>* _delivered;
}
+ (instancetype)shared {
  static YabNoticeCenter* center;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ center = [YabNoticeCenter new]; });
  return center;
}
- (instancetype)init {
  if ((self = [super init])) _delivered = [NSMutableArray array];
  return self;
}
- (void)deliverNotification:(NSUserNotification*)toast {
  @synchronized(self) {
    NSIndexSet* same = [_delivered indexesOfObjectsPassingTest:^BOOL(NSUserNotification* row, NSUInteger, BOOL*) {
      return [row.identifier isEqualToString:toast.identifier];
    }];
    [_delivered removeObjectsAtIndexes:same];
    [_delivered addObject:toast];
  }
  if (sink) sink(Described(toast));
}
- (NSArray<NSUserNotification*>*)deliveredNotifications {
  @synchronized(self) { return self.keep ? [_delivered arrayByAddingObject:self.keep] : [_delivered copy]; }
}
- (NSArray<NSUserNotification*>*)scheduledNotifications { return @[]; }
- (void)removeDeliveredNotification:(NSUserNotification*)toast {
  @synchronized(self) {
    [_delivered removeObject:toast];
  }
  if (sink) sink(@{@"op": @"close", @"key": Text(toast.identifier), @"id": Text(toast.userInfo[@"notificationId"]),
                   @"origin": Text(toast.userInfo[@"notificationOrigin"])});
}
- (void)removeAllDeliveredNotifications {
  @synchronized(self) { [_delivered removeAllObjects]; }
  if (sink) sink(@{@"op": @"closeAll"});
}
- (void)adopt:(NSUserNotification*)toast {
  @synchronized(self) {
    NSIndexSet* same = [_delivered indexesOfObjectsPassingTest:^BOOL(NSUserNotification* row, NSUInteger, BOOL*) {
      return [row.identifier isEqualToString:toast.identifier];
    }];
    [_delivered removeObjectsAtIndexes:same];
    [_delivered addObject:toast];
  }
}
- (void)forget:(NSString*)key {
  @synchronized(self) {
    NSIndexSet* same = [_delivered indexesOfObjectsPassingTest:^BOOL(NSUserNotification* row, NSUInteger, BOOL*) {
      return [row.identifier isEqualToString:key];
    }];
    [_delivered removeObjectsAtIndexes:same];
  }
}
@end

namespace yc::notices {
bool Install(Sink given, bool stayUp) {
  sink = std::move(given);
  if (stayUp) {
    // Matches no profile and no origin: it only keeps the list from being empty.
    NSUserNotification* keep = [NSUserNotification new];
    keep.identifier = @"yab.keep";
    keep.userInfo = @{@"notificationId": @"", @"notificationProfileId": @"", @"notificationIncognito": @NO, @"notificationOrigin": @""};
    [YabNoticeCenter shared].keep = keep;
  }
  Class center = NSClassFromString(@"NSUserNotificationCenter");
  Method original = center ? class_getClassMethod(center, @selector(defaultUserNotificationCenter)) : nullptr;
  if (!original) return false;
  IMP standIn = imp_implementationWithBlock(^id(id) { return [YabNoticeCenter shared]; });
  method_setImplementation(original, standIn);
  return true;
}

void AdoptFromHelper(NSDictionary* shown) {
  // Chrome's service in this process closes it by reading this row.
  NSUserNotification* toast = [NSUserNotification new];
  toast.identifier = Text(shown[@"key"]);
  toast.userInfo = @{@"notificationId": Text(shown[@"id"]), @"notificationProfileId": Text(shown[@"profile"]),
                     @"notificationIncognito": @([shown[@"incognito"] boolValue]), @"notificationOrigin": Text(shown[@"origin"]),
                     @"notificationType": @([shown[@"type"] intValue]), @"notificationUserDataDir": Text(shown[@"directory"])};
  [[YabNoticeCenter shared] adopt:toast];
}

void ForgetFromHelper(NSDictionary* closed) { [[YabNoticeCenter shared] forget:Text(closed[@"key"])]; }

bool Activate(NSString* action, NSInteger index, NSDictionary* userInfo) {
  id delegate = [YabNoticeCenter shared].delegate;
  if (!delegate) return false;
  YabAnsweredToast* toast = [YabAnsweredToast new];
  toast.userInfo = userInfo;
  toast.buttons = @[];
  if ([action isEqual:@"close"]) {
    toast.activationType = NSUserNotificationActivationTypeNone;
    SEL dismiss = NSSelectorFromString(@"userNotificationCenter:didDismissAlert:");
    if ([delegate respondsToSelector:dismiss])
      ((void (*)(id, SEL, id, id))[delegate methodForSelector:dismiss])(delegate, dismiss, [YabNoticeCenter shared], toast);
    [[YabNoticeCenter shared] forget:Text(userInfo[@"key"])];
    return true;
  }
  if ([action isEqual:@"button"]) {
    toast.activationType = NSUserNotificationActivationTypeActionButtonClicked;
    // The service counts the titles to know a menu from one button. Only
    // the count is read, and it needs the index to be inside it.
    NSMutableArray* titles = [NSMutableArray array];
    for (NSInteger i = 0; i < MAX(index + 1, 2); ++i) [titles addObject:@""];
    toast.buttons = titles;
    toast.pressed = index;
  } else {
    toast.activationType = NSUserNotificationActivationTypeContentsClicked;
  }
  SEL activate = @selector(userNotificationCenter:didActivateNotification:);
  if (![delegate respondsToSelector:activate]) return false;
  ((void (*)(id, SEL, id, id))[delegate methodForSelector:activate])(delegate, activate, [YabNoticeCenter shared], toast);
  [[YabNoticeCenter shared] forget:Text(userInfo[@"key"])];
  return true;
}

}  // namespace yc::notices

// The Alerts helper's half: Chromium's own service runs here unchanged,
// unsandboxed as in Chromium (kNoSandbox), and the stand-in hands each change
// to the browser process over Mach, the way this process already finds its
// browser (MachPortRendezvousServer). Nothing on disk, nothing listening.
extern "C" void yc_notices_install_in_alerts_helper(int argc, char* argv[]) {
  constexpr std::string_view kSwitch = "--yab-notices=";
  constexpr std::string_view kService = "--utility-sub-type=mac_notifications.mojom.MacNotificationProvider";
  std::string name;
  bool service = false;
  for (int i = 1; i < argc; ++i) {
    std::string_view arg(argv[i]);
    if (arg == kService) service = true;
    if (arg.substr(0, kSwitch.size()) == kSwitch) name = std::string(arg.substr(kSwitch.size()));
  }
  if (!service || name.empty() || name.size() >= sizeof(name_t)) return;
  // One way only: a click is answered by the browser process's own service,
  // which reads everything it needs from the row adopted there. Looked up at
  // the first change, not at launch.
  yc::notices::Install([name](NSDictionary* change) {
    NSData* json = [NSJSONSerialization dataWithJSONObject:change options:0 error:nil];
    if (!json.length) return;
    static mach_port_t browser = MACH_PORT_NULL;
    static std::mutex once;
    std::lock_guard<std::mutex> hold(once);
    if (browser == MACH_PORT_NULL &&
        bootstrap_look_up(bootstrap_port, const_cast<char*>(name.c_str()), &browser) != KERN_SUCCESS) {
      browser = MACH_PORT_NULL;
      return;
    }
    yc::notices::NoticeMessage message{};
    message.header.msgh_bits = MACH_MSGH_BITS_SET(MACH_MSG_TYPE_COPY_SEND, 0, 0, MACH_MSGH_BITS_COMPLEX);
    message.header.msgh_size = sizeof(message);
    message.header.msgh_remote_port = browser;
    message.header.msgh_id = yc::notices::kNoticeMessage;
    message.body.msgh_descriptor_count = 1;
    message.json.address = const_cast<void*>(json.bytes);
    message.json.size = static_cast<mach_msg_size_t>(json.length);
    message.json.deallocate = false;
    message.json.copy = MACH_MSG_VIRTUAL_COPY;
    message.json.type = MACH_MSG_OOL_DESCRIPTOR;
    kern_return_t sent = mach_msg(&message.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof(message), 0,
                                  MACH_PORT_NULL, 2000, MACH_PORT_NULL);
    // The browser went away with its name: look it up again next time.
    if (sent == MACH_SEND_INVALID_DEST) {
      mach_port_deallocate(mach_task_self(), browser);
      browser = MACH_PORT_NULL;
    }
  });
}
#pragma clang diagnostic pop
