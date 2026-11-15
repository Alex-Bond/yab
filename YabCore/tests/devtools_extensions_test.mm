#import <JavaScriptCore/JavaScriptCore.h>
#include <cassert>
#include "../src/devtools_extensions.h"

int main() { @autoreleasepool {
  assert(yc::DevToolsExtensionIdentity(0).empty());
  assert(yc::DevToolsExtensionIdentity(-1).empty());
  for (bool exists : {false, true}) {
    JSContext* context = [JSContext new];
    [context evaluateScript:@"var self=globalThis,top=self,location={origin:'devtools://devtools'};var received=[];var api={setInspectedTabId(id){received.push(id)}};"];
    if (exists) [context evaluateScript:@"globalThis.DevToolsAPI=api"];
    [context evaluateScript:@(yc::DevToolsExtensionIdentity(1234).c_str())];
    if (!exists) [context evaluateScript:@"globalThis.DevToolsAPI=api"];
    assert(!context.exception);
    assert([[context evaluateScript:@"received.length===1 && received[0]===1234 && DevToolsAPI===api"] toBool]);
    // A second native compatibility bootstrap must get the same identity.
    assert([[context evaluateScript:@"const d=Object.getOwnPropertyDescriptor(globalThis,'DevToolsAPI'); typeof d.set==='function'&&typeof d.get==='function'&&d.configurable&&d.enumerable"] toBool]);
    [context evaluateScript:@"DevToolsAPI={setInspectedTabId(id){received.push(id)}}"];
    assert([[context evaluateScript:@"received.length===2 && received[1]===1234"] toBool]);
    [context evaluateScript:@"DevToolsAPI={another:true}"];
    assert([[context evaluateScript:@"DevToolsAPI.another && received.length===2"] toBool]);
  }
  for (NSString* setup in @[@"var self=globalThis,top={},location={origin:'devtools://devtools'};",
                            @"var self=globalThis,top=self,location={origin:'https://example.com'};"]) {
    JSContext* context = [JSContext new];
    [context evaluateScript:setup];
    [context evaluateScript:@(yc::DevToolsExtensionIdentity(1234).c_str())];
    assert(!context.exception);
    assert([[context evaluateScript:@"!Object.hasOwn(globalThis,'DevToolsAPI')"] toBool]);
  }
  puts("PASS: inspected tab seeded before extension API initialization; foreign frames excluded");
} }
