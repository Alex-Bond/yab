// Partial original-approval adapter; snapshot controls require a separate accepted opt-in.
// No commit route or production engine-switch authority.
// Actual native authority is one CEF object per original authenticated peer.
#if YABCORE_NATIVE_GROUP_APPROVAL_API
struct NativeSwitchMember {
  std::string tab, profile, document;
  int browserId = 0;
  uint64_t generation = 0;
  bool privateMode = false;
  CefRefPtr<CefBrowser> browser;
  CefRefPtr<CefClient> client;
  CefRefPtr<CefRequestContext> context;
};
struct NativeGroupSnapshotWork;
struct NativeSwitchEntry {
  NSString* correlation = nil;
  NSString* transaction = nil;
  NSString* group = nil;
  NSString* recovery = nil;
  std::vector<NativeSwitchMember> members;
  int coordinator = 0;
  uint64_t mutation = 0;
  bool uncertain = false, retired = false, captureStarted = false;
  bool sourceBound = false;
  NSString *sourceReceipt = nil, *nativeTreeSequence = nil, *nativePhaseSequence = nil, *nativeOperationSequence = nil;
  std::shared_ptr<group_snapshot::Budget::Credit> captureCredit;
  std::string snapshotStream;
};
struct NativeSwitchPending {
  std::shared_ptr<NativeSwitchEntry> entry;
  NSString* command = nil;
  NSString* action = nil;
  NSString* wire = nil;
  uint64_t mutation = 0;
  bool completed = false;
  std::shared_ptr<NativeGroupSnapshotWork> snapshotWork;
};
static CefRefPtr<CefExternalSwitchGroupOwner> nativeSwitchOwner;
static NSString* nativeSwitchOwnerLabel = nil;
static bool nativeSwitchConnected = false;
#if YABCORE_NATIVE_GROUP_APPROVAL
static bool nativeSwitchHelloSeen = false;
#endif
// Non-evicting and bounded. Process exit is unknown, never a destructor cancel.
static auto& NativeSwitchLedger() {
  static auto* ledger = new std::map<std::string, std::shared_ptr<NativeSwitchEntry>>;
  return *ledger;
}
static std::map<std::string, std::shared_ptr<NativeSwitchPending>> nativeSwitchPending;
static std::set<std::string> nativeSwitchSeen;
static bool SwitchString(::id value, NSUInteger maximum = 256) {
  if (![value isKindOfClass:NSString.class] || ![value length]) return false;
  NSUInteger bytes = [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
  return bytes && bytes <= maximum && [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
}
static bool SwitchInt(::id value, int minimum = 1) {
  if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return false;
  const double number = [value doubleValue];
  return std::isfinite(number) && std::trunc(number) == number && number >= minimum && number <= INT_MAX;
}
static bool SwitchBool(::id value, bool expected) {
  return value && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() && [value boolValue] == expected;
}
static bool SwitchCurrent(const NativeSwitchMember& member) {
  auto tab = tabs.find(member.tab); auto profile = profiles.find(member.profile);
  if (tab == tabs.end() || profile == profiles.end()) return false;
  const auto& original = tab->second;
  if (!original.browser || !original.browser->IsValid() || original.browser.get() != member.browser.get() ||
      original.profile != member.profile || original.closing || original.crashed || !original.adopted || original.internal ||
      original.documentGeneration != member.generation || profile->second.privateMode != member.privateMode ||
      !profile->second.context || !member.context || !member.client || !profile->second.context->IsSame(member.context) ||
      original.browser->GetIdentifier() != member.browserId) return false;
  auto host = original.browser->GetHost();
  if (!host || host->GetClient().get() != member.client.get()) return false;
  auto context = host->GetRequestContext();
  if (!context || !context->IsSame(member.context)) return false;
  auto state = host->GetNativeCaptureState();
  return state && state->GetBool("known") && state->GetString("primaryDocument").ToString() == member.document;
}
static bool SwitchCurrent(const std::shared_ptr<NativeSwitchEntry>& entry) {
  return std::all_of(entry->members.begin(), entry->members.end(), [](const auto& member) { return SwitchCurrent(member); });
}
static NSArray* SwitchMembers(const std::shared_ptr<NativeSwitchEntry>& entry) {
  NSMutableArray* rows = [NSMutableArray new];
  for (const auto& member : entry->members)
    [rows addObject:@{@"tab": @(member.tab.c_str()), @"profile": @(member.profile.c_str()),
      @"document": @(member.document.c_str()), @"browserId": @(member.browserId)}];
  return rows;
}
[[maybe_unused]] static bool SwitchMemberParameters(const std::shared_ptr<NativeSwitchEntry>& entry, NSDictionary* parameters) {
  NSArray* rows = [parameters[@"members"] isKindOfClass:NSArray.class] ? parameters[@"members"] : nil;
  if (rows.count != entry->members.size() || !rows.count) return false;
  std::set<std::string> seen;
  for (::id item in rows) {
    if (![item isKindOfClass:NSDictionary.class] || !seen.insert(Key(S(item, @"tab"))).second) return false;
    bool found = false;
    for (const auto& member : entry->members)
      if ([S(item, @"tab") isEqual:@(member.tab.c_str())] && [S(item, @"profile") isEqual:@(member.profile.c_str())] &&
          [S(item, @"document") isEqual:@(member.document.c_str())]) found = true;
    if (!found) return false;
  }
  return true;
}
static bool SwitchReceipt(const std::shared_ptr<NativeSwitchEntry>& entry, NSDictionary* receipt) {
  if (!SwitchInt(receipt[@"version"]) || [receipt[@"version"] intValue] != 1 ||
      ![S(receipt, @"owner") isEqual:nativeSwitchOwnerLabel] || ![S(receipt, @"transaction") isEqual:entry->transaction] ||
      !SwitchString(receipt[@"group"]) || !SwitchString(receipt[@"recoveryToken"]) ||
      !SwitchBool(receipt[@"exclusiveNativeApprovals"], true) || !SwitchBool(receipt[@"commitAvailable"], false) ||
      !SwitchBool(receipt[@"nativeAtomicSwitchCommit"], false)) return false;
  if (entry->group && (![entry->group isEqual:S(receipt, @"group")] || ![entry->recovery isEqual:S(receipt, @"recoveryToken")])) return false;
  NSArray* rows = [receipt[@"members"] isKindOfClass:NSArray.class] ? receipt[@"members"] : nil;
  if (!rows.count || rows.count != entry->members.size()) return false;
  std::set<int> seen;
  for (::id item in rows) {
    if (![item isKindOfClass:NSDictionary.class] || !SwitchInt(item[@"browserId"]) || !seen.insert([item[@"browserId"] intValue]).second) return false;
    bool found = false;
    for (const auto& member : entry->members)
      if ([item[@"browserId"] intValue] == member.browserId && [S(item, @"document") isEqual:@(member.document.c_str())]) found = true;
    if (!found) return false;
  }
  return true;
}
#include "native_group_sources.inc"
static void NativeSnapshotRetired(const std::shared_ptr<NativeSwitchEntry>&);
static void NativeSnapshotUnknown(const std::shared_ptr<NativeSwitchPending>&);
static NSDictionary* NativeSnapshotDescriptor(const std::shared_ptr<NativeSwitchEntry>&, NSDictionary*);
static void CompleteSwitch(const std::shared_ptr<NativeSwitchPending>& pending, NSDictionary* native, NSString* source) {
  const auto entry = pending->entry;
  bool exact = native && SwitchInt(native[@"version"]) && [native[@"version"] intValue] == 1 &&
    [S(native, @"command") isEqual:pending->command] && [S(native, @"action") isEqual:pending->action];
  NSDictionary* receipt = native;
  if ([pending->action isEqual:@"inspect-owner"]) {
    exact &= [S(native, @"owner") isEqual:nativeSwitchOwnerLabel] && [native[@"groups"] isKindOfClass:NSArray.class];
    receipt = nil;
    if (exact) for (::id item in native[@"groups"]) {
      if (![item isKindOfClass:NSDictionary.class]) { exact = false; break; }
      if ([S(item, @"transaction") isEqual:entry->transaction]) {
        if (receipt) { exact = false; break; }
        receipt = item;
      }
    }
  }
  exact = exact && SwitchReceipt(entry, receipt);
  const bool sourceMetadata = entry->sourceBound && NativeSourceAuthorityAction(pending->action);
  if (sourceMetadata) exact = exact && NativeSourceMetadata(receipt, pending->action);

  if (exact) {
    // A late real callback may bind a lost first reply, never send a second one
    // or recreate the group. Retirement is monotonic, not a cached approval.
    if (!entry->group) { entry->group = S(receipt, @"group"); entry->recovery = S(receipt, @"recoveryToken"); }
    if (SwitchBool(receipt[@"recoveryRetired"], true) && SwitchBool(receipt[@"processOwned"], false)) {
      entry->retired = true; NativeSnapshotRetired(entry);
    }
  }
  if (pending->completed) return;
  pending->completed = true; nativeSwitchPending.erase(Key(pending->command));
  const bool current = SwitchCurrent(entry), operation = pending->mutation == entry->mutation;
  const bool originalCaller = original_caller::Ready();
  if (sourceMetadata && !(current && operation && originalCaller)) exact = false;
  if (sourceMetadata && exact && current && operation && originalCaller) {
    entry->sourceReceipt = S(receipt,@"sourceReceipt");
    entry->nativeTreeSequence = S(receipt,@"nativeTreeSequence");
    entry->nativePhaseSequence = S(receipt,@"nativePhaseSequence");
    entry->nativeOperationSequence = S(receipt,@"nativeOperationSequence");
  }
  if (!exact || !current || !operation || !originalCaller) {
    entry->uncertain = true;
    NativeSnapshotUnknown(pending);
  }
  NSMutableDictionary* result = [@{@"version": @1, @"command": pending->command, @"action": pending->action,
    @"transaction": entry->correlation, @"nativeTransaction": entry->transaction, @"helperOwner": nativeSwitchOwnerLabel,
    @"members": SwitchMembers(entry), @"nativeAcknowledged": @(exact), @"resultSource": source,
    @"currentOriginalsVerified": @(current), @"operationCurrent": @(operation),
    @"status": exact ? @"observed" : @"unknown", @"commitAvailable": @NO, @"nativeAtomicSwitchCommit": @NO} mutableCopy];
  if (exact) result[@"nativeReceipt"] = receipt;
  if (exact) if (NSDictionary* snapshot = NativeSnapshotDescriptor(entry, receipt)) result[@"snapshot"] = snapshot;
  NSString* wire = pending->wire; pending->wire = nil;
  if (nativeSwitchConnected && originalCaller) Reply(wire, result);
}
#include "native_group_snapshot.inc"
class NativeSwitchDone final : public CefExternalSwitchGroupCallback {
  std::shared_ptr<NativeSwitchPending> pending_;
  std::shared_ptr<group_snapshot::Budget::Credit> captureCredit_;
 public:
  explicit NativeSwitchDone(std::shared_ptr<NativeSwitchPending> pending)
      : pending_(std::move(pending)), captureCredit_(pending_->entry->captureCredit) {}
  ~NativeSwitchDone() override {
    // Hold through the SDK caller's result/stack destruction as well as ours.
    auto credit = captureCredit_;
    if (credit) dispatch_async(dispatch_get_main_queue(), ^{ (void)credit; });
  }
  void OnExternalSwitchGroupResult(CefRefPtr<CefDictionaryValue> result) override {
    if (pending_->entry->sourceBound && NativeSourceAuthorityAction(pending_->action)) {
      // This native callback is itself posted only AFTER native terminal state
      // and a fresh actual whole-tree/task recheck. No escaping CEF reference or
      // later GCD block may turn that point-in-time observation into authority.
      NativeCloseScope originalCallbackScope;
      NativeSourcesCallbackScope metadataScope;
      NSDictionary* native = result && !result->HasKey("captures") ? NativeDictionary(result) : nil;
      NSData* bytes = native ? [NSJSONSerialization dataWithJSONObject:native options:0 error:nil] : nil;
      if (!bytes || bytes.length > 3 * 1024 * 1024) native = nil;
      CompleteSwitch(pending_, native, @"native-original-sources");
      return;
    }
    if ([pending_->action isEqual:@"capture"]) { NativeSnapshotConsume(pending_, result); return; }
    // Do not serialize unsupported snapshots or mutate any native object from
    // the callback stack. The accepted wire supports metadata/approvals only.
    NSDictionary* native = result && !result->HasKey("frames") && !result->HasKey("captures") ? NativeDictionary(result) : nil;
    NSData* bytes = native ? [NSJSONSerialization dataWithJSONObject:native options:0 error:nil] : nil;
    if (!bytes || bytes.length > 3 * 1024 * 1024) native = nil; // Reject whole; never truncate a snapshot.
    auto pending = pending_;
    dispatch_async(dispatch_get_main_queue(), ^{ CompleteSwitch(pending, native, @"native"); });
  }
  IMPLEMENT_REFCOUNTING(NativeSwitchDone);
};
#endif

#if !YABCORE_NATIVE_GROUP_APPROVAL_API
static bool NativeGroupSourcesAvailable() { return false; }
#endif
static bool NativeSwitchApprovalsAvailable() {
#if YABCORE_NATIVE_GROUP_APPROVAL
  return nativeSwitchConnected && nativeSwitchOwner && original_caller::Ready();
#else
  return false;
#endif
}
static bool NativeSnapshotsAvailable() {
#if YABCORE_NATIVE_GROUP_SNAPSHOTS
  return NativeSwitchApprovalsAvailable() && nativeSnapshotPID == getpid() &&
    !nativeSnapshotBirthSec.empty() && !nativeSnapshotConnection.empty();
#else
  return false;
#endif
}
static NSDictionary* NativeSnapshotPeerIdentity() {
#if YABCORE_NATIVE_GROUP_SNAPSHOTS
  if (NativeSnapshotsAvailable()) return @{@"helperPID": @(nativeSnapshotPID), @"helperBirthSec": @(nativeSnapshotBirthSec.c_str()),
    @"helperBirthUsec": @(nativeSnapshotBirthUsec), @"connection": @(nativeSnapshotConnection.c_str()), @"helperOwner": nativeSwitchOwnerLabel};
#endif
  return @{};
}
static void NativeSwitchGroupsHello() {
#if YABCORE_NATIVE_GROUP_APPROVAL
  if (nativeSwitchHelloSeen) return; // Even factory-null cannot grant a replacement peer a later owner.
  nativeSwitchHelloSeen = true;
  if (!original_caller::Ready()) return;
  nativeSwitchOwner = CefCreateExternalSwitchGroupOwner();
  if (!nativeSwitchOwner) return;
  nativeSwitchOwnerLabel = NSUUID.UUID.UUIDString.lowercaseString;
  nativeSwitchConnected = true;
  NativeSnapshotHello();
#endif
}
static void NativeSwitchGroupsDisconnected() {
#if YABCORE_NATIVE_GROUP_APPROVAL_API
  nativeSwitchConnected = false;
  NativeSnapshotDisconnect();
  for (auto& [key, entry] : NativeSwitchLedger()) entry->uncertain = true;
  for (auto& [key, pending] : nativeSwitchPending) pending->wire = nil;
  // No cancel/retire/recreate/force-close on lost transport. Registry/process
  // death remains unknown and needs the future durable coordinator journal.
#endif
}
static bool NativeSwitchGroupRequest(NSString* method, NSDictionary* parameters, NSString* request) {
#if YABCORE_NATIVE_GROUP_APPROVAL_API
  if (NativeSnapshotRequest(method, parameters, request)) return true;
#endif
  const bool sourceRequest = [method isEqual:@"switch.group.sources"];
  if (!sourceRequest && ![method isEqual:@"switch.group.native"]) return false;
#if YABCORE_NATIVE_GROUP_APPROVAL_API
  if (nativeSourcesCallbackDepth) { Reply(request,nil,@"Native metadata completion cannot be reentered"); return true; }
#endif
  if (sourceRequest && !NativeGroupSourcesAvailable()) {
    Reply(request,nil,@"Native original source observation is not accepted"); return true;
  }
#if YABCORE_NATIVE_GROUP_APPROVAL
  NSString* action = sourceRequest ? @"sources" : S(parameters, @"action"), *command = S(parameters, @"command"), *correlation = S(parameters, @"transaction");
  const bool reserve = [action isEqual:@"reserve"];
  const bool recovery = [@[@"inspect", @"inspect-owner", @"cancel", @"detach", @"retire"] containsObject:action];
  if (!nativeSwitchConnected || !nativeSwitchOwner || !original_caller::Ready() || parameters[@"owner"] || parameters[@"nativeOwner"] ||
      ![@[@"reserve", @"sources", @"prepare", @"drain", @"seal", @"capture", @"validate", @"inspect", @"inspect-owner", @"cancel", @"detach", @"retire"] containsObject:action] ||
      !SwitchString(command, 128) || !SwitchString(correlation, 128) ||
      nativeSwitchPending.size() >= 32 || nativeSwitchSeen.size() >= 4096 || nativeSwitchSeen.count(Key(command))) {
    Reply(request, nil, @"Native original group authority unavailable, repeated or bounded"); return true;
  }
  if ([@[@"drain", @"seal", @"capture"] containsObject:action] && !NativeSnapshotsAvailable()) {
    Reply(request, nil, @"Native partial snapshot transport is unavailable"); return true;
  }
  auto found = NativeSwitchLedger().find(Key(correlation));
  std::shared_ptr<NativeSwitchEntry> entry;
  if (reserve) {
    if (found != NativeSwitchLedger().end() || NativeSwitchLedger().size() >= 256 ||
        ![parameters[@"members"] isKindOfClass:NSArray.class] || ![parameters[@"members"] count] || [parameters[@"members"] count] > 256) {
      Reply(request, nil, @"Original transaction already exists or has invalid members; inspect-owner instead of retry"); return true;
    }
    entry = std::make_shared<NativeSwitchEntry>(); entry->correlation = correlation; entry->transaction = NSUUID.UUID.UUIDString.lowercaseString;
    std::set<std::string> seen;
    for (::id item in parameters[@"members"]) {
      if (![item isKindOfClass:NSDictionary.class] || !SwitchString(item[@"tab"]) || !SwitchString(item[@"profile"]) ||
          !SwitchString(item[@"document"]) || !seen.insert(Key(S(item, @"tab"))).second) { Reply(request, nil, @"Invalid original member"); return true; }
      auto tab = tabs.find(Key(S(item, @"tab"))); auto profile = profiles.find(Key(S(item, @"profile")));
      if (tab == tabs.end() || profile == profiles.end() || !tab->second.browser) { Reply(request, nil, @"Original member missing"); return true; }
      NativeSwitchMember member; member.tab = tab->first; member.profile = profile->first; member.document = Key(S(item, @"document"));
      member.browser = tab->second.browser; member.browserId = member.browser->GetIdentifier();
      member.generation = tab->second.documentGeneration; member.privateMode = profile->second.privateMode;
      auto host = member.browser->IsValid() ? member.browser->GetHost() : nullptr;
      if (!host) { Reply(request, nil, @"Original native host retired"); return true; }
      member.client = host->GetClient(); member.context = profile->second.context;
      if (!SwitchCurrent(member)) { Reply(request, nil, @"Original native document/client/profile changed"); return true; }
      if ([S(parameters, @"coordinator") isEqual:@(member.tab.c_str())]) entry->coordinator = member.browserId;
      entry->members.push_back(std::move(member));
    }
    if (!entry->coordinator) { Reply(request, nil, @"Coordinator must be an exact original member"); return true; }
    NativeSwitchLedger().emplace(Key(correlation), entry); // BEFORE any native reservation/callback.
  } else {
    if (found == NativeSwitchLedger().end() || !SwitchMemberParameters(found->second, parameters)) { Reply(request, nil, @"Original transaction/member identity missing"); return true; }
    entry = found->second;
    if (![action isEqual:@"inspect-owner"] && (!entry->group || ![entry->group isEqual:S(parameters, @"group")] ||
        ![entry->recovery isEqual:S(parameters, @"recoveryToken")])) { Reply(request, nil, @"Original native group/token mismatch"); return true; }
    if (!recovery && (entry->retired || entry->uncertain || !SwitchCurrent(entry))) { Reply(request, nil, @"Original native group needs recovery"); return true; }
  }
  if ([action isEqual:@"sources"] && (!sourceRequest || !NativeGroupSourcesAvailable())) {
    Reply(request,nil,@"Sources require the dedicated original-policy route"); return true;
  }
  if (parameters[@"sourceReceipt"] || parameters[@"nativeTreeSequence"] || parameters[@"nativePhaseSequence"] || parameters[@"nativeOperationSequence"] ||
      parameters[@"sources"] || parameters[@"frames"] || parameters[@"originalProcess"]) {
    Reply(request,nil,@"Native source authority cannot be supplied by an endpoint"); return true;
  }
  if (entry->sourceBound && [action isEqual:@"capture"]) {
    // The existing deferred binary snapshot lane has no sources-delivery lease.
    // Do not silently promote it; this bounded packet admits metadata only.
    Reply(request,nil,@"Sources-bound binary capture transport is not accepted"); return true;
  }
  if (entry->sourceBound && NativeSourceAuthorityAction(action) && !NativeGroupSourcesAvailable()) {
    Reply(request,nil,@"Original source policy retired"); return true;
  }
  // Recovery still rechecks current native identities, but global native lookup
  // may inspect original records after browser destruction without dead hosts.
  (void)SwitchCurrent(entry);
  const bool mutation = reserve || [@[@"sources", @"prepare", @"drain", @"seal", @"capture", @"cancel", @"detach", @"retire"] containsObject:action];
  if (mutation && entry->mutation == UINT64_MAX) { entry->uncertain = true; Reply(request, nil, @"Original operation counter exhausted"); return true; }
  if (mutation) {
    ++entry->mutation;
    if (![action isEqual:@"capture"]) NativeSnapshotInvalidate(entry);
  }
  auto pending = std::make_shared<NativeSwitchPending>(); pending->entry = entry; pending->command = command;
  pending->action = action; pending->wire = request; pending->mutation = entry->mutation;
  if ([action isEqual:@"capture"] && !NativeSnapshotBegin(pending)) {
    Reply(request, nil, @"Original capture already started or resource credit unavailable"); return true;
  }
  auto native = CefDictionaryValue::Create(); native->SetInt("version", 1); native->SetString("command", Key(command));
  native->SetString("action", Key(action)); native->SetString("owner", Key(nativeSwitchOwnerLabel));
  if (reserve) {
    native->SetString("transaction", Key(entry->transaction)); native->SetInt("coordinator", entry->coordinator);
    auto members = CefListValue::Create();
    for (size_t index = 0; index < entry->members.size(); ++index) {
      auto item = CefDictionaryValue::Create(); item->SetInt("browserId", entry->members[index].browserId);
      item->SetString("document", entry->members[index].document); members->SetDictionary(index, item);
    }
    native->SetList("members", members);
  } else if (![action isEqual:@"inspect-owner"]) {
    native->SetString("group", Key(entry->group)); native->SetString("recoveryToken", Key(entry->recovery));
  }
  if ([action isEqual:@"sources"]) entry->sourceBound = true; // BEFORE native dispatch, including lost first reply.
  if (entry->sourceBound && NativeSourceAuthorityAction(action) && entry->sourceReceipt) {
    native->SetString("sourceReceipt",Key(entry->sourceReceipt));
    native->SetString("nativeTreeSequence",Key(entry->nativeTreeSequence));
    native->SetString("nativePhaseSequence",Key(entry->nativePhaseSequence));
    native->SetString("nativeOperationSequence",Key(entry->nativeOperationSequence));
  }
  nativeSwitchSeen.insert(Key(command)); nativeSwitchPending.emplace(Key(command), pending);
  requests[Key(request)] = Now() + 45; // Native deadline30s < helper40s < client60s.
  if (!CefSendExternalSwitchGroup(nativeSwitchOwner, native, new NativeSwitchDone(pending)))
    CompleteSwitch(pending, nil, @"native-dispatch-rejected");
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 40 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    CompleteSwitch(pending, nil, @"helper-timeout"); // No native cancellation or retry.
  });
#else
  (void)parameters;
  Reply(request, nil, @"Native original group approvals are unavailable");
#endif
  return true;
}
