// Legacy flat helpers can receive scripting events addressed to Yab.
// Keep their relay for compatibility. The independently identified nested
// helper has no scripting dictionary, so installation below does nothing.
// A quit addressed to this process always belongs to this process.
@interface YabCoreScriptingRelay : NSObject
@end

@implementation YabCoreScriptingRelay {
  pid_t _owner;
}

/// Once launching has finished, when Cocoa has put its own handlers in.
+ (void)install {
  static YabCoreScriptingRelay* relay;
  if (!relay) {
    // Only under the Yab that owns this process, the same app by bundle id.
    pid_t owner = getppid();
    NSRunningApplication* app = [NSRunningApplication runningApplicationWithProcessIdentifier:owner];
    NSString* ours = NSBundle.mainBundle.bundleIdentifier;
    if (!app || !ours || ![app.bundleIdentifier isEqualToString:ours]) return;
    if (![[NSBundle.mainBundle objectForInfoDictionaryKey:@"NSAppleScriptEnabled"] boolValue]) return;
    relay = [YabCoreScriptingRelay new];
    relay->_owner = owner;
  }
  NSAppleEventManager* manager = NSAppleEventManager.sharedAppleEventManager;
  // Every command of the dictionary, Cocoa's get, set, count and exists
  // among them; each of Cocoa's handlers for one is replaced by the relay.
  NSScriptSuiteRegistry* registry = NSScriptSuiteRegistry.sharedScriptSuiteRegistry;
  NSMutableSet<NSString*>* codes = [NSMutableSet set];
  auto take = [&](FourCharCode eventClass, FourCharCode eventID) {
    if (eventClass == kCoreEventClass) return;
    [manager setEventHandler:relay andSelector:@selector(relay:withReply:) forEventClass:eventClass andEventID:eventID];
    [codes addObject:[NSString stringWithFormat:@"%08x%08x", eventClass, eventID]];
  };
  for (NSString* suite in registry.suiteNames)
    for (NSScriptCommandDescription* command in [registry commandDescriptionsInSuite:suite].allValues)
      take(command.appleEventClassCode, command.appleEventCode);
  const FourCharCode cocoas[] = {kAEGetData, kAESetData, kAECountElements, kAEDoObjectsExist};
  for (const FourCharCode eventID : cocoas) take(kAECoreSuite, eventID);
  // Open a file, open location: macOS's events, not the dictionary's.
  const FourCharCode systems[][2] = {
      {kCoreEventClass, kAEOpenDocuments}, {kInternetEventClass, kAEGetURL}};
  for (const auto& system : systems) {
    [manager setEventHandler:relay andSelector:@selector(relay:withReply:) forEventClass:system[0] andEventID:system[1]];
    [codes addObject:[NSString stringWithFormat:@"%08x%08x", system[0], system[1]]];
  }
  const NSUInteger relayed = codes.count;
  if (getenv("YAB_PROBE") && *getenv("YAB_PROBE"))
    fprintf(stderr, "YabCore passes %lu scripting commands to Yab (pid %d), open and open location among them\n", (unsigned long)relayed, relay->_owner);
}

- (void)relay:(NSAppleEventDescriptor*)event withReply:(NSAppleEventDescriptor*)reply {
  const bool quit = event.eventClass == kCoreEventClass && event.eventID == kAEQuitApplication;
  if (quit) {
    [NSApp terminate:nil];
    return;
  }
  NSAppleEventDescriptor* passed = [NSAppleEventDescriptor
      appleEventWithEventClass:event.eventClass eventID:event.eventID
              targetDescriptor:[NSAppleEventDescriptor descriptorWithProcessIdentifier:_owner]
                      returnID:kAutoGenerateReturnID transactionID:kAnyTransactionID];
  for (NSInteger i = 1; i <= event.numberOfItems; ++i) {
    const AEKeyword key = [event keywordForDescriptorAtIndex:i];
    if (NSAppleEventDescriptor* value = [event paramDescriptorForKeyword:key]) [passed setParamDescriptor:value forKeyword:key];
  }
  // `tell front window to …` names its object here ('subj', ASRegistry's
  // keySubjectAttr); `considering case` too ('cons', 'csig').
  const AEKeyword attributes[] = {'subj', 'cons', 'csig'};
  for (const AEKeyword key : attributes) {
    if (NSAppleEventDescriptor* value = [event attributeDescriptorForKeyword:key]) [passed setAttributeDescriptor:value forKeyword:key];
  }
  // The sender's own timeout, in ticks, when it gave one.
  long ticks = kAEDefaultTimeout;
  if (NSAppleEventDescriptor* timeout = [event attributeDescriptorForKeyword:keyTimeoutAttr]) ticks = timeout.int32Value;
  const bool wantsReply = reply.descriptorType != typeNull;
  NSAppleEventManager* manager = NSAppleEventManager.sharedAppleEventManager;
  NSAppleEventManagerSuspensionID suspension = [manager suspendCurrentAppleEvent];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    AppleEvent answer = {typeNull, nullptr};
    const OSStatus sent = AESendMessage(passed.aeDesc, &answer,
                                        (wantsReply ? kAEWaitReply : kAENoReply) | kAECanInteract, ticks);
    NSAppleEventDescriptor* got = [[NSAppleEventDescriptor alloc] initWithAEDescNoCopy:&answer];
    dispatch_async(dispatch_get_main_queue(), ^{
      NSAppleEventDescriptor* out = [manager replyAppleEventForSuspensionID:suspension];
      if (out && out.descriptorType != typeNull) {
        // Yab quit before it answered the quit: that is the answer.
        if (sent != noErr && !(quit && (sent == connectionInvalid || sent == procNotFound))) {
          [out setParamDescriptor:[NSAppleEventDescriptor descriptorWithInt32:sent] forKeyword:keyErrorNumber];
        } else {
          for (NSInteger i = 1; i <= got.numberOfItems; ++i) {
            const AEKeyword key = [got keywordForDescriptorAtIndex:i];
            if (NSAppleEventDescriptor* value = [got paramDescriptorForKeyword:key]) [out setParamDescriptor:value forKeyword:key];
          }
        }
      }
      [manager resumeWithSuspensionID:suspension];
    });
  });
}
@end
