#import <JavaScriptCore/JavaScriptCore.h>
#include <cassert>
#include "../src/devtools_files.h"

int main() { @autoreleasepool {
  for (bool exists : {false, true}) {
    JSContext* context = [JSContext new];
    [context evaluateScript:@"var self=globalThis,top=self,location={origin:'devtools://devtools'};var messages=[];function yabDevToolsFile(m){messages.push(JSON.parse(m))};var host={close(){return 'stock'},other(){return 42}};"];
    if (exists) [context evaluateScript:@"InspectorFrontendHost=host"];
    [context evaluateScript:@(yc::DevToolsFileBridge().c_str())];
    if (!exists) [context evaluateScript:@"InspectorFrontendHost=host"];
    [context evaluateScript:@"InspectorFrontendHost.save('a.har','雪\\n',true,false);InspectorFrontendHost.append('a.har','tail');"];
    assert(!context.exception);
    assert([[context evaluateScript:@"messages.length===2 && messages[0].method==='save' && messages[0].content==='雪\\n' && messages[0].forceSaveAs===true && messages[0].isBase64===false && messages[1].method==='append' && messages[1].content==='tail'"] toBool]);
    assert([[context evaluateScript:@"InspectorFrontendHost===host && host.close()==='stock' && host.other()===42"] toBool]);
    // A compatibility bootstrap replacement receives the file routes too.
    [context evaluateScript:@"InspectorFrontendHost={};InspectorFrontendHost.save('b.gz','YQ==',false,true)"];
    assert(!context.exception);
    assert([[context evaluateScript:@"messages[2].url==='b.gz' && messages[2].isBase64===true"] toBool]);
  }
  for (NSString* setup in @[@"var self=globalThis,top={},location={origin:'devtools://devtools'};",
                            @"var self=globalThis,top=self,location={origin:'https://example.com'};"]) {
    JSContext* context = [JSContext new]; [context evaluateScript:setup];
    [context evaluateScript:@(yc::DevToolsFileBridge().c_str())];
    assert(!context.exception);
    assert([[context evaluateScript:@"!Object.hasOwn(globalThis,'InspectorFrontendHost')"] toBool]);
  }
  puts("PASS: DevTools save/append ABI, bootstrap replacement, Unicode/base64 and foreign-frame exclusion");
} }
