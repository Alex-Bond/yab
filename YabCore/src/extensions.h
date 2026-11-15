#pragma once
#import <Foundation/Foundation.h>

namespace yc {
// A command's key as chrome://extensions/shortcuts writes it on a Mac
// (cr_shortcut_util keystrokeToString), or "" for none: Command, Ctrl (the
// Control key), Alt and Shift, at least one but Shift, then one key Chrome
// lets a command have (Command::ParseImpl).
static bool ExtensionKeybindingValid(NSString* keybinding) {
  if (!keybinding.length) return true;
  if (keybinding.length > 64) return false;
  NSArray* parts = [keybinding componentsSeparatedByString:@"+"];
  if (parts.count < 2 || parts.count > 4) return false;
  NSSet* modifiers = [NSSet setWithArray:@[@"Command", @"Ctrl", @"Alt", @"Shift"]];
  NSMutableSet* seen = [NSMutableSet new];
  for (NSUInteger i = 0; i + 1 < parts.count; i++) {
    if (![modifiers containsObject:parts[i]] || [seen containsObject:parts[i]]) return false;
    [seen addObject:parts[i]];
  }
  // Shift alone isn't a command's modifier in Chrome.
  if (seen.count == 1 && [seen containsObject:@"Shift"]) return false;
  NSString* key = parts.lastObject;
  static NSSet* named = [NSSet setWithArray:@[@"Comma", @"Period", @"Home", @"End", @"PageUp", @"PageDown", @"Space",
                                              @"Insert", @"Delete", @"Up", @"Down", @"Left", @"Right", @"Tab"]];
  if ([named containsObject:key]) return true;
  if (key.length != 1) return false;
  unichar c = [key characterAtIndex:0];
  return (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
}
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
    // `escalated`: Chrome's updater put in a version asking for more and
    // turned it off until that is allowed (management's disabledReason;
    // developerPrivate's disableReasons has no field for it). `views`: the
    // kinds of the extension's open pages, chrome://extensions' "Inspect
    // views" (a tab, side panel, offscreen document, its worker; no popup).
    return @"(async()=>{const items=await new Promise((resolve,reject)=>chrome.developerPrivate.getExtensionsInfo({includeDisabled:true,includeTerminated:true},items=>chrome.runtime.lastError?reject(new Error(chrome.runtime.lastError.message)):resolve(items)));const why=Object.fromEntries((await new Promise(resolve=>chrome.management.getAll(all=>resolve(chrome.runtime.lastError?[]:all)))).map(m=>[m.id,m.disabledReason]));return items.map(e=>({escalated:why[e.id]==='permissions_increase',id:e.id,name:e.name,version:e.version,description:e.description,state:e.state,type:e.type,iconData:typeof e.iconUrl==='string'&&e.iconUrl.startsWith('data:image/png;base64,')&&e.iconUrl.length<200000?e.iconUrl:null,optionsURL:e.optionsPage?.url??null,location:e.location,disableReasons:e.disableReasons??{},path:e.path??null,access:e.permissions?.runtimeHostPermissions??null,incognito:e.incognitoAccess?.isActive===true,incognitoChangeable:e.incognitoAccess?.isEnabled===true,userScripts:e.userScriptsAccess?.isActive===true,userScriptsChangeable:e.userScriptsAccess?.isEnabled===true,commands:(e.commands??[]).map(c=>({name:c.name,description:c.description??'',active:c.isActive===true,global:c.scope==='GLOBAL',action:c.isExtensionAction===true})),views:(e.views??[]).map(v=>v.type)}))})()";
  }
  if ([method isEqual:@"extension.checkUpdates"]) {
    // Chrome's ExtensionUpdater, now rather than at its next check: every
    // store install is checked, and a newer version installed at once (an
    // extension asking for more is disabled until it is allowed, as Chromium
    // does). Settles when Chrome says the check is done; two minutes at most.
    return @"Promise.race([new Promise(resolve=>chrome.developerPrivate.autoUpdate(()=>resolve(true))),new Promise((_,reject)=>setTimeout(()=>reject(new Error('The update check did not finish')),120000))])";
  }
  NSString* extension = [params[@"extension"] isKindOfClass:NSString.class] ? params[@"extension"] : @"";
  NSCharacterSet* invalid = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnop"] invertedSet];
  if (extension.length != 32 || [extension rangeOfCharacterFromSet:invalid].location != NSNotFound) {
    *error = @"extension must be a Chrome extension ID (32 lowercase letters a-p)";
    return nil;
  }
  if ([method isEqual:@"extension.setEnabled"]) {
    if (![params[@"enabled"] isKindOfClass:NSNumber.class]) { *error = @"enabled is required"; return nil; }
    // userApproved (the dispatcher's gesture): turning on one Chrome turned
    // off for asking more, after Yab asked. Chrome's re-enable question
    // comes to the client (0013) and is answered there.
    if (params[@"userApproved"] && !([params[@"userApproved"] isEqual:@YES] && [params[@"enabled"] boolValue])) {
      *error = @"userApproved only turns an extension on"; return nil;
    }
    return [NSString stringWithFormat:@"new Promise((resolve,reject)=>chrome.management.setEnabled('%@',%@,()=>chrome.runtime.lastError?reject(new Error(chrome.runtime.lastError.message)):resolve(true)))", extension, [params[@"enabled"] boolValue] ? @"true" : @"false"];
  }
  if ([method isEqual:@"extension.access"]) {
    // Yab's one list says where it may reach; this makes Chrome's runtime
    // host permissions say the same. Only valid site patterns reach here.
    NSString* access = [params[@"hostAccess"] isKindOfClass:NSString.class] ? params[@"hostAccess"] : @"";
    if (![@[@"ON_CLICK", @"ON_SPECIFIC_SITES", @"ON_ALL_SITES"] containsObject:access]) { *error = @"hostAccess is required"; return nil; }
    NSRegularExpression* site = [NSRegularExpression regularExpressionWithPattern:@"^(\\*|https?)://(\\*\\.)?[a-z0-9.-]+/\\*$" options:0 error:nil];
    NSMutableArray* lists = [NSMutableArray new];
    for (NSString* key in @[@"add", @"remove"]) {
      NSArray* rows = params[key] ?: @[];
      if (![rows isKindOfClass:NSArray.class] || rows.count > 256) { *error = @"Site patterns must be a short list"; return nil; }
      for (id row in rows) {
        if (![row isKindOfClass:NSString.class] || ![site numberOfMatchesInString:row options:0 range:NSMakeRange(0, [row length])]) { *error = @"Invalid site pattern"; return nil; }
      }
      NSData* data = [NSJSONSerialization dataWithJSONObject:rows options:0 error:nil];
      [lists addObject:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]];
    }
    return [NSString stringWithFormat:@"(async()=>{const d=chrome.developerPrivate,id='%@';await d.updateExtensionConfiguration({extensionId:id,hostAccess:'%@'});for(const p of %@)await d.addHostPermission(id,p);for(const p of %@)await d.removeHostPermission(id,p);return true})()", extension, access, lists[0], lists[1]];
  }
  if ([method isEqual:@"extension.incognito"]) {
    // Yab's one "Allow in private tabs" switch, as Chromium's per-extension
    // "Allow in Incognito": the private side of this profile (CEF 0092)
    // runs the extension, spanning or split as its manifest says. Chrome
    // reloads an enabled extension to apply it.
    if (![params[@"enabled"] isKindOfClass:NSNumber.class]) { *error = @"enabled is required"; return nil; }
    return [NSString stringWithFormat:@"chrome.developerPrivate.updateExtensionConfiguration({extensionId:'%@',incognitoAccess:%@}).then(()=>true)", extension, [params[@"enabled"] boolValue] ? @"true" : @"false"];
  }
  if ([method isEqual:@"extension.command"]) {
    // chrome://extensions/shortcuts' own write: Chrome's CommandService takes
    // the key (from any other extension that had it) or, given "", clears it.
    // Only that page's form reaches it ("Command+Shift+X", "Ctrl+Alt+1").
    NSString* command = [params[@"command"] isKindOfClass:NSString.class] ? params[@"command"] : @"";
    NSString* keybinding = [params[@"keybinding"] isKindOfClass:NSString.class] ? params[@"keybinding"] : nil;
    if (!command.length || command.length > 256) { *error = @"command is required"; return nil; }
    if (!keybinding || !ExtensionKeybindingValid(keybinding)) { *error = @"keybinding must be empty or Chrome's form, such as Command+Shift+X"; return nil; }
    NSData* name = [NSJSONSerialization dataWithJSONObject:command options:NSJSONWritingFragmentsAllowed error:nil];
    NSData* keys = [NSJSONSerialization dataWithJSONObject:keybinding options:NSJSONWritingFragmentsAllowed error:nil];
    return [NSString stringWithFormat:@"chrome.developerPrivate.updateExtensionCommand({extensionId:'%@',commandName:%@,keybinding:%@}).then(()=>true)",
            extension, [[NSString alloc] initWithData:name encoding:NSUTF8StringEncoding], [[NSString alloc] initWithData:keys encoding:NSUTF8StringEncoding]];
  }
  if ([method isEqual:@"extension.userScripts"]) {
    // Chrome's per-extension "Allow User Scripts" (chrome://extensions
    // details, Chrome 138+): without it chrome.userScripts runs nothing, so
    // no Tampermonkey or Violentmonkey script reaches a page. Chrome keeps
    // it in the profile's prefs; Yab's one list says what it should be.
    if (![params[@"enabled"] isKindOfClass:NSNumber.class]) { *error = @"enabled is required"; return nil; }
    return [NSString stringWithFormat:@"chrome.developerPrivate.updateExtensionConfiguration({extensionId:'%@',userScriptsAccess:%@}).then(()=>true)", extension, [params[@"enabled"] boolValue] ? @"true" : @"false"];
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
