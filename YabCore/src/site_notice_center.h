#pragma once
#import <Foundation/Foundation.h>
#include <mach/mach.h>
#include <functional>
// Chromium's own macOS notification path, with Yab where macOS would be.
//
// Chrome hands every site notification, a page's or a service worker's, to
// NSUserNotificationCenter from its Mac service, in this process for a banner
// and in the " (Alerts)" helper for one that stays up. That center would post
// under the helper's name and icon. The stand-in installed here takes the
// class's place in the process: the same service, the same delivered list,
// the same delegate, but what it is given goes to Yab, which shows it under
// its own name, and what the person does comes back to Chromium's delegate.
namespace yc::notices {
// Every change, on any thread: op "show", "close" or "closeAll".
using Sink = std::function<void(NSDictionary*)>;
// Installs the stand-in. False if macOS has no such class to stand in for.
// `stayUp`: Chrome ends its service while nothing is delivered, and with it
// the delegate every answer goes back through, so this process's stays.
bool Install(Sink sink, bool stayUp = false);
// What the Alerts helper sends the browser process, one change a message:
// the change as JSON, out of line. The browser checks it in under the name
// in --yab-notices, as Chromium checks in its MachPortRendezvousServer.
constexpr mach_msg_id_t kNoticeMessage = 0x7961626e;  // 'yabn'
struct NoticeMessage {
  mach_msg_header_t header;
  mach_msg_body_t body;
  mach_msg_ool_descriptor_t json;
};
// In the browser process: an alert from the helper joins the delivered list
// here, where its click and its close are answered.
void AdoptFromHelper(NSDictionary* shown);
void ForgetFromHelper(NSDictionary* closed);
// What the person did. action: "click", "button" (with index) or "close".
// False if Chromium's delegate isn't up in this process.
bool Activate(NSString* action, NSInteger index, NSDictionary* userInfo);
}
// In the Alerts helper, called from its C main before CEF runs: stands in
// if this process is Chrome's notification service.
extern "C" void yc_notices_install_in_alerts_helper(int argc, char* argv[]);
