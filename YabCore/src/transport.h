#pragma once
#import <Foundation/Foundation.h>
#include <deque>
#include <functional>
#include <string>
#include <unordered_map>
namespace yc {
// One message either way, as the client's Socket.limit.
constexpr size_t kMaxMessage = 4 * 1024 * 1024;
// Everything the helper holds for its client, by kind. Nothing in this file
// grows past these; what would is refused, coalesced or ended by its source.
//   events  produced but not yet within the client's credit, both kinds
//   replies written to output and not yet taken by the socket; past it no
//           request is read, so the client's own admission holds the rest
//   input   requests read and not yet handled: one whole message and a read
constexpr size_t kEventBudget = 32 * 1024 * 1024;
constexpr size_t kReplyBudget = 8 * 1024 * 1024;
constexpr size_t kInputBudget = kMaxMessage + 16 * 1024;
// A client that says nothing of event flow (a test tool speaking the wire
// directly) gets events as they come, up to this, as before flow control.
constexpr size_t kLegacyQueued = 256 * 1024 * 1024;

// The helper's half of the wire. Replies always leave; events leave within
// the credit the client grants as its consumer takes them (hello's
// eventWindow, then {"flow": {"bytes", "count"}} frames). Until then an event
// waits here: a latest-state one (see LatestKey in transport.mm) replaces the
// waiting one of its key, unless an ordered event of the same source came
// between them; every other event keeps its place. If waiting events pass
// kEventBudget, the source holding the most is the one shed: its waiting
// notifications go and onShed names it, for its owner to end that page and
// say so. Asks the page waits on (dialogs, pickers, close preflight) and a
// tab's own creation and close are never shed. Nothing else is touched.
class Transport {
 public:
  bool Start(NSString* path);
  void Poll();
  void Send(NSDictionary* value);
  void Close();
  std::function<void(NSDictionary*)> onRequest;
  std::function<void()> onDisconnect;
  std::function<void(const std::string& source, size_t bytes)> onShed;
  NSDictionary* Metrics() const;
  bool Flowing() const { return flow_; }
  // A latest-state event's key (merge: its params are a patch), nil if ordered.
  static NSString* LatestKey(NSString* name, NSDictionary* params, bool* merge);

 private:
  struct Waiting {
    std::string source;
    NSString* key = nil;        // nil: ordered
    NSDictionary* value = nil;
    NSData* data = nil;
    bool keep = false;          // never shed
  };
  int listener_ = -1, peer_ = -1;
  NSString* path_;
  NSMutableData* input_ = [NSMutableData new];
  NSMutableData* output_ = [NSMutableData new];
  std::deque<Waiting> waiting_;
  uint64_t front_ = 0;  // sequence of waiting_.front()
  std::unordered_map<std::string, uint64_t> latest_;   // key -> its slot
  std::unordered_map<std::string, uint64_t> barrier_;  // source -> its last ordered slot
  std::unordered_map<std::string, size_t> sourceBytes_;
  size_t waitingBytes_ = 0;
  // Credit: the window the client grants, and what it has not returned yet.
  bool flow_ = false;
  size_t windowBytes_ = 0, windowCount_ = 0, outBytes_ = 0, outCount_ = 0;
  // Metrics.
  size_t peakWaiting_ = 0, peakOutput_ = 0, peakInput_ = 0, outputHigh_ = 0, inputHigh_ = 0;
  uint64_t coalesced_ = 0, shed_ = 0, sent_ = 0, refusedCredit_ = 0;
  // One-shot run loop sources: a socket wakes the main thread only when it
  // has something, and in the same modes the page work runs in.
  CFFileDescriptorRef listenWatch_ = nullptr, peerWatch_ = nullptr;
  bool pollQueued_ = false;
  void Enqueue(NSDictionary* value, NSData* data);
  void Shed();
  void Pump();
  void Credit(NSDictionary* flow);
  void Hello(NSDictionary* params);
  void Reset();
  void Drop();
  void Arm();
  void Flush();
  void PollSoon();
  bool Reading() const;
  static CFFileDescriptorRef Watch(int fd, void* owner);
  static void Unwatch(CFFileDescriptorRef& watch);
  static void Ready(CFFileDescriptorRef, CFOptionFlags, void* owner);
};
}
