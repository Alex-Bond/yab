#import <Foundation/Foundation.h>
#include <cassert>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <vector>

// The real page_snapshot.inc with controllable CDP replies: when a hide runs
// against the pictures in flight. Whether Chromium then presents, strands or
// keeps a frame is the native probes' (evals/speedometer/leaving_pictures.py).
#define YABCORE_DISCARD 0
using Completion = std::function<void(NSDictionary*, NSString*)>;
struct View { bool visible = true; void SetVisible(bool value) { visible = value; } };
struct Tab {
  bool closing = false, visible = true, viewCleared = false, clearAfterCapture = false;
  uint64_t documentGeneration = 1, visibleTurn = 0;
  // The page.snapshot handler counts the picture before SnapshotPage.
  int capturing = 1;
  std::shared_ptr<View> view = std::make_shared<View>();
};
static std::map<std::string, Tab> tabs;
struct Call { NSDictionary* params; Completion done; };
struct ReplyValue { NSDictionary* result; NSString* error; };
static std::vector<Call> calls;
static std::vector<ReplyValue> replies;
static int clearCalls;
static constexpr NSUInteger kMaxMessage = 8192;
static double Now() { return 0; }
static bool DocumentMatches(const Tab& tab, NSDictionary* proof) {
  return !proof || [proof[@"generation"] unsignedLongLongValue] == tab.documentGeneration;
}
static void Reply(NSString*, NSDictionary* result, NSString* error) { replies.push_back({result, error}); }
static bool producerShown;
static bool ProducerShown(Tab&) { return producerShown; }
static bool HoldHideForPicture(Tab&);
// core.mm's, without its timers: the view goes at once.
static void HideClearing(Tab& tab) {
  if (HoldHideForPicture(tab)) return;
  ++clearCalls;
  ++tab.visibleTurn;
  tab.viewCleared = true;
  tab.view->SetVisible(false);
}
static void CDP(Tab&, NSString* method, NSDictionary* params, Completion done) {
  assert([method isEqual:@"Page.captureScreenshot"]);
  calls.push_back({params, done});
}
static void DRMWhenReady(std::string id, std::function<void(Tab&)> ready,
                         std::function<void(NSString*)> failed, double) {
  auto tab = tabs.find(id);
  if (tab == tabs.end()) failed(@"Tab closed"); else ready(tab->second);
}
#include "page_snapshot.inc"

static Call take() {
  assert(!calls.empty());
  Call call = calls.front(); calls.erase(calls.begin()); return call;
}
static Tab& tab() { return tabs.at("tab"); }
static void reset(bool hidden = false) {
  calls.clear(); replies.clear(); tabs.clear(); tabs["tab"] = {};
  producerShown = false;
  clearCalls = 0;
  if (hidden) {
    tab().visible = false; tab().viewCleared = true; tab().view->visible = false;
  }
}
static void start(int quality = 0, NSDictionary* clip = nil, NSDictionary* proof = @{@"generation": @1}) {
  SnapshotPage("tab", 1, proof, @"request", quality, clip);
}
// tab.visible false, as core.mm's handler runs it for a shown page.
static void hide() { tab().visible = false; if (!tab().viewCleared) HideClearing(tab()); }
static void show() { tab().visible = true; tab().clearAfterCapture = false; }

int main() { @autoreleasepool {
  int cases = 0;
  reset(); start();
  auto shot = take(); shot.done(@{@"data": @"image"}, nil);
  assert(replies.size() == 1 && !replies[0].error && tab().capturing == 0 && clearCalls == 0);
  shot.done(@{@"data": @"late duplicate"}, nil); assert(replies.size() == 1);
  ++cases;

  // The stage's leaving picture: asked, then the hide. The hide waits with
  // the view and the window up, and runs whole once the picture is taken.
  reset(); start(75, nil, nil); hide();
  assert(clearCalls == 0 && tab().clearAfterCapture && tab().view->visible && !tab().viewCleared);
  shot = take(); assert([shot.params[@"format"] isEqual:@"jpeg"]);
  shot.done(@{@"data": @"image"}, nil);
  assert(replies.size() == 1 && !replies[0].error && clearCalls == 1 && tab().viewCleared && !tab().view->visible);
  assert(!tab().clearAfterCapture && tab().capturing == 0);
  ++cases;

  // A hide with nothing in flight runs at once.
  reset(); tab().capturing = 0; hide();
  assert(clearCalls == 1 && tab().viewCleared && !tab().clearAfterCapture);
  ++cases;

  // Two pictures before the hide: it waits for both.
  reset(); tab().capturing = 2; start(); start(); hide();
  take().done(@{@"data": @"first"}, nil); assert(clearCalls == 0 && tab().capturing == 1 && tab().view->visible);
  take().done(@{@"data": @"second"}, nil); assert(clearCalls == 1 && tab().capturing == 0);
  ++cases;

  // Shown again before the picture is back: the held hide is dropped.
  reset(); start(); hide(); show(); take().done(@{@"data": @"image"}, nil);
  assert(clearCalls == 0 && tab().view->visible && !tab().viewCleared && replies.size() == 1);
  ++cases;

  // A picture that fails still lets the held hide run.
  reset(); start(); hide(); take().done(nil, @"CDP timeout");
  assert([replies[0].error isEqual:@"CDP timeout"] && clearCalls == 1 && tab().capturing == 0);
  ++cases;

  // The document changed under a held hide: refused, and the hide runs.
  reset(); start(); hide(); shot = take(); tab().documentGeneration = 2;
  shot.done(@{@"data": @"wrong-document"}, nil);
  assert([replies[0].error isEqual:@"Snapshot document changed"] && clearCalls == 1);
  ++cases;

  // Too large for the wire: stepped down while the hide waits.
  reset(); start(); hide();
  NSString* large = [@"" stringByPaddingToLength:5000 withString:@"x" startingAtIndex:0];
  take().done(@{@"data": large}, nil); shot = take();
  assert([shot.params[@"quality"] intValue] == 75 && clearCalls == 0);
  shot.done(@{@"data": large}, nil); shot = take();
  assert([shot.params[@"quality"] intValue] == 40 && clearCalls == 0);
  shot.done(@{@"data": @"image"}, nil);
  assert(replies.size() == 1 && clearCalls == 1 && tab().capturing == 0);
  ++cases;

  // A hidden window's page: pictured as it is, its view left down.
  reset(true); start();
  assert(!tab().view->visible && tab().viewCleared && !tab().clearAfterCapture && tab().visibleTurn == 0);
  take().done(@{@"data": @"image"}, nil);
  assert(replies.size() == 1 && !replies[0].error && clearCalls == 0 && tab().capturing == 0);
  ++cases;

  // Asked just after a hide, the window still on its way to hiding: the view
  // comes back at once and the whole hide runs again after the picture.
  reset(true); producerShown = true; start(); shot = take();
  assert(tab().view->visible && !tab().viewCleared && tab().clearAfterCapture && tab().visibleTurn == 1);
  shot.done(@{@"data": @"image"}, nil);
  assert(replies.size() == 1 && !replies[0].error && clearCalls == 1 && tab().capturing == 0 && tab().viewCleared);
  ++cases;

  reset(); start(75, @{@"x": @3, @"y": @4, @"width": @50, @"height": @60, @"scale": @1});
  shot = take();
  assert([shot.params[@"format"] isEqual:@"jpeg"] && [shot.params[@"quality"] intValue] == 75);
  assert([shot.params[@"clip"][@"width"] intValue] == 50 && [shot.params[@"captureBeyondViewport"] boolValue]);
  shot.done(@{@"data": @"image"}, nil); assert(tab().capturing == 0);
  ++cases;

  // Closed or closing under a held hide: no hide runs on a closing page.
  reset(); start(); hide(); shot = take(); tabs.erase("tab"); shot.done(nil, @"Tab closed");
  assert([replies[0].error isEqual:@"Snapshot document changed"] && clearCalls == 0);
  reset(); start(); hide(); shot = take(); tab().closing = true; shot.done(nil, @"Tab closing");
  assert([replies[0].error isEqual:@"Snapshot document changed"] && clearCalls == 0);
  ++cases;

  printf("PASS %d snapshot and hide cases: picture, leaving picture then hide, bare hide, two in flight, shown again, failure, changed document, step down, hidden window as is, view back while hiding, clip, closed\n", cases);
}}
