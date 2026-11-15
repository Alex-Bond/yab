// Included after the original approval matcher; metadata/bytes only off-UI.
struct NativeGroupSnapshotWork {
  std::shared_ptr<group_snapshot::Budget::Credit> credit;
  std::shared_ptr<const std::string> payload;
  std::shared_ptr<group_snapshot::ImmutableFile> file;
  std::string stream, correlation, connection, owner, captureCommand;
  std::string descriptorJSON, metadataJSON, temporaryDirectory;
  uint64_t mutation = 0;
  std::atomic<bool> consumed{false}, retired{false}, reading{false};
};
struct NativeGroupSnapshotRecord {
  std::shared_ptr<NativeGroupSnapshotWork> work;
  NSDictionary* descriptor = nil;
  bool ready = false;
};
static group_snapshot::Budget nativeSnapshotBudget;
static std::map<std::string, std::shared_ptr<NativeGroupSnapshotRecord>> nativeSnapshots;
static std::string nativeSnapshotConnection, nativeSnapshotBirthSec;
static uint32_t nativeSnapshotBirthUsec = 0;
static int nativeSnapshotPID = 0;
static NSString* SnapshotHash(const std::string& bytes) {
  unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(bytes.data(), static_cast<CC_LONG>(bytes.size()), digest);
  std::string output; const char* hex = "0123456789abcdef";
  for (auto byte : digest) { output.push_back(hex[byte >> 4]); output.push_back(hex[byte & 15]); }
  return @(output.c_str());
}
static std::string SnapshotJSON(::id value) {
  NSData* bytes = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];
  return bytes ? std::string(static_cast<const char*>(bytes.bytes), bytes.length) : std::string();
}
static bool SnapshotPeer(const std::shared_ptr<NativeGroupSnapshotWork>& work) {
  return nativeSwitchConnected && nativeSwitchOwner && original_caller::Ready() && work->connection == nativeSnapshotConnection &&
    work->owner == Key(nativeSwitchOwnerLabel) && !work->retired.load();
}
static void NativeSnapshotHello() {
#if YABCORE_NATIVE_GROUP_SNAPSHOTS
  proc_bsdinfo info{};
  if (proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info) ||
      info.pbi_pid != static_cast<uint32_t>(getpid()) || info.pbi_uid != getuid() || !info.pbi_start_tvsec) return;
  nativeSnapshotPID = getpid(); nativeSnapshotBirthSec = std::to_string(info.pbi_start_tvsec);
  nativeSnapshotBirthUsec = info.pbi_start_tvusec;
  nativeSnapshotConnection = Key(NSUUID.UUID.UUIDString.lowercaseString);
#endif
}
static void NativeSnapshotInvalidate(const std::shared_ptr<NativeSwitchEntry>& entry) {
  auto found = nativeSnapshots.find(entry->snapshotStream);
  if (found != nativeSnapshots.end()) {
    found->second->work->retired.store(true);
    nativeSnapshots.erase(found); // Work/callback/FD/readers still own their credits.
  }
  entry->snapshotStream.clear();
}
static void NativeSnapshotRetired(const std::shared_ptr<NativeSwitchEntry>& entry) {
  NativeSnapshotInvalidate(entry);
  // Only actual native recoveryRetired=true/processOwned=false refunds THIS
  // hold. Callback/writer/FD/read-buffer holds can keep it charged longer.
  entry->captureCredit.reset();
}
static void NativeSnapshotUnknown(const std::shared_ptr<NativeSwitchPending>& pending) {
  if (pending->snapshotWork) pending->snapshotWork->retired.store(true);
  NativeSnapshotInvalidate(pending->entry);
}
static void NativeSnapshotDisconnect() {
  for (auto& [key, record] : nativeSnapshots) record->work->retired.store(true);
  nativeSnapshots.clear(); // No native cancellation/retirement; no credit refund.
}
static NSDictionary* NativeSnapshotDescriptor(const std::shared_ptr<NativeSwitchEntry>& entry, NSDictionary* receipt) {
  auto found = nativeSnapshots.find(entry->snapshotStream);
  if (found == nativeSnapshots.end() || !found->second->ready || !SnapshotPeer(found->second->work) ||
      entry->uncertain || entry->retired || entry->mutation != found->second->work->mutation) return nil;
  NSDictionary* descriptor = found->second->descriptor;
  return [S(descriptor, @"group") isEqual:S(receipt, @"group")] &&
    [S(descriptor, @"seal") isEqual:S(receipt, @"seal")] && [S(descriptor, @"snapshot") isEqual:S(receipt, @"snapshot")] ? descriptor : nil;
}
static bool NativeSnapshotBegin(const std::shared_ptr<NativeSwitchPending>& pending) {
  auto entry = pending->entry;
  if (entry->captureStarted || !entry->group || !NativeSnapshotsAvailable()) return false;
  auto credit = nativeSnapshotBudget.Acquire(entry.get());
  if (!credit) return false;
  auto work = std::make_shared<NativeGroupSnapshotWork>(); work->credit = credit;
  work->stream = Key(NSUUID.UUID.UUIDString.lowercaseString); work->correlation = Key(entry->correlation);
  work->connection = nativeSnapshotConnection; work->owner = Key(nativeSwitchOwnerLabel);
  work->captureCommand = Key(pending->command); work->mutation = pending->mutation;
  work->temporaryDirectory = Key(NSTemporaryDirectory());
  auto record = std::make_shared<NativeGroupSnapshotRecord>(); record->work = work;
  nativeSnapshots.emplace(work->stream, record);
  entry->captureStarted = true; entry->captureCredit = std::move(credit); entry->snapshotStream = work->stream;
  pending->snapshotWork = work;
  return true;
}
static bool SnapshotTopology(NSArray* frames, const std::shared_ptr<NativeSwitchEntry>& entry, NSMutableArray* topology) {
  if (!frames.count || frames.count > 512) return false;
  std::set<std::pair<int, int>> seen;
  std::map<std::pair<int, int>, std::pair<int, int>> parents;
  std::map<std::pair<int, int>, int> browsers;
  std::set<int> mains;
  for (::id value in frames) {
    if (![value isKindOfClass:NSDictionary.class] || !SwitchInt(value[@"browserId"]) || !SwitchInt(value[@"processId"]) ||
        !SwitchInt(value[@"routingId"]) || !SwitchString(value[@"document"]) || ![value[@"state"] isKindOfClass:NSDictionary.class] ||
        (!SwitchBool(value[@"main"], true) && !SwitchBool(value[@"main"], false))) return false;
    int browser = [value[@"browserId"] intValue]; bool matched = false;
    for (const auto& member : entry->members) if (member.browserId == browser) {
      matched = true;
      if (SwitchBool(value[@"main"], true) && ![S(value, @"document") isEqual:@(member.document.c_str())]) return false;
    }
    if (!matched) return false;
    auto id = std::make_pair([value[@"processId"] intValue], [value[@"routingId"] intValue]);
    if (!seen.insert(id).second) return false;
    browsers[id] = browser;
    NSMutableDictionary* row = [@{@"browserId": value[@"browserId"], @"processId": value[@"processId"],
      @"routingId": value[@"routingId"], @"document": value[@"document"], @"main": value[@"main"]} mutableCopy];
    if (SwitchBool(value[@"main"], true)) {
      if (!mains.insert(browser).second || value[@"parentProcessId"] || value[@"parentRoutingId"]) return false;
    } else {
      if (!SwitchInt(value[@"parentProcessId"]) || !SwitchInt(value[@"parentRoutingId"])) return false;
      parents[id] = {[value[@"parentProcessId"] intValue], [value[@"parentRoutingId"] intValue]};
      row[@"parentProcessId"] = value[@"parentProcessId"]; row[@"parentRoutingId"] = value[@"parentRoutingId"];
    }
    [topology addObject:row];
  }
  if (mains.size() != entry->members.size()) return false;
  for (const auto& [id, parent] : parents) {
    auto at = id; std::set<std::pair<int, int>> chain;
    while (parents.count(at)) {
      if (!chain.insert(at).second || !seen.count(parents.at(at)) || browsers.at(parents.at(at)) != browsers.at(id)) return false;
      at = parents.at(at);
    }
  }
  [topology sortUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
    NSComparisonResult process = [a[@"processId"] compare:b[@"processId"]];
    return process == NSOrderedSame ? [a[@"routingId"] compare:b[@"routingId"]] : process;
  }];
  return true;
}
static void SnapshotPublished(const std::shared_ptr<NativeGroupSnapshotWork>& work) {
  auto found = nativeSwitchPending.find(work->captureCommand);
  if (found == nativeSwitchPending.end()) { work->retired.store(true); return; }
  auto pending = found->second; auto entry = pending->entry;
  if (!work->file || !SnapshotPeer(work) || pending->completed || entry->uncertain || entry->retired ||
      entry->mutation != work->mutation || !SwitchCurrent(entry)) {
    work->retired.store(true); CompleteSwitch(pending, nil, @"snapshot-unknown"); return;
  }
  auto record = nativeSnapshots.find(work->stream);
  if (record == nativeSnapshots.end() || record->second->work != work) { CompleteSwitch(pending, nil, @"snapshot-retired"); return; }
  NSDictionary* descriptor = Decode(work->descriptorJSON.data(), work->descriptorJSON.size());
  NSDictionary* metadata = Decode(work->metadataJSON.data(), work->metadataJSON.size());
  record->second->descriptor = descriptor; record->second->ready = true;
  CompleteSwitch(pending, metadata, @"native");
}
static void NativeSnapshotConsume(const std::shared_ptr<NativeSwitchPending>& pending, CefRefPtr<CefDictionaryValue> result) {
  auto work = pending->snapshotWork;
  if (!work || work->consumed.exchange(true)) { if (work) work->retired.store(true); return; }
  if (work->retired.load()) return;
  @autoreleasepool {
    // The ONLY SDK-result read. CEF values/strings are consumed synchronously;
    // no CefRefPtr or SDK-owned buffer enters the writer queue.
    std::string bytes = result ? CefWriteJSON(result, JSON_WRITER_DEFAULT).ToString() : std::string();
    NSDictionary* full = bytes.size() <= group_snapshot::kMaximum ? Decode(bytes.data(), bytes.size()) : nil;
    NSArray* frames = [full[@"frames"] isKindOfClass:NSArray.class] ? full[@"frames"] : nil;
    NSMutableDictionary* metadata = [full mutableCopy]; [metadata removeObjectForKey:@"frames"];
    NSMutableArray* topology = [NSMutableArray new];
    bool valid = !bytes.empty() && bytes.size() <= group_snapshot::kMaximum && SwitchReceipt(pending->entry, metadata) &&
      [S(metadata, @"command") isEqual:pending->command] && [S(metadata, @"action") isEqual:@"capture"] &&
      [S(metadata, @"phase") isEqual:@"captured"] && SwitchBool(metadata[@"primitiveAccepted"], true) &&
      SwitchString(metadata[@"seal"]) && SwitchString(metadata[@"snapshot"]) && SwitchInt(metadata[@"frameCount"]) &&
      [metadata[@"frameCount"] unsignedIntegerValue] == frames.count && SnapshotTopology(frames, pending->entry, topology);
    if (!valid) {
      dispatch_async(dispatch_get_main_queue(), ^{
        auto found = nativeSwitchPending.find(work->captureCommand);
        if (found != nativeSwitchPending.end()) CompleteSwitch(found->second, nil, @"native-snapshot-rejected");
      });
      return;
    }
    NSDictionary* source = @{@"version": @1, @"helperPID": @(nativeSnapshotPID), @"helperBirthSec": @(nativeSnapshotBirthSec.c_str()),
      @"helperBirthUsec": @(nativeSnapshotBirthUsec), @"connection": @(work->connection.c_str()), @"helperOwner": @(work->owner.c_str()),
      @"nativeTransaction": pending->entry->transaction, @"group": metadata[@"group"], @"recoveryToken": metadata[@"recoveryToken"],
      @"seal": metadata[@"seal"], @"snapshot": metadata[@"snapshot"], @"members": SwitchMembers(pending->entry), @"frames": topology};
    std::string sourceJSON = SnapshotJSON(source);
    NSData* sourceBytes = [NSData dataWithBytes:sourceJSON.data() length:sourceJSON.size()];
    NSDictionary* descriptor = @{@"version": @1, @"stream": @(work->stream.c_str()), @"transaction": pending->entry->correlation,
      @"captureCommand": pending->command, @"total": @(bytes.size()), @"sha256": SnapshotHash(bytes),
      @"helperPID": source[@"helperPID"], @"helperBirthSec": source[@"helperBirthSec"], @"helperBirthUsec": source[@"helperBirthUsec"],
      @"connection": source[@"connection"], @"helperOwner": source[@"helperOwner"], @"nativeTransaction": source[@"nativeTransaction"],
      @"group": source[@"group"], @"recoveryToken": source[@"recoveryToken"], @"seal": source[@"seal"], @"snapshot": source[@"snapshot"],
      @"members": source[@"members"],
      @"sourceSHA256": SnapshotHash(sourceJSON), @"source": [sourceBytes base64EncodedStringWithOptions:0],
      @"maxChunk": @(group_snapshot::kChunk), @"immutable": @YES, @"partial": @YES,
      @"commitAvailable": @NO, @"nativeAtomicSwitchCommit": @NO};
    work->descriptorJSON = SnapshotJSON(descriptor); work->metadataJSON = SnapshotJSON(metadata);
    if (sourceJSON.empty() || sourceJSON.size() > 768 * 1024 || work->descriptorJSON.empty() ||
        work->descriptorJSON.size() > 1024 * 1024 || work->metadataJSON.empty() || work->metadataJSON.size() > 1024 * 1024) {
      dispatch_async(dispatch_get_main_queue(), ^{
        auto found = nativeSwitchPending.find(work->captureCommand);
        if (found != nativeSwitchPending.end()) CompleteSwitch(found->second, nil, @"native-snapshot-metadata-rejected");
      });
      return;
    }
    work->payload = std::make_shared<const std::string>(std::move(bytes));
  }
  static dispatch_queue_t writer = dispatch_queue_create("yab.original.snapshot.writer", DISPATCH_QUEUE_SERIAL);
  dispatch_async(writer, ^{
    // work is independent strings/bytes/RAII credit only, not native objects.
    auto payload = work->payload;
    if (payload) work->file = group_snapshot::ImmutableFile::Freeze(*payload, work->temporaryDirectory, work->credit, work->retired);
    work->payload.reset(); payload.reset();
    dispatch_async(dispatch_get_main_queue(), ^{ SnapshotPublished(work); });
  });
}
static bool NativeSnapshotRequest(NSString* method, NSDictionary* parameters, NSString* request) {
  if (![method hasPrefix:@"switch.group.snapshot."]) return false;
#if YABCORE_NATIVE_GROUP_SNAPSHOTS
  NSString* action = [method substringFromIndex:@"switch.group.snapshot.".length];
  NSDictionary* supplied = [parameters[@"descriptor"] isKindOfClass:NSDictionary.class] ? parameters[@"descriptor"] : nil;
  auto found = nativeSnapshots.find(Key(S(supplied, @"stream")));
  if (!NativeSnapshotsAvailable() || found == nativeSnapshots.end() || !found->second->ready ||
      !SnapshotPeer(found->second->work) || SnapshotJSON(supplied) != SnapshotJSON(found->second->descriptor)) {
    Reply(request, nil, @"Original immutable snapshot identity unavailable"); return true;
  }
  auto record = found->second; auto work = record->work;
  auto original = NativeSwitchLedger().find(work->correlation);
  if (original == NativeSwitchLedger().end() || original->second->snapshotStream != work->stream ||
      original->second->uncertain || original->second->retired || original->second->mutation != work->mutation || !SwitchCurrent(original->second)) {
    Reply(request, nil, @"Original snapshot source changed or became unknown"); return true;
  }
  if ([action isEqual:@"release"]) {
    NativeSnapshotInvalidate(original->second); Reply(request, @{@"released": @YES, @"nativeReleased": @NO}); return true;
  }
  if (![action isEqual:@"read"] || !SwitchInt(parameters[@"offset"], 0) || !SwitchInt(parameters[@"length"]) ||
      [parameters[@"length"] unsignedIntegerValue] > group_snapshot::kChunk) { Reply(request, nil, @"Invalid immutable snapshot range"); return true; }
  const size_t offset = [parameters[@"offset"] unsignedIntegerValue], length = [parameters[@"length"] unsignedIntegerValue];
  const size_t total = [record->descriptor[@"total"] unsignedIntegerValue];
  if (offset >= total || length > total - offset || work->reading.exchange(true)) { Reply(request, nil, @"Snapshot range or reader is unavailable"); return true; }
  auto file = work->file; auto descriptor = record->descriptor;
  static dispatch_queue_t reader = dispatch_queue_create("yab.original.snapshot.reader", DISPATCH_QUEUE_SERIAL);
  dispatch_async(reader, ^{
    auto bytes = std::make_shared<std::string>();
    bool success = file && file->Read(offset, length, *bytes, work->retired);
    dispatch_async(dispatch_get_main_queue(), ^{
      work->reading.store(false);
      auto current = NativeSwitchLedger().find(work->correlation);
      if (!SnapshotPeer(work)) return; // Never reply to a disconnected/replacement peer.
      if (!success || current == NativeSwitchLedger().end() || current->second->uncertain || current->second->retired ||
          current->second->mutation != work->mutation || !SwitchCurrent(current->second)) {
        Reply(request, nil, @"Immutable snapshot read became unknown"); return;
      }
      NSData* data = [NSData dataWithBytes:bytes->data() length:bytes->size()];
      Reply(request, @{@"descriptor": descriptor, @"offset": @(offset), @"length": @(bytes->size()),
        @"sha256": SnapshotHash(*bytes), @"data": [data base64EncodedStringWithOptions:0]});
    });
  });
#else
  (void)parameters; Reply(request, nil, @"Native partial snapshot transport is unavailable");
#endif
  return true;
}
