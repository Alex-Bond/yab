#pragma once
#import <Cocoa/Cocoa.h>
#include "include/cef_app.h"
#include <functional>
#include "transport.h"
namespace yc {
using Completion = std::function<void(NSDictionary*, NSString*)>;
CefRefPtr<CefApp> MakeApp(NSString* root, NSString* socket);
// Yab's choices for a Chrome profile, written before Chrome reads the file.
void SeedPreferences(NSString* path);
void Shutdown();
void TearDown();
// The focused node of the page Yab has focused, for NSApplication's
// accessibilityFocusedUIElement (accessibility.inc); nil when none.
id AccessibilityFocusedElement();
}
