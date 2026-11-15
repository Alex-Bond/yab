#pragma once
#import <Cocoa/Cocoa.h>
#include "include/cef_app.h"
#include <functional>
namespace yc {
constexpr size_t kMaxMessage = 4 * 1024 * 1024;
// Queued bytes either way. Overflow drops the client, and with it every page:
// 138 loading tabs overran 8 MB (Release-1 scenario runs, 2026-10-30).
constexpr size_t kMaxQueued = 256 * 1024 * 1024;
using Completion = std::function<void(NSDictionary*, NSString*)>;
class Transport {
 public:
  bool Start(NSString* path);
  void Poll();
  void Send(NSDictionary* value);
  void Close();
  std::function<void(NSDictionary*)> onRequest;
  std::function<void()> onDisconnect;
 private:
  int listener_ = -1, peer_ = -1;
  NSString* path_;
  NSMutableData* input_ = [NSMutableData new];
  NSMutableData* output_ = [NSMutableData new];
  void Drop();
};
CefRefPtr<CefApp> MakeApp(NSString* root, NSString* socket);
void Shutdown();
void TearDown();
}
