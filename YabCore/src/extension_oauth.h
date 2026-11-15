#pragma once
#import <Foundation/Foundation.h>

namespace yc {
// Keep the reserved-origin boundary in sync with ChromiumOAuthRedirect.swift.
// A failed main-frame load here is a native extension callback, not a broken
// website. The native tabs event remains Chrome's; this never fabricates one.
inline bool ExtensionOAuthRedirect(NSString* address) {
  NSURL* url = [NSURL URLWithString:address];
  NSString* host = url.host.lowercaseString;
  NSString* suffix = @".chromiumapp.org";
  if (![url.scheme.lowercaseString isEqual:@"https"] || url.user || url.password ||
      (url.port && url.port.intValue != 443) || ![host hasSuffix:suffix]) return false;
  NSString* identifier = [host substringToIndex:host.length - suffix.length];
  if (identifier.length != 32) return false;
  for (NSUInteger i = 0; i < identifier.length; ++i) {
    unichar c = [identifier characterAtIndex:i];
    if (c < 'a' || c > 'p') return false;
  }
  return true;
}
}
