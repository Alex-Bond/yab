static unsigned nativeSourcesCallbackDepth=0;
struct NativeSourcesCallbackScope {
  NativeSourcesCallbackScope(){++nativeSourcesCallbackDepth;}
  ~NativeSourcesCallbackScope(){--nativeSourcesCallbackDepth;}
};
// Partial native metadata admission only. The acceptance policy is immutable
// compiled source and intentionally has no issuer. CLI/DTO/env cannot populate it.
namespace native_group_sources_policy {
struct Policy { int version=0; const char* sdkFrameworkSHA=""; const char* sourceManifestSHA=""; };
static constexpr Policy Current() { return {}; }
}
static bool NativeGroupSourcesAvailable() {
#if YABCORE_NATIVE_GROUP_SOURCES
  constexpr auto policy=native_group_sources_policy::Current();
  // An actual future issuer must bind the original loaded SDK, signed helper
  // and exact native acceptance; an arbitrary nonempty DTO is not that issuer.
  return policy.version==1 && policy.sdkFrameworkSHA[0] && policy.sourceManifestSHA[0] &&
      nativeSwitchConnected && nativeSwitchOwner && original_caller::Ready();
#else
  return false;
#endif
}
static bool NativeSourceAuthorityAction(NSString* action) {
  return [@[@"sources",@"prepare",@"drain",@"seal",@"validate"] containsObject:action];
}
static bool NativeSourceSequence(::id value) {
  if(!SwitchString(value,20))return false;
  const char* text=[value UTF8String];uint64_t number=0;
  if(!text||!*text||*text=='0')return false;
  for(;*text;++text) {if(*text<'0'||*text>'9'||number>(UINT64_MAX-(*text-'0'))/10)return false;number=number*10+(*text-'0');}
  return number>0;
}
static bool NativeSourceMetadata(NSDictionary* value,NSString* action) {
  if(!value||!SwitchInt(value[@"nativeSourcesVersion"])||[value[@"nativeSourcesVersion"] intValue]!=1||
      !SwitchBool(value[@"nativeSourcesCurrentAtReply"],true)||!SwitchBool(value[@"fullImageLease"],false)||
      !SwitchString(value[@"sourceReceipt"])||!NativeSourceSequence(value[@"nativeTreeSequence"])||
      !NativeSourceSequence(value[@"nativePhaseSequence"])||!NativeSourceSequence(value[@"nativeOperationSequence"]))return false;
  if([action isEqual:@"sources"]&&(!SwitchBool(value[@"available"],true)||
      ![value[@"frames"] isKindOfClass:NSArray.class]||![value[@"frames"] count]||[value[@"frames"] count]>4096))return false;
  return true; // Native private ticket, not these dictionary fields, is authority.
}
