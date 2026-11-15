#include "original_caller.h"
#import <Security/Security.h>
#include <CommonCrypto/CommonDigest.h>
#include <libproc.h>
#include <mach/mach.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <cstring>
#include <memory>
#include <vector>
#include <atomic>
#include <functional>
#include <mutex>
#include <utility>
#include <fcntl.h>
#include <string>
#include <map>
#include <set>
#include <optional>
#include <algorithm>
#include <sys/stat.h>
#include <limits.h>
#include <poll.h>
#include <chrono>
#include <cerrno>
namespace yc::original_caller {
namespace {
struct Identity {
  Identity() = default;
  Identity(const Identity&) = delete;
  Identity& operator=(const Identity&) = delete;
  pid_t pid = 0; uint32_t parent = 0, uid = 0; uint64_t sec = 0, usec = 0;
  std::string executable, argv, boot, identifier, unique;
  NSData* audit = nil;
  SecCodeRef dynamic = nullptr;
  ~Identity() { if (dynamic) CFRelease(dynamic); }
};
class OriginalParentImagePair;
struct OwnedFD;
struct DiagnosticPolicyWork {
  NSString* ticket = NSUUID.UUID.UUIDString.lowercaseString;
  std::atomic<bool> started{false}, waiting{false}, released{false}, strictCompleted{false}, strictSucceeded{false}, finished{false}, timedOut{false};
};
struct State {
  bool observationEnabled = false;
  bool imagePolicyDiagnostic = false, diagnosticDeadline = false;
  std::shared_ptr<OwnedFD> diagnosticGate;
  std::shared_ptr<DiagnosticPolicyWork> diagnosticWork;
  bool initialSeen = false, acceptedSeen = false, helloSeen = false, live = false, lost = false;
  int connection = -1;
  bool imageLatchAttempted = false;
  std::shared_ptr<const OriginalParentImagePair> parentImagePair;
  std::shared_ptr<Identity> parent, peer, helper;
  NSString* clientNonce = nil; NSString* helperNonce = nil; NSString* reason = @"not-captured";
};
State state;
std::string Hex(const void* bytes, size_t length) {
  std::string result; const char* hex = "0123456789abcdef";
  auto p = static_cast<const unsigned char*>(bytes);
  for (size_t i = 0; i < length; ++i) { result.push_back(hex[p[i] >> 4]); result.push_back(hex[p[i] & 15]); }
  return result;
}
std::string Hash(const void* bytes, size_t length) {
  unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(bytes, static_cast<CC_LONG>(length), digest);
  return Hex(digest, sizeof(digest));
}
bool Birth(pid_t pid, proc_bsdinfo& result) {
  return pid > 0 && proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &result, sizeof(result)) == sizeof(result) &&
    result.pbi_pid == static_cast<uint32_t>(pid) && result.pbi_uid == getuid() && result.pbi_status != 5 &&
    result.pbi_start_tvsec > 0 && result.pbi_start_tvusec < 1000000;
}
bool SameBirth(const proc_bsdinfo& a, const proc_bsdinfo& b) {
  return a.pbi_pid == b.pbi_pid && a.pbi_ppid == b.pbi_ppid && a.pbi_uid == b.pbi_uid &&
    a.pbi_start_tvsec == b.pbi_start_tvsec && a.pbi_start_tvusec == b.pbi_start_tvusec;
}
bool Path(pid_t pid, std::string& result) {
  char bytes[PROC_PIDPATHINFO_MAXSIZE]{};
  if (proc_pidpath(pid, bytes, sizeof(bytes)) <= 0 || !bytes[0] || strnlen(bytes,sizeof(bytes)) == sizeof(bytes)) return false;
  result = bytes; return true;
}
bool String(const char*& at, const char* end, std::string& result) {
  if (at >= end) return false;
  auto zero = static_cast<const char*>(std::memchr(at, 0, end-at));
  if (!zero) return false;
  result.assign(at, zero); at = zero+1; return true;
}
bool Arguments(pid_t pid, std::string& result) {
  int maximum = 0, limit[] = {CTL_KERN, KERN_ARGMAX}; size_t size = sizeof(maximum);
  if (sysctl(limit, 2, &maximum, &size, nullptr, 0) || maximum <= sizeof(int) || maximum > 1024*1024) return false;
  int mib[] = {CTL_KERN, KERN_PROCARGS2, pid}; std::vector<char> bytes(maximum); size = bytes.size();
  if (sysctl(mib, 3, bytes.data(), &size, nullptr, 0) || size <= sizeof(int) || size > bytes.size()) return false;
  int count = 0; std::memcpy(&count, bytes.data(), sizeof(count)); if (count <= 0 || count > 16384) return false;
  const char* at = bytes.data()+sizeof(count); const char* end = bytes.data()+size;
  std::string kernel, encoded;
  if (!String(at, end, kernel) || kernel.empty()) return false;
  while (at < end && !*at) ++at;
  for (int i = 0; i < count; ++i) {
    std::string value; if (!String(at, end, value) || (!i && value.empty())) return false;
    encoded += value; encoded.push_back(0);
  }
  result = Hash(encoded.data(), encoded.size()); return true; // No argv/environment log or payload.
}
bool Boot(std::string& result) {
  char value[128]{}; size_t size = sizeof(value);
  if (sysctlbyname("kern.bootsessionuuid", value, &size, nullptr, 0) || !size || size > sizeof(value) || value[sizeof(value)-1]) return false;
  NSUUID* uuid = [[NSUUID alloc] initWithUUIDString:@(value)]; if (!uuid) return false;
  result = uuid.UUIDString.UTF8String; return true;
}
NSData* Token(int fd) {
  audit_token_t token{}; socklen_t size = sizeof(token);
  return getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0 && size == sizeof(token) ? [NSData dataWithBytes:&token length:size] : nil;
}
bool PeerPID(int fd, pid_t& pid) {
  uid_t uid = 0; gid_t gid = 0; socklen_t size = sizeof(pid); int type = 0; socklen_t typeSize = sizeof(type);
  sockaddr_un address{}; socklen_t addressSize = sizeof(address);
  return getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &typeSize) == 0 && type == SOCK_STREAM &&
    getsockname(fd, reinterpret_cast<sockaddr*>(&address), &addressSize) == 0 && address.sun_family == AF_UNIX &&
    getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 && size == sizeof(pid) && pid > 0 &&
    getpeereid(fd, &uid, &gid) == 0 && uid == getuid();
}
std::shared_ptr<Identity> Read(pid_t pid, NSData* audit) {
  if (!audit || audit.length != sizeof(audit_token_t)) return {};
  proc_bsdinfo first{}, last{};
  auto result = std::make_shared<Identity>(); result->audit = [audit copy];
  if (!Birth(pid, first) || !Path(pid, result->executable) || !Arguments(pid, result->argv) || !Boot(result->boot)) return {};
  NSDictionary* attributes = @{(__bridge NSString*)kSecGuestAttributeAudit: audit};
  if (SecCodeCopyGuestWithAttributes(nullptr, (__bridge CFDictionaryRef)attributes, kSecCSDefaultFlags, &result->dynamic) != errSecSuccess ||
      !result->dynamic || SecCodeCheckValidity(result->dynamic, kSecCSDefaultFlags, nullptr) != errSecSuccess) return {};
  SecStaticCodeRef disk = nullptr; CFDictionaryRef information = nullptr;
  if (SecCodeCopyStaticCode(result->dynamic, kSecCSDefaultFlags, &disk) != errSecSuccess || !disk) return {};
  OSStatus status = SecCodeCopySigningInformation(disk, kSecCSSigningInformation, &information); CFRelease(disk);
  if (status != errSecSuccess || !information) return {};
  NSDictionary* row = CFBridgingRelease(information);
  NSURL* executable = row[(__bridge NSString*)kSecCodeInfoMainExecutable];
  NSString* identifier = row[(__bridge NSString*)kSecCodeInfoIdentifier];
  NSData* unique = row[(__bridge NSString*)kSecCodeInfoUnique];
  if (![executable isKindOfClass:NSURL.class] || ![identifier isKindOfClass:NSString.class] || !identifier.length ||
      ![unique isKindOfClass:NSData.class] || !unique.length || unique.length > 64 ||
      result->executable != std::string(executable.path.UTF8String ?: "")) return {};
  result->identifier = identifier.UTF8String; result->unique = Hex(unique.bytes, unique.length);
  std::string path, argv, boot;
  if (!Birth(pid, last) || !SameBirth(first,last) || !Path(pid,path) || path != result->executable ||
      !Arguments(pid,argv) || argv != result->argv || !Boot(boot) || boot != result->boot ||
      SecCodeCheckValidity(result->dynamic, kSecCSDefaultFlags, nullptr) != errSecSuccess) return {};
  result->pid = pid; result->parent = last.pbi_ppid; result->uid = last.pbi_uid;
  result->sec = last.pbi_start_tvsec; result->usec = last.pbi_start_tvusec; return result;
}
bool Same(const std::shared_ptr<Identity>& a, const std::shared_ptr<Identity>& b) {
  return a && b && a->pid == b->pid && a->parent == b->parent && a->uid == b->uid && a->sec == b->sec && a->usec == b->usec &&
    a->executable == b->executable && a->argv == b->argv && a->boot == b->boot && a->identifier == b->identifier &&
    a->unique == b->unique && [a->audit isEqual:b->audit];
}
std::shared_ptr<Identity> Peer(int fd) {
  pid_t pid = 0, again = 0; NSData* audit = Token(fd);
  if (!audit || !PeerPID(fd,pid)) return {};
  auto result = Read(pid,audit);
  return result && PeerPID(fd,again) && again == pid && [Token(fd) isEqual:audit] ? result : nullptr;
}
std::shared_ptr<Identity> Self() {
  audit_token_t token{}; mach_msg_type_number_t count = TASK_AUDIT_TOKEN_COUNT;
  if (task_info(mach_task_self(), TASK_AUDIT_TOKEN, reinterpret_cast<task_info_t>(&token), &count) != KERN_SUCCESS || count != TASK_AUDIT_TOKEN_COUNT) return {};
  return Read(getpid(), [NSData dataWithBytes:&token length:sizeof(token)]);
}
#include "original_parent_image.inc"

// Optional proof must not strand ordinary source62 startup/UI behind code
// signing or process introspection. One bounded worker; any deadline/close
// uncertainty permanently disables auth. Late work cannot mutate state.
std::atomic<bool> authUnavailable{false};
struct OwnedFD {
  int fd;
  explicit OwnedFD(int value) : fd(value) {}
  ~OwnedFD() { if (close(fd) != 0) authUnavailable.store(true); } // Never retry reused FD.
};
std::shared_ptr<Identity> Bounded(std::function<std::shared_ptr<Identity>()> operation) {
  if (authUnavailable.load()) return {};
  struct Work { std::shared_ptr<Identity> result; std::atomic<bool> done{false}; };
  auto work = std::make_shared<Work>(); auto semaphore = dispatch_semaphore_create(0);
  static dispatch_queue_t queue = dispatch_queue_create("yab.original.caller.proof",DISPATCH_QUEUE_SERIAL);
  dispatch_async(queue, ^{
    @autoreleasepool { work->result = operation(); work->done.store(true); dispatch_semaphore_signal(semaphore); }
  });
  if (dispatch_semaphore_wait(semaphore,dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC)) != 0 || !work->done.load()) {
    authUnavailable.store(true); return {};
  }
  return work->result;
}
std::shared_ptr<Identity> BoundedPeer(int fd) {
  if (authUnavailable.load()) return {};
  int copy = fcntl(fd,F_DUPFD_CLOEXEC,0); if (copy < 0) return {};
  auto owned = std::make_shared<OwnedFD>(copy);
  return Bounded([owned] { return Peer(owned->fd); });
}
std::shared_ptr<Identity> BoundedRead(const std::shared_ptr<Identity>& original) {
  return original ? Bounded([original] { return Read(original->pid,original->audit); }) : nullptr;
}
bool Current() {
  if (!state.observationEnabled || !state.live || state.lost) return false;
  if (!state.parent || !state.peer || state.connection < 0 || getppid() != state.parent->pid) { state.lost = true; state.reason = @"parent-reparented-or-source-lost"; return false; }
  if (!Same(state.parent, BoundedRead(state.parent)) || !Same(state.parent, BoundedPeer(state.connection))) {
    state.lost = true; state.reason = @"caller-read-gap-or-introspection-unavailable"; return false;
  }
  return true;
}
static bool WaitDiagnosticGate(int fd) {
  const auto until=std::chrono::steady_clock::now()+std::chrono::seconds(5);
  while (std::chrono::steady_clock::now()<until) {
    auto remain=std::chrono::duration_cast<std::chrono::milliseconds>(until-std::chrono::steady_clock::now()).count();
    pollfd event{fd,POLLIN,0}; int status=poll(&event,1,static_cast<int>(std::max<int64_t>(1,remain)));
    if (status<0 && errno==EINTR) continue;
    if (status<=0 || !(event.revents&POLLIN)) return false;
    unsigned char byte=0; auto count=recv(fd,&byte,1,MSG_DONTWAIT);
    if (count<0 && (errno==EAGAIN || errno==EINTR)) continue;
    return count==1 && byte==0x44; // Actual original inherited socket only; no auth meaning.
  }
  return false;
}
static NSDictionary* PolicyTrace() {
  auto work=state.diagnosticWork;
  if (!work) return @{};
  const bool finished=work->finished.load(std::memory_order_acquire);
  const bool timedOut=work->timedOut.load();
  return @{@"ticket":work->ticket,@"started":@(work->started.load()),@"waiting":@(work->waiting.load()),
    @"released":@(work->released.load()),@"strictCompleted":@(work->strictCompleted.load()),
    @"strictSucceeded":@(work->strictSucceeded.load()),@"finished":@(finished),
    @"timedOut":@(timedOut),@"lateCompletion":@(timedOut && finished),
    @"existingDeadlineMilliseconds":@250,@"authUnavailable":@(authUnavailable.load()),@"acceptedVersion":@0};
}
[[maybe_unused]] NSDictionary* ObserveCompiledImagePolicy() {
  // Explicit diagnostic only: never creates/updates a connection pair/factory.
  if (!state.imagePolicyDiagnostic) return @{@"status":@"disabled",@"acceptedVersion":@0,@"compiledPolicyVersion":@(YABCORE_COMPILED_PARENT_POLICY_VERSION)};
  if (state.diagnosticWork) return @{@"status":@"unavailable",@"acceptedVersion":@0,
    @"compiledPolicyVersion":@(YABCORE_COMPILED_PARENT_POLICY_VERSION),@"observationOnly":@YES,
    @"continuousImageLease":@NO,@"deadlineTrace":PolicyTrace()}; // Never rerun/upgrade a retired attempt.
  auto policy = AcceptedOriginalParentImageIssuer::Compiled();
  if (!policy || !policy->Complete() || !state.helper || !Current())
    return @{@"status":@"unavailable",@"acceptedVersion":@0,@"compiledPolicyVersion":@(YABCORE_COMPILED_PARENT_POLICY_VERSION),@"observationOnly":@YES};
  auto parent=state.parent, helper=state.helper;
  std::shared_ptr<Identity> observed;
  if (state.diagnosticDeadline) {
    auto work=std::make_shared<DiagnosticPolicyWork>();state.diagnosticWork=work;
    auto gate=state.diagnosticGate;state.diagnosticGate.reset(); // Worker holds actual FD through completion.
    observed=Bounded([policy,parent,helper,work,gate] {
      work->started.store(true);work->waiting.store(true);
      if (!gate || !WaitDiagnosticGate(gate->fd)) { work->waiting.store(false);work->finished.store(true);return std::shared_ptr<Identity>{}; }
      work->waiting.store(false);work->released.store(true);
      auto result=InspectOriginalParentImage(policy,parent,helper); // REAL strict inspector, never a fake success.
      work->strictSucceeded.store(static_cast<bool>(result));work->strictCompleted.store(true);work->finished.store(true);
      return result;
    });
    if (authUnavailable.load() && !work->finished.load()) work->timedOut.store(true);
  } else observed=Bounded([policy,parent,helper] { return InspectOriginalParentImage(policy,parent,helper); });
  const bool current=Same(parent,observed) && Current();
  return @{@"status":current ? @"strict-snapshot-observed" : @"unavailable",
    @"acceptedVersion":@0,@"compiledPolicyVersion":@(YABCORE_COMPILED_PARENT_POLICY_VERSION),
    @"observationOnly":@YES,@"continuousImageLease":@NO,@"deadlineTrace":PolicyTrace()};
}
NSDictionary* Fields(const std::shared_ptr<Identity>& identity) {
  if (!identity) return @{};
  return @{@"pid": @(identity->pid), @"parent": @(identity->parent), @"uid": @(identity->uid),
    @"startSec": @(std::to_string(identity->sec).c_str()), @"startUsec": @(identity->usec),
    @"executable": @(identity->executable.c_str()), @"argvSHA256": @(identity->argv.c_str()),
    @"bootSession": @(identity->boot.c_str()), @"auditSHA256": @(Hash(identity->audit.bytes,identity->audit.length).c_str()),
    @"codeIdentifier": @(identity->identifier.c_str()), @"codeUnique": @(identity->unique.c_str())};
}
}
void CaptureBeforeCEF(int fd, bool diagnostic_observation, bool deadline_gate) {
#if YABCORE_ORIGINAL_CALLER_ACCEPTED_VERSION != 1
  // An explicit isolated probe may observe real inherited/kernel evidence.
  // This flag cannot change Ready()/acceptedVersion or activate group routes.
  if (!diagnostic_observation) { state.reason = @"policy-disabled"; return; }
#endif
  state.observationEnabled = true;
  state.imagePolicyDiagnostic = diagnostic_observation;
  state.diagnosticDeadline = diagnostic_observation && deadline_gate;
  if (state.initialSeen) return; state.initialSeen = true;
  pid_t parent = getppid(); if (parent <= 1) { state.reason = @"initial-parent-unavailable"; return; }
  auto initial = BoundedPeer(fd);
  if (!initial || initial->pid != parent || getppid() != parent || !Same(initial,BoundedRead(initial))) { state.reason = authUnavailable.load() ? @"introspection-deadline-or-close" : @"bootstrap-kernel-proof-unavailable"; return; }
  if (state.diagnosticDeadline) {
    int gate=fcntl(fd,F_DUPFD_CLOEXEC,0);
    if (gate<0) { state.lost=true;state.reason=@"diagnostic-original-gate-unavailable";return; }
    state.diagnosticGate=std::make_shared<OwnedFD>(gate);
  }
  state.reason = @"initial-parent-captured"; state.parent = initial; // Actual inherited socket audit identity, not getppid authority.
}
void ConnectionAccepted(int fd) {
  if (!state.observationEnabled) return;
  if (state.acceptedSeen) { state.lost = true; state.reason = @"replacement-connection-refused"; return; }
  state.acceptedSeen = true; state.connection = fd;
  if (!state.parent || state.lost) return;
  auto peer = BoundedPeer(fd);
  if (!peer || !Same(state.parent,peer) || getppid() != state.parent->pid) { state.reason = @"original-caller-mismatch-or-read-gap"; return; }
  state.reason = @"original-connection-bound"; state.peer = peer; state.live = true; state.helperNonce = NSUUID.UUID.UUIDString.lowercaseString;
}
void ConnectionDropped() { if (!state.observationEnabled) return; state.lost = true; state.live = false; state.connection = -1; state.reason = @"original-connection-lost"; }
void Hello(NSDictionary* parameters) {
  if (!state.observationEnabled) return;
  if (state.helloSeen) { state.lost = true; state.reason = @"repeated-hello-refused"; return; } state.helloSeen = true;
  NSString* nonce = [parameters[@"originalPeerClientNonce"] isKindOfClass:NSString.class] ? parameters[@"originalPeerClientNonce"] : nil;
  NSUUID* parsed = nonce ? [[NSUUID alloc] initWithUUIDString:nonce] : nil;
  if (!parsed || ![parsed.UUIDString.lowercaseString isEqual:nonce]) { state.reason = @"client-nonce-invalid"; return; }
  if (!Current()) return;
  auto helper = Bounded([] { return Self(); }); if (!helper) { state.reason = @"helper-self-read-gap"; return; }
  if (!Current()) return;
  state.helper = helper; state.clientNonce = nonce; state.reason = @"nonce-pair-observed";
}
bool Ready() {
  if (state.imagePolicyDiagnostic) return false; // Diagnostic origin never creates a factory, even future1.
  // Normal source has no compiled issuer; acceptedVersion0 stays closed even
  // with explicit build-time candidate inputs. No runtime peer supplies policy.
  auto policy = OriginalParentImagePolicy::Current();
  if (!policy || !policy->Complete()) return false;
#if YABCORE_ORIGINAL_CALLER_ACCEPTED_VERSION == 1
  if (authUnavailable.load() || !state.clientNonce || !state.helperNonce || !state.helper || !Current()) return false;
  if (state.imageLatchAttempted && !state.parentImagePair) return false;
  state.imageLatchAttempted = true; // Never upgrade/retry a failed first connection.
  auto parent = state.parent, helper = state.helper;
  auto expected = state.parentImagePair;
  auto observed = std::make_shared<std::shared_ptr<const OriginalParentImagePair>>();
  auto image = Bounded([policy,parent,helper,expected,observed] {
    return InspectOriginalParentImage(policy,parent,helper,expected,observed.get());
  });
  if (!Same(parent,image) || !*observed || !Current()) {
    state.lost = true; state.reason = @"parent-image-policy-mismatch-or-read-gap"; return false;
  }
  state.parentImagePair = *observed; // Only after actual bounded completion + current original peer.
  return true; // Current-call validation snapshot only, not native commit proof.
#else
  return false;
#endif
}
NSDictionary* Receipt(NSString* factory, NSString* groupConnection) {
  if (!state.observationEnabled) return @{@"version": @1, @"status": @"unavailable", @"acceptedVersion": @0, @"reason": @"policy-disabled"};
  if (!state.clientNonce || !state.helperNonce || !state.helper || !Current()) return @{@"version": @1, @"status": @"unavailable", @"acceptedVersion": @0, @"reason": state.reason};
  return @{@"version": @1, @"status": @"observed", @"acceptedVersion": @(state.imagePolicyDiagnostic ? 0 : YABCORE_ORIGINAL_CALLER_ACCEPTED_VERSION), @"reason": state.reason,
    @"clientNonce": state.clientNonce, @"helperNonce": state.helperNonce,
    @"initialParent": Fields(state.parent), @"caller": Fields(state.peer), @"helper": Fields(state.helper),
    @"factoryOwner": factory ?: @"", @"groupConnection": groupConnection ?: @"",
    @"parentImagePolicyObservation": ObserveCompiledImagePolicy()};
}
NSDictionary* DiagnosticReceipt(NSString* factory, NSString* groupConnection) {
  if (!state.imagePolicyDiagnostic || !state.acceptedSeen || !state.live || state.connection<0 || !state.clientNonce || !state.helperNonce) return nil;
  if (state.diagnosticWork) return @{@"version":@1,@"status":@"unavailable",@"acceptedVersion":@0,
    @"reason":@"diagnostic-deadline-retired",@"parentImagePolicyObservation":ObserveCompiledImagePolicy()};
  return Receipt(factory,groupConnection);
}

}
