#pragma once
#import <Foundation/Foundation.h>

namespace yc {
// Keep the version-specific Chrome management surface out of the dispatcher.
// Only run this expression in chrome://extensions/ in the requested profile.
static NSString* ExtensionExpression(NSString* method, NSDictionary* params, NSString** error, bool nativeConsent = false) {
  if ([method isEqual:@"extension.review"]) {
    NSString* manifest = [params[@"manifest"] isKindOfClass:NSString.class] ? params[@"manifest"] : nil;
    NSData* data = [manifest dataUsingEncoding:NSUTF8StringEncoding];
    if (!data || data.length > 1000000 || ![[NSJSONSerialization JSONObjectWithData:data options:0 error:nil] isKindOfClass:NSDictionary.class]) {
      *error = @"A valid extension manifest is required"; return nil;
    }
    NSData* quoted = [NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingFragmentsAllowed error:nil];
    NSString* argument = [[NSString alloc] initWithData:quoted encoding:NSUTF8StringEncoding];
    return [NSString stringWithFormat:@"new Promise((resolve,reject)=>chrome.management.getPermissionWarningsByManifest(%@,warnings=>chrome.runtime.lastError?reject(new Error(chrome.runtime.lastError.message)):resolve(warnings)))", argument];
  }
  if ([method isEqual:@"extension.list"]) {
    // Chrome already supplies a PNG data URL. Reading it directly respects
    // the management page's connect-src policy; fetching it would be refused.
    return @"(async()=>{const items=await new Promise((resolve,reject)=>chrome.developerPrivate.getExtensionsInfo({includeDisabled:true,includeTerminated:true},items=>chrome.runtime.lastError?reject(new Error(chrome.runtime.lastError.message)):resolve(items)));return items.map(e=>({id:e.id,name:e.name,version:e.version,description:e.description,state:e.state,type:e.type,iconData:typeof e.iconUrl==='string'&&e.iconUrl.startsWith('data:image/png;base64,')&&e.iconUrl.length<200000?e.iconUrl:null,optionsURL:e.optionsPage?.url??null,location:e.location,disableReasons:e.disableReasons??{}}))})()";
  }
  NSString* extension = [params[@"extension"] isKindOfClass:NSString.class] ? params[@"extension"] : @"";
  NSCharacterSet* invalid = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnop"] invertedSet];
  if (extension.length != 32 || [extension rangeOfCharacterFromSet:invalid].location != NSNotFound) {
    *error = @"extension must be a Chrome extension ID (32 lowercase letters a-p)";
    return nil;
  }
  if ([method isEqual:@"extension.setEnabled"]) {
    if (![params[@"enabled"] isKindOfClass:NSNumber.class]) { *error = @"enabled is required"; return nil; }
    return [NSString stringWithFormat:@"new Promise((resolve,reject)=>chrome.management.setEnabled('%@',%@,()=>chrome.runtime.lastError?reject(new Error(chrome.runtime.lastError.message)):resolve(true)))", extension, [params[@"enabled"] boolValue] ? @"true" : @"false"];
  }
  if ([method isEqual:@"extension.remove"]) {
    if (![params[@"userApproved"] isEqual:@YES]) { *error = @"Confirm removal in Yab first"; return nil; }
    // Do not hold a DevTools evaluation open across extension destruction.
    // The caller observes the callback error and verifies absence separately.
    return [NSString stringWithFormat:@"(()=>{const state={id:'%@',done:false,error:null};globalThis.__yabNativeRemoval=state;chrome.management.uninstall(state.id,{showConfirmDialog:%@},()=>{state.error=chrome.runtime.lastError?.message??null;state.done=true});return {nativeConsent:%@}})()", extension, nativeConsent ? @"true" : @"false", nativeConsent ? @"true" : @"false"];
  }
  if ([method isEqual:@"extension.removalState"]) {
    return [NSString stringWithFormat:@"(()=>{const s=globalThis.__yabNativeRemoval;if(s?.id!=='%@')throw new Error('No matching reviewed removal');return {done:s.done,error:s.error}})()", extension];
  }
  *error = @"Unknown extension method";
  return nil;
}
}
