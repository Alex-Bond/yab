#include "transport.h"
#ifndef YABCORE_TRANSPORT_FAKE
#include "core_lifetime.h"
#include "original_caller.h"
#else
// YabCore/tests/transport_fake.mm runs this file without CEF.
namespace yc { static void WatchPeer(int) {} namespace original_caller {
static void ConnectionDropped() {} static void ConnectionAccepted(int) {}
} }
#endif
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <fcntl.h>
#include <unistd.h>
#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
namespace yc {
static std::string Key(NSString* s) { return s.UTF8String ?: ""; }
CFFileDescriptorRef Transport::Watch(int fd, void* owner) {
  CFFileDescriptorContext context = {0, owner, nullptr, nullptr, nullptr};
  CFFileDescriptorRef watch = CFFileDescriptorCreate(kCFAllocatorDefault, fd, false, Ready, &context);
  if (!watch) return nullptr;
  CFRunLoopSourceRef source = CFFileDescriptorCreateRunLoopSource(kCFAllocatorDefault, watch, 0);
  CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
  CFRelease(source);
  return watch;
}
void Transport::Unwatch(CFFileDescriptorRef& watch) {
  if (!watch) return;
  CFFileDescriptorInvalidate(watch);
  CFRelease(watch);
  watch = nullptr;
}
void Transport::Ready(CFFileDescriptorRef, CFOptionFlags, void* owner) {
  static_cast<Transport*>(owner)->Poll();
}
// Requests are read only while what is held for them is under budget: one
// request in, its reply out. Past either, the client's socket and its own
// admission hold the rest, and nothing is lost or ended.
bool Transport::Reading() const {
  return input_.length < kInputBudget && output_.length < kReplyBudget;
}
// Each source fires once per enable. Anything still to read or write asks again.
void Transport::Arm() {
  if (listenWatch_) CFFileDescriptorEnableCallBacks(listenWatch_, kCFFileDescriptorReadCallBack);
  if (peerWatch_) CFFileDescriptorEnableCallBacks(peerWatch_,
    (Reading() ? kCFFileDescriptorReadCallBack : 0) | (output_.length ? kCFFileDescriptorWriteCallBack : 0));
}
void Transport::PollSoon() {
  if (pollQueued_) return;
  pollQueued_ = true;
  CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{ pollQueued_ = false; Poll(); });
  CFRunLoopWakeUp(CFRunLoopGetMain());
}
// Replies and events leave at once. A full socket keeps the rest for its write
// callback; a broken one is left to the read side, which drops it on EOF.
void Transport::Flush() {
  while (peer_ >= 0 && output_.length) {
    ssize_t n = write(peer_, output_.bytes, MIN(output_.length, 256 * 1024));
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) { if (peerWatch_) CFFileDescriptorEnableCallBacks(peerWatch_, kCFFileDescriptorWriteCallBack); return; }
    [output_ replaceBytesInRange:NSMakeRange(0, n) withBytes:nullptr length:0];
  }
  // A drained buffer gives back the room its busiest moment took.
  if (peer_ >= 0 && !output_.length && outputHigh_ > 1024 * 1024) { output_ = [NSMutableData new]; outputHigh_ = 0; }
}
bool Transport::Start(NSString* path) {
  // The caller supplies a new socket inside an owner-only directory. Never
  // unlink an existing endpoint, which may belong to a live helper.
  struct stat st;
  NSString* parent = path.stringByDeletingLastPathComponent;
  if (lstat(parent.fileSystemRepresentation, &st) || !S_ISDIR(st.st_mode) ||
      st.st_uid != getuid() || (st.st_mode & 077) != 0) return false;
  sockaddr_un addr = {}; addr.sun_family = AF_UNIX;
  if (path.length == 0 || strlen(path.fileSystemRepresentation) >= sizeof(addr.sun_path)) return false;
  strlcpy(addr.sun_path, path.fileSystemRepresentation, sizeof(addr.sun_path));
  listener_ = socket(AF_UNIX, SOCK_STREAM, 0);
  if (listener_ < 0) return false;
  fcntl(listener_, F_SETFL, O_NONBLOCK); fcntl(listener_, F_SETFD, FD_CLOEXEC);
  if (bind(listener_, reinterpret_cast<sockaddr*>(&addr), sizeof(addr))) {
    close(listener_); listener_ = -1; return false;
  }
  path_ = path;
  if (chmod(path.fileSystemRepresentation, 0600) || listen(listener_, 1)) { Close(); return false; }
  listenWatch_ = Watch(listener_, this);
  Arm();
  return true;
}
void Transport::Reset() {
  input_ = [NSMutableData new]; output_ = [NSMutableData new];
  waiting_.clear(); latest_.clear(); barrier_.clear(); sourceBytes_.clear();
  front_ = 0; waitingBytes_ = 0; outputHigh_ = inputHigh_ = 0;
  flow_ = false; windowBytes_ = windowCount_ = outBytes_ = outCount_ = 0;
}
void Transport::Drop() {
  if (peer_ < 0) return;
  original_caller::ConnectionDropped();
  Unwatch(peerWatch_);
  close(peer_); peer_ = -1;
  Reset();
  if (onDisconnect) onDisconnect();
}
void Transport::Close() {
  Drop();
  Unwatch(listenWatch_);
  if (listener_ >= 0) { close(listener_); listener_ = -1; }
  if (path_) { unlink(path_.fileSystemRepresentation); path_ = nil; }
}
// A later event of one of these says all an earlier one of its key said, so a
// waiting one is replaced. page.state and download.updated are patches and
// merge. Everything else keeps its order and its every copy: navigation,
// close, crash, dialogs, pickers, permissions, consent, page messages.
NSString* Transport::LatestKey(NSString* name, NSDictionary* params, bool* merge) {
  *merge = false;
  if (![name isKindOfClass:NSString.class] || ![params isKindOfClass:NSDictionary.class]) return nil;
  NSString* tab = [params[@"tab"] isKindOfClass:NSString.class] ? params[@"tab"] : @"";
  static NSSet* perTab = [NSSet setWithArray:@[@"layer.changed", @"page.hover", @"page.cursor", @"documentPiP.size",
    @"media.state", @"media.session.changed", @"media.pip.changed", @"media.capture.changed", @"media.capture",
    @"page.fullscreen", @"page.responsive", @"page.textInput"]];
  if ([name isEqual:@"page.state"]) {
    if (!tab.length) return nil;
    *merge = true; return [@"page.state|" stringByAppendingString:tab];
  }
  if ([perTab containsObject:name]) return tab.length ? [NSString stringWithFormat:@"%@|%@", name, tab] : nil;
  if ([name isEqual:@"download.updated"] && [params[@"download"] isKindOfClass:NSString.class]) {
    *merge = true; return [@"download.updated|" stringByAppendingString:params[@"download"]];
  }
  if (([name isEqual:@"popup.textInput"] || [name isEqual:@"popup.cursor"]) && [params[@"token"] isKindOfClass:NSString.class])
    return [NSString stringWithFormat:@"%@|%@", name, params[@"token"]];
  if ([name isEqual:@"popup.layer"] && [params[@"popup"] isKindOfClass:NSString.class])
    return [@"popup.layer|" stringByAppendingString:params[@"popup"]];
  if ([name isEqual:@"cookies.touched"] && tab.length && [params[@"url"] isKindOfClass:NSString.class])
    return [NSString stringWithFormat:@"cookies.touched|%@|%d|%@", tab, [params[@"main"] boolValue], params[@"url"]];
  return nil;
}
// What a page or the app waits on, and a tab's own birth and end: never shed.
static bool Kept(NSString* name) {
  static NSSet* kept = [NSSet setWithArray:@[@"tab.created", @"tab.closed", @"tab.closePreflight", @"page.crash",
    @"dialog.open", @"dialog.closed", @"question.open", @"question.closed", @"select.open", @"select.closed",
    @"file.open", @"file.closed", @"menu.open", @"print.request", @"print.withdrawn", @"download.open",
    @"extension.consent", @"extension.consent.withdrawn", @"extension.desktopMedia", @"extension.desktopMedia.withdrawn", @"popup.closed", @"read.page.closed", @"page.eventsShed"]];
  return [kept containsObject:name];
}
void Transport::Enqueue(NSDictionary* value, NSData* data) {
  NSString* name = value[@"event"];
  NSDictionary* params = [value[@"params"] isKindOfClass:NSDictionary.class] ? value[@"params"] : @{};
  std::string source = Key([params[@"tab"] isKindOfClass:NSString.class] ? params[@"tab"] : @"");
  bool merge = false;
  NSString* key = LatestKey(name, params, &merge);
  if (key) {
    auto slot = latest_.find(Key(key));
    auto barrier = barrier_.find(source);
    if (slot != latest_.end() && slot->second >= front_ &&
        (barrier == barrier_.end() || barrier->second < slot->second)) {
      Waiting& held = waiting_[slot->second - front_];
      if (held.value) {
        NSDictionary* next = value; NSData* encoded = data;
        if (merge) {
          NSMutableDictionary* fields = [held.value[@"params"] mutableCopy];
          [fields addEntriesFromDictionary:params];
          next = @{@"v": @1, @"event": name, @"params": fields};
          encoded = [NSJSONSerialization dataWithJSONObject:next options:0 error:nil];
        }
        if (encoded && encoded.length <= kMaxMessage) {
          waitingBytes_ = waitingBytes_ - held.data.length + encoded.length;
          sourceBytes_[source] = sourceBytes_[source] - held.data.length + encoded.length;
          held.value = next; held.data = encoded; ++coalesced_;
          peakWaiting_ = std::max(peakWaiting_, waitingBytes_);
          while (waitingBytes_ > kEventBudget) Shed();
          return;
        }
      }
    }
  }
  uint64_t sequence = front_ + waiting_.size();
  waiting_.push_back({source, key, value, data, Kept(name)});
  if (key) latest_[Key(key)] = sequence; else barrier_[source] = sequence;
  waitingBytes_ += data.length; sourceBytes_[source] += data.length;
  peakWaiting_ = std::max(peakWaiting_, waitingBytes_);
  while (waitingBytes_ > kEventBudget) Shed();
}
// The budget is passed: the source holding the most waiting bytes loses its
// waiting notifications, and only it. Its owner ends its page (onShed). What
// is left is laid out again, so a shed event leaves nothing behind. If what
// is left is all asks and lifecycle, which nothing produces at this volume,
// the wire itself can't be kept, and the client learns it from its end.
void Transport::Shed() {
  std::unordered_map<std::string, size_t> sheddable;
  for (const auto& slot : waiting_) if (!slot.keep && !slot.source.empty()) sheddable[slot.source] += slot.data.length;
  std::string victim; size_t most = 0;
  for (const auto& [source, bytes] : sheddable) if (bytes > most) { victim = source; most = bytes; }
  size_t freed = 0;
  std::deque<Waiting> kept;
  for (auto& slot : waiting_) {
    if (!victim.empty() && slot.source == victim && !slot.keep) { freed += slot.data.length; continue; }
    kept.push_back(std::move(slot));
  }
  waiting_.swap(kept);
  latest_.clear(); barrier_.clear(); sourceBytes_.clear(); waitingBytes_ = 0;
  for (uint64_t i = 0; i < waiting_.size(); ++i) {
    const Waiting& slot = waiting_[i];
    if (slot.key) latest_[Key(slot.key)] = front_ + i; else barrier_[slot.source] = front_ + i;
    sourceBytes_[slot.source] += slot.data.length; waitingBytes_ += slot.data.length;
  }
  if (!freed) {
    fprintf(stderr, "YabCore transport: %zu bytes of asks and lifecycle wait, past the %zu budget; ending the connection\n",
      waitingBytes_, kEventBudget);
    Drop(); return;
  }
  ++shed_;
  fprintf(stderr, "YabCore transport: shed %zu waiting bytes of tab=%s (budget %zu)\n", freed, victim.c_str(), kEventBudget);
  if (onShed) onShed(victim, freed);
}
// Waiting events leave in order while the client's credit lasts. One larger
// than the whole window still leaves once nothing else is out.
void Transport::Pump() {
  while (peer_ >= 0 && !waiting_.empty()) {
    Waiting& slot = waiting_.front();
    if (slot.value) {
      size_t size = slot.data.length + 1;
      if (outCount_ >= windowCount_ || (outBytes_ && outBytes_ + size > windowBytes_)) break;
      [output_ appendData:slot.data]; [output_ appendBytes:"\n" length:1];
      outBytes_ += size; ++outCount_; ++sent_;
      waitingBytes_ -= slot.data.length;
      auto bytes = sourceBytes_.find(slot.source);
      if (bytes != sourceBytes_.end()) { bytes->second -= slot.data.length; }
    }
    if (slot.key) {
      auto latest = latest_.find(Key(slot.key));
      if (latest != latest_.end() && latest->second == front_) latest_.erase(latest);
    } else {
      auto barrier = barrier_.find(slot.source);
      if (barrier != barrier_.end() && barrier->second == front_) barrier_.erase(barrier);
    }
    auto bytes = sourceBytes_.find(slot.source);
    if (bytes != sourceBytes_.end() && !bytes->second) sourceBytes_.erase(bytes);
    waiting_.pop_front(); ++front_;
  }
  peakOutput_ = std::max(peakOutput_, (size_t)output_.length);
  outputHigh_ = std::max(outputHigh_, (size_t)output_.length);
}
// {"flow": {"bytes": N, "count": M}}: events the client's consumer has taken.
void Transport::Credit(NSDictionary* flow) {
  if (![flow isKindOfClass:NSDictionary.class] || ![flow[@"bytes"] isKindOfClass:NSNumber.class] ||
      ![flow[@"count"] isKindOfClass:NSNumber.class] || [flow[@"bytes"] longLongValue] < 0 || [flow[@"count"] longLongValue] < 0) {
    fprintf(stderr, "YabCore transport: malformed flow frame\n"); Drop(); return;
  }
  size_t bytes = (size_t)[flow[@"bytes"] longLongValue], count = (size_t)[flow[@"count"] longLongValue];
  if (bytes > outBytes_ || count > outCount_) {
    // More back than was out is the client's accounting error; never more
    // room than the window it asked for.
    if (!refusedCredit_++) fprintf(stderr, "YabCore transport: credit past what was sent (%zu/%zu of %zu/%zu)\n", bytes, count, outBytes_, outCount_);
  }
  outBytes_ -= std::min(bytes, outBytes_); outCount_ -= std::min(count, outCount_);
}
void Transport::Hello(NSDictionary* params) {
  NSDictionary* window = [params isKindOfClass:NSDictionary.class] ? params[@"eventWindow"] : nil;
  if (![window isKindOfClass:NSDictionary.class]) return;
  long long bytes = [window[@"bytes"] longLongValue], count = [window[@"count"] longLongValue];
  if (bytes < 64 * 1024 || bytes > 64 * 1024 * 1024 || count < 16 || count > 65536) return;
  flow_ = true; windowBytes_ = (size_t)bytes; windowCount_ = (size_t)count; outBytes_ = outCount_ = 0;
}
NSDictionary* Transport::Metrics() const {
  size_t live = 0;
  for (const auto& slot : waiting_) if (slot.value) ++live;
  return @{@"flow": @(flow_), @"windowBytes": @(windowBytes_), @"windowCount": @(windowCount_),
    @"outstandingBytes": @(outBytes_), @"outstandingCount": @(outCount_),
    @"waitingEvents": @(live), @"waitingBytes": @(waitingBytes_), @"peakWaitingBytes": @(peakWaiting_),
    @"waitingSources": @(sourceBytes_.size()), @"latestKeys": @(latest_.size()), @"barriers": @(barrier_.size()),
    @"outputBytes": @(output_.length), @"peakOutputBytes": @(peakOutput_),
    @"inputBytes": @(input_.length), @"peakInputBytes": @(peakInput_),
    @"coalesced": @(coalesced_), @"shed": @(shed_), @"sent": @(sent_), @"creditErrors": @(refusedCredit_),
    @"eventBudget": @(kEventBudget), @"replyBudget": @(kReplyBudget), @"inputBudget": @(kInputBudget)};
}
void Transport::Send(NSDictionary* value) { @autoreleasepool {
  if (peer_ < 0) return;
  NSError* error = nil;
  NSData* data = [NSJSONSerialization dataWithJSONObject:value options:0 error:&error];
  if (!data || data.length > kMaxMessage) {
    // One answer too long for the wire fails its own request. Dropping the
    // connection here ended the helper and every page with a clean exit and
    // no crash report: a page's picture on a big window came to 4.6 MB.
    fprintf(stderr, "YabCore transport send refused: json=%s bytes=%lu request=%d event=%s\n",
      error ? error.localizedDescription.UTF8String : "valid", (unsigned long)data.length, value[@"id"] != nil,
      [value[@"event"] isKindOfClass:NSString.class] ? [value[@"event"] UTF8String] : "-");
    if (!value[@"id"]) return;
    data = [NSJSONSerialization dataWithJSONObject:@{@"v": @1, @"id": value[@"id"], @"error":
      @{@"code": @"operation_failed", @"message": @"Reply too long for the wire"}} options:0 error:nil];
  }
  if (value[@"id"] || !flow_) {
    if (!value[@"id"] && output_.length + data.length > kLegacyQueued) {
      fprintf(stderr, "YabCore transport queue full: bytes=%lu queued=%lu\n", (unsigned long)data.length, (unsigned long)output_.length);
      Drop(); return;
    }
    [output_ appendData:data]; [output_ appendBytes:"\n" length:1];
    peakOutput_ = std::max(peakOutput_, (size_t)output_.length);
    outputHigh_ = std::max(outputHigh_, (size_t)output_.length);
  } else {
    Enqueue(value, data);
    if (peer_ < 0) return;
    Pump();
  }
  Flush();
} }
void Transport::Poll() {
  int fd = accept(listener_, nullptr, nullptr);
  if (fd >= 0) {
    uid_t uid; gid_t gid;
    if (peer_ >= 0 || getpeereid(fd, &uid, &gid) || uid != getuid()) close(fd);
    else {
      peer_ = fd; fcntl(fd, F_SETFL, O_NONBLOCK); fcntl(fd, F_SETFD, FD_CLOEXEC);
      int yes = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
      original_caller::ConnectionAccepted(fd);
      WatchPeer(fd);
      peerWatch_ = Watch(fd, this);
    }
  }
  if (peer_ < 0) { Arm(); return; }
  char buffer[16384];
  // Bound UI-thread work per tick so input cannot starve Chromium.
  for (int i = 0; i < 16 && peer_ >= 0 && Reading(); ++i) {
    ssize_t n = read(peer_, buffer, sizeof(buffer));
    if (n == 0) { Drop(); break; }
    if (n < 0) { if (errno != EAGAIN && errno != EINTR) Drop(); break; }
    [input_ appendBytes:buffer length:n];
    peakInput_ = std::max(peakInput_, (size_t)input_.length);
    inputHigh_ = std::max(inputHigh_, (size_t)input_.length);
  }
  size_t consumed = 0;
  for (int i = 0; i < 64 && peer_ >= 0; ++i) {
    const char* start = static_cast<const char*>(input_.bytes) + consumed;
    const void* end = memchr(start, '\n', input_.length - consumed);
    if (!end) break;
    NSUInteger n = static_cast<const char*>(end) - start;
    if (n > kMaxMessage) { Drop(); break; }
    id object = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytesNoCopy:(void*)start length:n freeWhenDone:NO] options:0 error:nil];
    consumed += n + 1;
    if (![object isKindOfClass:NSDictionary.class]) { Drop(); break; }
    // Credit is the wire's own, never a request: it has no id and no reply.
    if (object[@"flow"]) { Credit(object[@"flow"]); continue; }
    if ([object[@"method"] isEqual:@"hello"]) Hello(object[@"params"]);
    if (onRequest) onRequest(object);
  }
  if (peer_ >= 0 && consumed) {
    [input_ replaceBytesInRange:NSMakeRange(0, consumed) withBytes:nullptr length:0];
    if (!input_.length && inputHigh_ > 1024 * 1024) { input_ = [NSMutableData new]; inputHigh_ = 0; }
  }
  if (peer_ >= 0 && input_.length > kMaxMessage && !memchr(input_.bytes, '\n', input_.length)) Drop();
  if (peer_ >= 0) { Pump(); Flush(); }
  // Messages left over from the per-tick bound wait for the next turn of the
  // loop, as they waited for the next tick, not for more bytes that may not come.
  if (peer_ >= 0 && input_.length && memchr(input_.bytes, '\n', input_.length)) PollSoon();
  Arm();
}
}
