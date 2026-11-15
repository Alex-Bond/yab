#import <Foundation/Foundation.h>
#include <cassert>
#include "../src/extension_oauth.h"
#include "../src/devtools_target.h"

int main() { @autoreleasepool {
  NSString* origin = @"https://fkmaohpngenfoccdgceedjkfhkdcohmg.chromiumapp.org";
  for (NSString* suffix in @[@"/", @"/callback?code=a%2Fb&state=unchanged#fragment",
                             @":443/?code=fixture"]) {
    assert(yc::ExtensionOAuthRedirect([origin stringByAppendingString:suffix]));
  }
  for (NSString* address in @[
      @"http://fkmaohpngenfoccdgceedjkfhkdcohmg.chromiumapp.org/",
      @"https://fkmaohpngenfoccdgceedjkfhkdcohmg.chromiumapp.org:8443/",
      @"https://fkmaohpngenfoccdgceedjkfhkdcohmg.chromiumapp.org.evil.test/",
      @"https://www.fkmaohpngenfoccdgceedjkfhkdcohmg.chromiumapp.org/",
      @"https://user@fkmaohpngenfoccdgceedjkfhkdcohmg.chromiumapp.org/",
      @"https://fkmaohpngenfoccdgceedjkfhkdcohmg.chromiumapp.org@evil.test/",
      @"https://bad.chromiumapp.org/", @"https://chromiumapp.org/",
      @"https://zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz.chromiumapp.org/", @""]) {
    assert(!yc::ExtensionOAuthRedirect(address));
  }
  for (const std::string type : {"page", "tab", "service_worker", "shared_worker", "worker"}) {
    const bool worker = type.find("worker") != std::string::npos;
    assert(yc::DevToolsFrontend(type) == (worker ? "worker_app.html" : "devtools_app.html"));
    assert(yc::DevToolsTargetQuery(type) == (type == "tab" ? "&targetType=tab" : ""));
  }
  puts("PASS: reserved OAuth origins and page/tab/worker frontend selection");
} }
