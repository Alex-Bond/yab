#include "core.h"
#include "core_lifetime.h"
#include "original_caller.h"
#include "group_snapshot_store.h"
#include <CommonCrypto/CommonDigest.h>
#include "extensions.h"
#import <QuartzCore/QuartzCore.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <atomic>
#include <fcntl.h>
#include <cerrno>
#include "original_pdf_budget.h"
#include "original_pdf_presence_owner.h"
#include <map>
#include <mutex>
#include <set>
#include <vector>
#include <memory>
#include <string>
#include <cmath>
#include <climits>
#include <algorithm>
#include <libproc.h>
#include <signal.h>
#include <unistd.h>
#include "include/cef_process_message.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_command_line.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_dialog_handler.h"
#include "include/cef_jsdialog_handler.h"
#include "include/cef_find_handler.h"
#include "include/cef_resource_handler.h"
#include "include/cef_resource_request_handler.h"
#include "include/cef_response.h"
#include "include/cef_download_handler.h"
#include "include/cef_permission_handler.h"
#include "include/cef_parser.h"
#include "include/cef_request_context.h"
#include "include/views/cef_browser_view.h"
#include "include/views/cef_window.h"
#include "include/views/cef_window_delegate.h"
#include "owncef_surface.h"

// The experimental callback is available only with matching patched CEF.
#if defined(CEF_YAB_LAYER_CONTEXT_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_OWNCEF_SURFACES 1
#else
#define YABCORE_OWNCEF_SURFACES 0
#endif
#if defined(CEF_YAB_EXTERNAL_HOST_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_EXTERNAL_HOST 1
#else
#define YABCORE_EXTERNAL_HOST 0
#endif
#include "extensions_native.h"
#include "extensions_actions.h"

namespace yc {
static std::string Key(NSString* s) { return s.UTF8String ?: ""; }
static NSString* Str(const CefString& s) { return @(s.ToString().c_str()); }
static NSString* S(NSDictionary* p, NSString* k) { return [p[k] isKindOfClass:NSString.class] ? p[k] : @""; }
static double Now() { return NSProcessInfo.processInfo.systemUptime; }
static NSDictionary* Decode(const void* bytes, size_t size) {
  if (!bytes || !size) return @{};
  id v = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes length:size] options:0 error:nil];
  return [v isKindOfClass:NSDictionary.class] ? v : @{};
}
static NSString* JSON(id value) {
  NSData* data = [NSJSONSerialization dataWithJSONObject:value ?: NSNull.null options:NSJSONWritingFragmentsAllowed error:nil];
  return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"null";
}
// A request context is usable only after CEF reports it initialized: creating a
// browser earlier trips Chromium's own check in source builds. profile.open
// answers (and later opens of the same profile wait) until then.
struct Profile { CefRefPtr<CefRequestContext> context; bool privateMode = false; bool ready = false; std::vector<NSString*> waiting; };
#include "scripts_state.h"
#if defined(CEF_YAB_EXTERNAL_PAGE_VERSION) && YABCORE_OWNCEF_SURFACES && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_NATIVE_PAGE 1
#else
#define YABCORE_NATIVE_PAGE 0
#endif
#if defined(CEF_YAB_NATIVE_TAB_MODEL_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_NATIVE_TAB_MODEL 1
#else
#define YABCORE_NATIVE_TAB_MODEL 0
#endif
struct Tab {
  std::string healthToken, healthFrame;
  pid_t healthPID = 0;
  double healthSendAt = 0, healthDeadline = 0;
  bool healthSent = false, healthUnresponsive = false, healthAgain = false;
  uint64_t healthPings = 0, healthPongs = 0;
  ScriptState scripts;
  std::string id, profile;
  std::string opener;
  NSString* creationURL = nil;
  NSString* title = @"";
  bool foreground = true;
  NSDictionary* popupSource = nil;
  NSDictionary* extensionCreation = nil;
  bool creationAnnounced = false;
  // Only a client-created, empty endpoint may manufacture a bootstrap load.
  // A native popup owns its pending navigation even before HasDocument is true.
  bool scriptBootstrapAllowed = false;
  CefRefPtr<CefBrowser> browser;
  CefRefPtr<CefBrowserView> view;
  CefRefPtr<CefWindow> window;
  CefRefPtr<CefRegistration> observer;
  NSWindow* native = nil;
  bool nativeExtensions = false;
  // A Chrome-created window (popup, tab in a Chrome window) has frame or
  // toolbar around the page: fit the page view to the requested size.
  bool fitPage = false;
  // Chrome's DevTools frontend for this page, and whether this tab is one.
  std::string devToolsFront; bool devToolsFrontend = false;
  bool adopted = true, closing = false, visible = true, internal = false, themeReady = false, crashed = false, transportReady = false, domainsReady = false;
  double themeAttempt = 0;
  double width = 800, height = 600, scale = 1;
  NSString* lastLayer = nil;
  OwnCEFSurface surface;
  bool externallyHosted = false;
  bool externalPage = false;
  NSString* nativePageToken = nil;
  NSDictionary* nativePageReceipt = nil;
  bool audible = false, focused = false, discarded = false, frozen = false;
  NSDictionary* textState = nil;
  NSString* closeOwner = nil;
  NSString* closeWireRequest = nil;
  NSDictionary* closePreflight = nil;
  NSString* backgroundColor = nil;
  NSString* resizeSerial = nil;
  int resizeWidth = 0, resizeHeight = 0;
  int selectToken = 0;
  NSString* createRequest = nil;
  NSString* extensionPath = nil;
  bool extensionLoadPending = false;
  pid_t rendererPID = 0;
  uint64_t rendererBorn = 0;
  uint64_t documentGeneration = 0;
  bool drmReady = false, drmInstalling = false;
  std::vector<Completion> drmWaiters;
  std::string drmMainFrame;
  std::map<int, std::string> drmFrames;
  std::map<std::string, int> worlds;
  std::map<int, std::string> contextNames;
  std::map<std::string, std::set<std::string>> bindings;
};
struct Pending { int browser; Completion completion; double deadline; };
static Transport wire;
static NSString* dataRoot;
static std::map<std::string, Profile> profiles;
static std::map<std::string, Tab> tabs;
static std::map<int, std::string> browserTabs;
static std::map<int, Pending> pending;
static std::map<std::string, double> requests;
static int sequence = 0, tabSequence = 0;
static bool hello = false, stopping = false;
static void OriginalPDFBrowserClosed(int browser, NSString* reason);
static void ClearOriginalPDF();
static void OriginalPDFPresenceSuspend(int browser);
static void OriginalPDFPresenceClosed(int browser);
static void ClearOriginalPDFPresence();
static void OriginalPDFPresenceDocumentEnded(CefRefPtr<CefBrowser> browser);

static int nativeCloseDepth = 0;
static bool contextInitialized = false, shutdownStarted = false;
static NSTimer* timer;
static double lastPoll = 0;
static Tab* Find(CefRefPtr<CefBrowser> browser) {
  if (!browser) return nullptr;
  auto i = browserTabs.find(browser->GetIdentifier());
  if (i == browserTabs.end()) return nullptr;
  auto t = tabs.find(i->second); return t == tabs.end() ? nullptr : &t->second;
}
static bool IsReadTab(const Tab* tab);
static void Event(NSString* name, Tab* tab, NSDictionary* payload = @{}) {
  if (IsReadTab(tab) && ![name hasPrefix:@"read.page."]) return;
  if (!hello) return;
  NSMutableDictionary* p = [payload mutableCopy];
  if (tab) p[@"tab"] = @(tab->id.c_str());
  wire.Send(@{@"v": @1, @"event": name, @"params": p});
}
#include "owncef_surface.inc"
#include "owncef_page.inc"
static void Reply(NSString* id, ::id result = @{}, NSString* error = nil) {
  if (!id || requests.erase(Key(id)) == 0) return;
  if (getenv("YAB_CEF_TRACE_CDP")) fprintf(stderr, "YabCore reply id=%s error=%s\n", id.UTF8String, error ? error.UTF8String : "-");
  NSMutableDictionary* value = [@{@"v": @1, @"id": id} mutableCopy];
  if (error) {
    value[@"error"] = @{@"code": @"operation_failed", @"message": error};
    // Failures are otherwise visible only to the client; keep them in the helper log too.
    fprintf(stderr, "YabCore error reply: %s\n", [error substringToIndex:MIN(error.length, (NSUInteger)300)].UTF8String);
  }
  else value[@"result"] = result ?: NSNull.null;
  wire.Send(value);
}
static void CDP(Tab& t, NSString* method, NSDictionary* params, Completion completion, NSString* session = @"") {
  if (!t.browser || t.closing || !t.transportReady) { completion(nil, @"Tab DevTools is not ready or is closing"); return; }
  if (pending.size() >= 256) { completion(nil, @"Too many pending CDP calls"); return; }
  auto v = CefParseJSON(Key(JSON(params)), JSON_PARSER_RFC);
  int id = ++sequence;
  if (getenv("YAB_CEF_TRACE_CDP")) fprintf(stderr, "YabCore CDP send id=%d browser=%d window=%ld internal=%d method=%s\n", id, t.browser->GetIdentifier(), (long)t.native.windowNumber, t.internal, method.UTF8String);
  pending.emplace(id, Pending{t.browser->GetIdentifier(), completion, Now() + 15});
  int sent;
  if (session.length) {
    NSString* message = JSON(@{@"id": @(id), @"method": method, @"params": params, @"sessionId": session});
    sent = t.browser->GetHost()->SendDevToolsMessage(message.UTF8String, [message lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
  } else sent = t.browser->GetHost()->ExecuteDevToolsMethod(id, Key(method), v ? v->GetDictionary() : nullptr);
  if (!sent) { pending.erase(id); completion(nil, @"CDP rejected command"); }
}
static void Ignore(NSDictionary*, NSString*) {}
// A shutdown request and the peer's disconnect both end the run; the message
// loop may be asked to quit only once (a second call trips CEF's context check).
static void QuitOnce() {
  static bool quit = false;
  if (quit) return;
  quit = true;
  CefQuitMessageLoop();
}
static void Eval(Tab& t, NSString* expression, int context, Completion completion, bool userGesture = false) {
  NSMutableDictionary* p = [@{@"expression": expression, @"returnByValue": @YES, @"awaitPromise": @YES} mutableCopy];
  if (userGesture) p[@"userGesture"] = @YES;
  if (context) p[@"contextId"] = @(context);
  CDP(t, @"Runtime.evaluate", p, [completion](NSDictionary* r, NSString* e) {
    if (e) { completion(nil, e); return; }
    if (r[@"exceptionDetails"]) { completion(nil, [@"JavaScript exception: " stringByAppendingString:JSON(r[@"exceptionDetails"])]); return; }
    completion(r, nil);
  });
}
static NSString* ScriptBridge(NSArray* names);
static void WithWorld(std::string id, NSString* world, std::function<void(Tab&, int)> action, Completion failure) {
  auto i = tabs.find(id);
  if (i == tabs.end()) { failure(nil, @"Tab closed"); return; }
  // New-document scripts already made their named worlds. Use that same
  // main-frame context when a native consumer calls into the script later.
  for (const auto& [key, context] : i->second.scripts.contexts) {
    if (!context.session.length && [context.frame isEqual:i->second.scripts.mainFrame] && [context.world isEqual:world]) {
      action(i->second, context.id); return;
    }
  }
  auto existing = i->second.worlds.find(Key(world));
  if (existing != i->second.worlds.end()) { action(i->second, existing->second); return; }
  CDP(i->second, @"Page.getFrameTree", @{}, [id, world, action, failure](NSDictionary* result, NSString* error) {
    if (error) { failure(nil, error); return; }
    auto t = tabs.find(id); if (t == tabs.end()) { failure(nil, @"Tab closed"); return; }
    NSString* frame = result[@"frameTree"][@"frame"][@"id"];
    if (!frame) { failure(nil, @"Main frame not available"); return; }
    // No universal cross-origin access is granted to an isolated world.
    CDP(t->second, @"Page.createIsolatedWorld", @{@"frameId": frame, @"worldName": world},
      [id, world, action, failure](NSDictionary* r, NSString* e) {
        auto j = tabs.find(id);
        if (e || j == tabs.end()) { failure(nil, e ?: @"Tab closed"); return; }
        int context = [r[@"executionContextId"] intValue];
        if (!context) { failure(nil, @"No isolated context"); return; }
        j->second.worlds[Key(world)] = context; j->second.contextNames[context] = Key(world);
        // A world created after load missed its new-document relay script.
        // Live features (dark pages enabled on an already-open light site)
        // need the same authenticated binding before their first request.
        NSArray* names = j->second.scripts.relays[world];
        if (!names.count) { action(j->second, context); return; }
        NSString* bridge = [NSString stringWithFormat:@"if(!globalThis.__yabScriptReply){%@}", ScriptBridge(names)];
        Eval(j->second, bridge, context, [id, context, action, failure](NSDictionary*, NSString* error) {
          auto current = tabs.find(id);
          if (error || current == tabs.end()) { failure(nil, error ?: @"Tab closed"); return; }
          action(current->second, context);
        });
      });
  });
}
#include "scripts.inc"
#include "agents.inc"
#include "drm.inc"
#include "drm_cookies.inc"
#include "ext_bridge.inc"
#include "core_readiness.inc"
#include "ext_actions.inc"

static NSWindow* Native(CefRefPtr<CefWindow> w) {
  NSView* v = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(w->GetWindowHandle());
  return [(id)v isKindOfClass:NSWindow.class] ? (NSWindow*)(id)v : v.window;
}
static NSView* FindView(NSView* v, NSString* name) {
  if ([NSStringFromClass(v.class) isEqual:name]) return v;
  for (NSView* child in v.subviews) { NSView* found = FindView(child, name); if (found) return found; }
  return nil;
}
// This private walk is confined to YabCore, never exposed in the client.
static void Layers(CALayer* layer, NSView* owner, NSMutableArray* rows, int depth) {
  if (!layer || depth > 60) return;
  if ([NSStringFromClass(layer.class) isEqual:@"CALayerHost"]) {
    NSNumber* context = [layer valueForKey:@"contextId"];
    if (context.unsignedIntValue) [rows addObject:@{@"contextId": context, @"view": NSStringFromClass(owner.class)}];
  }
  for (CALayer* sub in layer.sublayers) {
    if ([sub.delegate isKindOfClass:NSView.class] && (id)sub.delegate != (id)owner) continue;
    Layers(sub, owner, rows, depth + 1);
  }
}
static void ViewLayers(NSView* view, NSMutableArray* rows, int depth) {
  if (!view || depth > 60) return;
  Layers(view.layer, view, rows, 0);
  for (NSView* child in view.subviews) ViewLayers(child, rows, depth + 1);
}
static uint32_t Context(NSWindow* w) {
  NSMutableArray* rows = [NSMutableArray new];
  ViewLayers(w.contentView.superview ?: w.contentView, rows, 0);
  for (NSDictionary* row in rows) if ([row[@"view"] isEqual:@"BridgedContentView"]) return [row[@"contextId"] unsignedIntValue];
  for (NSDictionary* row in rows) if ([row[@"view"] isEqual:@"RenderWidgetHostViewCocoa"]) return [row[@"contextId"] unsignedIntValue];
  return 0;
}
// The window is never seen or pressed: its page is given the app's own events
// by sendEvent:. An NSWindow hands a mouse-moved event to its views only when
// it accepts them, so a page behind it would hear no pointer move at all.
static void Conceal(NSWindow* w) { if (w) { w.alphaValue = 0; w.ignoresMouseEvents = YES; w.acceptsMouseMovedEvents = YES; } }
// Physical WindowServer state is independent of CEF's logical visibility.
static NSNumber* WindowOnScreen(NSWindow* window) {
  if (!window) return nil;
  NSArray* rows = CFBridgingRelease(CGWindowListCopyWindowInfo(
      kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
      kCGNullWindowID));
  if (!rows) return nil;
  for (NSDictionary* row in rows) {
    if ([row[(__bridge NSString*)kCGWindowNumber] integerValue] == window.windowNumber &&
        [row[(__bridge NSString*)kCGWindowOwnerPID] intValue] == NSProcessInfo.processInfo.processIdentifier)
      return @YES;
  }
  return @NO;
}
static void State(Tab* t, NSDictionary* fields) { if (t && !t->internal) Event(@"page.state", t, fields); }
static void InstallTheme(std::string id) {
  auto tab = tabs.find(id);
  if (tab == tabs.end() || tab->second.closing || tab->second.crashed ||
      !tab->second.browser || !tab->second.transportReady || !tab->second.browser->HasDocument()) return;
  tab->second.themeAttempt = Now();
  Completion fail = [](NSDictionary*, NSString* e) { if (e) fprintf(stderr, "YabCore theme world: %s\n", e.UTF8String); };
  WithWorld(id, @"__yab_state", [](Tab& tab, int context) {
    tab.bindings["__yabTheme"].insert("__yab_state");
    CDP(tab, @"Runtime.addBinding", @{@"name": @"__yabTheme", @"executionContextName": @"__yab_state"},
      [id = tab.id, context](NSDictionary*, NSString* e) {
        auto i = tabs.find(id); if (e || i == tabs.end()) return;
        Eval(i->second, @"(()=>{const get=()=>document.querySelector('meta[name=\"theme-color\"]')?.content??null;if(!globalThis.__themeObserver){let previous=get();const f=()=>{const color=get();if(color!==previous){previous=color;__yabTheme(JSON.stringify({color}))}};globalThis.__themeObserver=new MutationObserver(f);__themeObserver.observe(document.documentElement,{subtree:true,attributes:true,childList:true})}return {color:get()}})()", context,
          [id](NSDictionary* result, NSString* error) {
            auto t = tabs.find(id); if (t == tabs.end()) return;
            if (error) { fprintf(stderr, "YabCore theme snapshot: %s\n", error.UTF8String); return; }
            NSDictionary* value = result[@"result"][@"value"];
            if (![value isKindOfClass:NSDictionary.class]) return;
            t->second.themeReady = true;
            State(&t->second, @{@"themeColor": value[@"color"] ?: NSNull.null});
          });
      });
  }, fail);
}
static void CancelPending(int browser, NSString* reason) {
  std::vector<Completion> callbacks;
  for (auto i = pending.begin(); i != pending.end();) {
    if (i->second.browser == browser) { callbacks.push_back(i->second.completion); i = pending.erase(i); }
    else ++i;
  }
  // Also called from DevTools observer callbacks; see OnDevToolsMethodResult.
  for (auto& c : callbacks) {
    // Blocks capture a C++ reference variable by reference, not its referent.
    // The vector dies on return, so give each queued block its own callable.
    Completion completion = std::move(c);
    dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, reason); });
  }
}
class Observer : public CefDevToolsMessageObserver {
 public:
  bool OnDevToolsMessage(CefRefPtr<CefBrowser> browser, const void* bytes, size_t size) override {
    NSDictionary* message = Decode(bytes, size);
    NSString* session = S(message, @"sessionId");
    if (!session.length) return false;
    auto tab = Find(browser); if (!tab) return true;
    if (message[@"id"]) {
      auto found = pending.find([message[@"id"] intValue]);
      if (found != pending.end() && found->second.browser == browser->GetIdentifier()) {
        auto completion = found->second.completion; pending.erase(found);
        id result = message[@"result"]; NSString* error = message[@"error"] ? JSON(message[@"error"]) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(result, error); });
      }
    } else ScriptEvent(*tab, S(message, @"method"), message[@"params"] ?: @{}, session);
    return true;
  }
  void OnDevToolsMethodResult(CefRefPtr<CefBrowser>, int id, bool success, const void* bytes, size_t size) override {
    if (getenv("YAB_CEF_TRACE_CDP")) fprintf(stderr, "YabCore CDP result id=%d success=%d bytes=%zu\n", id, success, size);
    auto p = pending.find(id); if (p == pending.end()) return;
    auto completion = p->second.completion; pending.erase(p);
    NSDictionary* value = Decode(bytes, size);
    // Completions often send the next CDP command. Sending it from inside
    // CEF's observer notification nests a second notification whenever the
    // agent answers synchronously, which trips Chromium's observer-list
    // reentrancy check (seen in extension options pages and at shutdown).
    // The main queue keeps results in arrival order.
    dispatch_async(dispatch_get_main_queue(), ^{ completion(success ? value : nil, success ? nil : JSON(value)); });
  }
  void OnDevToolsEvent(CefRefPtr<CefBrowser> browser, const CefString& method, const void* bytes, size_t size) override {
    Tab* t = Find(browser); if (!t) return;
    NSString* m = Str(method); NSDictionary* p = Decode(bytes, size);
    ScriptEvent(*t, m, p, @"");
    if (ExtensionBridgeEvent(*t, m, p)) return;
    if ([m isEqual:@"Runtime.executionContextsCleared"] || [m isEqual:@"Page.frameNavigated"]) {
      if ([m isEqual:@"Page.frameNavigated"] && p[@"frame"][@"parentId"]) return;
      ++t->documentGeneration;
      t->worlds.clear(); t->contextNames.clear(); t->drmFrames.clear();
      if ([m isEqual:@"Page.frameNavigated"]) t->drmMainFrame = Key(S(p[@"frame"], @"id"));
    } else if ([m isEqual:@"Runtime.executionContextCreated"]) {
      NSDictionary* c = p[@"context"]; NSString* name = S(c, @"name");
      if (name.length) t->contextNames[[c[@"id"] intValue]] = Key(name);
      if ([c[@"auxData"][@"isDefault"] boolValue]) t->drmFrames[[c[@"id"] intValue]] = Key(S(c[@"auxData"], @"frameId"));
    } else if ([m isEqual:@"Runtime.executionContextDestroyed"]) {
      int context = [p[@"executionContextId"] intValue]; t->contextNames.erase(context); t->drmFrames.erase(context);
      for (auto i = t->worlds.begin(); i != t->worlds.end();) { if (i->second == context) i = t->worlds.erase(i); else ++i; }
    } else if ([m isEqual:@"Runtime.bindingCalled"]) {
      NSString* name = S(p, @"name"); int context = [p[@"executionContextId"] intValue];
      if ([name isEqual:@"__yabWidevineRejected"]) {
        auto frame = t->drmFrames.find(context);
        if (frame == t->drmFrames.end() || t->drmMainFrame.empty() || frame->second != t->drmMainFrame) return;
        NSDictionary* value = Decode(S(p, @"payload").UTF8String, [S(p, @"payload") lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
        if ([S(value, @"keySystem") isEqual:@"com.widevine.alpha"])
          Event(@"drm.unavailable", t, @{@"keySystem": @"com.widevine.alpha", @"url": Str(browser->GetMainFrame()->GetURL())});
        return;
      }
      auto w = t->contextNames.find(context);
      if (w == t->contextNames.end()) return;
      auto binding = t->bindings.find(Key(name));
      if (binding == t->bindings.end() || !binding->second.count(w->second)) return;
      NSData* data = [S(p, @"payload") dataUsingEncoding:NSUTF8StringEncoding];
      id value = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:nil] ?: NSNull.null;
      if ([name isEqual:@"__yabTheme"]) { if ([value isKindOfClass:NSDictionary.class]) State(t, @{@"themeColor": value[@"color"] ?: NSNull.null}); }
      else Event(@"script.message", t, @{@"world": @(w->second.c_str()), @"name": name, @"value": value});
    }
  }
  void OnDevToolsAgentAttached(CefRefPtr<CefBrowser> browser) override {
    auto tab = Find(browser); if (!tab || tab->closing) return;
    std::string id = tab->id;
    fprintf(stderr, "YabCore DevTools agent attached: %s url=%s\n", id.c_str(), Key(Str(browser->GetMainFrame()->GetURL())).c_str());
    // Never dispatch recursively while CEF is attaching its DevTools agent.
    // Cached profiles can create the browser synchronously inside a Views callback.
    dispatch_async(dispatch_get_main_queue(), ^{
      auto found = tabs.find(id); if (found == tabs.end() || found->second.closing) return;
      Tab& t = found->second;
      ScriptAttach(t, @"", [id](NSDictionary*, NSString* error) {
        auto current = tabs.find(id); if (current == tabs.end() || current->second.closing) return;
        current->second.domainsReady = !error;
        if (error) { Event(@"script.error", &current->second, @{@"message": error}); return; }
        // The first document may have committed before this agent existed,
        // so no Page.frameNavigated was seen: learn the main frame now.
        CDP(current->second, @"Page.getFrameTree", @{}, [id](NSDictionary* tree, NSString* treeError) {
          auto found = tabs.find(id);
          if (treeError || found == tabs.end() || found->second.closing || !found->second.drmMainFrame.empty()) return;
          NSString* frameID = S(tree[@"frameTree"][@"frame"], @"id");
          if (frameID.length) found->second.drmMainFrame = Key(frameID);
        });
        if (!current->second.drmReady && !current->second.internal) InstallDRM(current->second, Ignore, true);
      });
      for (auto& [name, worlds] : t.bindings) for (const auto& world : worlds) {
        CDP(t, @"Runtime.addBinding", @{@"name": @(name.c_str()), @"executionContextName": @(world.c_str())}, Ignore);
      }
    });
  }
  void OnDevToolsAgentDetached(CefRefPtr<CefBrowser> browser) override {
    OriginalPDFPresenceClosed(browser->GetIdentifier());
    OriginalPDFBrowserClosed(browser->GetIdentifier(), @"Original PDF renderer detached");
    fprintf(stderr, "YabCore DevTools agent detached: browser %d\n", browser->GetIdentifier());
    if (auto t = Find(browser)) { ++t->documentGeneration; t->drmReady = false; t->drmFrames.clear(); t->domainsReady = false; t->worlds.clear(); t->contextNames.clear(); t->scripts.contexts.clear(); t->scripts.sessions.clear(); t->scripts.identifiers.clear(); }
    CancelPending(browser->GetIdentifier(), @"Renderer detached");
  }
  IMPLEMENT_REFCOUNTING(Observer);
};
static NSDictionary* NativeHookCapabilities();
static NSDictionary* CreatedState(Tab& t) {
  NSString* url = t.browser ? Str(t.browser->GetMainFrame()->GetURL()) : @"";
  auto profile = profiles.find(t.profile);
  NSMutableDictionary* result = [@{@"profile": @(t.profile.c_str()), @"private": @(profile != profiles.end() && profile->second.privateMode),
    @"opener": t.opener.empty() ? (id)NSNull.null : @(t.opener.c_str()), @"foreground": @(t.foreground),
    @"mustAdopt": @YES, @"source": t.popupSource ?: (id)NSNull.null,
    @"url": url.length ? url : (t.creationURL ?: @"about:blank")} mutableCopy];
  if (t.extensionCreation) result[@"extensionCreation"] = t.extensionCreation;
  result[@"creationPurpose"] = t.extensionCreation ? @"extension" : t.popupSource ? @"popup" : t.adopted ? @"client" : @"unrequested";
  return result;
}
#include "tab_creation.inc"
static void Attach(CefRefPtr<CefBrowser> b, std::string profile, std::string preferred,
                   std::string opener = "", NSString* creationURL = nil, bool foreground = true, NSDictionary* source = nil) {
  if (browserTabs.count(b->GetIdentifier())) return;
  // Always derive ownership from the actual native request context. A popup
  // may inherit a Client from its opener while Chrome chooses another context.
  profile.clear();
  for (auto& [key, p] : profiles) if (b->GetHost()->GetRequestContext()->IsSame(p.context)) { profile = key; break; }
  auto t = tabs.find(preferred);
  bool spawned = t == tabs.end() || t->second.browser;
  if (getenv("YAB_CEF_TRACE_CDP")) {
    fprintf(stderr, "YabCore creation: %s\n", JSON(@{@"at": @(Now()), @"browser": @(b->GetIdentifier()),
      @"preferred": @(preferred.c_str()), @"spawned": @(spawned), @"profile": @(profile.c_str()),
      @"nativeOpener": @(b->GetHost()->GetOpenerIdentifier()), @"opener": @(opener.c_str()),
      @"creationURL": creationURL ?: (id)NSNull.null, @"url": Str(b->GetMainFrame()->GetURL()),
      @"source": source ?: (id)NSNull.null}).UTF8String);
    if (spawned) fprintf(stderr, "YabCore creation stack: %s\n", NSThread.callStackSymbols.description.UTF8String);
  }
  if (spawned) {
    preferred = "tab-" + std::to_string(++tabSequence);
    Tab value; value.id = preferred; value.profile = profile; value.adopted = false;
    auto nativeOpener = browserTabs.find(b->GetHost()->GetOpenerIdentifier());
    value.opener = nativeOpener != browserTabs.end() ? nativeOpener->second : opener;
    value.creationURL = creationURL; value.foreground = foreground;
    value.popupSource = source;
    value.fitPage = true;
    t = tabs.emplace(preferred, std::move(value)).first;
  }
  t->second.browser = b;
  browserTabs[b->GetIdentifier()] = preferred;
  if (stopping || profile.empty()) { t->second.closing = true; b->GetHost()->CloseBrowser(true); return; }
#if YABCORE_NATIVE_PAGE
  // The SDK already bound its exact native Browser before OnAfterCreated.
  // Refuse an unbound default client before tab.created, not a geometry fallback.
  if (spawned && !CefBrowserView::GetForBrowser(b) && !AttachNativePage(t->second)) {
    t->second.closing = true;
    b->GetHost()->CloseBrowser(true);
    return;
  }
#endif
  t->second.observer = b->GetHost()->AddDevToolsMessageObserver(new Observer);
  dispatch_async(dispatch_get_main_queue(), ^{
    auto current = tabs.find(preferred); if (current == tabs.end() || current->second.closing) return;
    current->second.transportReady = true;
    // The native endpoint can accept LoadURL now. Page.enable can wait for
    // the first real renderer document; waiting for it here would prevent
    // that very first navigation on CEF's empty, unnavigated bootstrap.
    NSString* request = current->second.createRequest;
    current->second.createRequest = nil;
    if (request) Reply(request, @{@"tab": @(preferred.c_str())});
    CDP(current->second, @"Page.enable", @{}, Ignore);
  });
  if (spawned) FinishNativeCreation(preferred);
#if YABCORE_NATIVE_PAGE
  if (t->second.externalPage) PublishOwnCEFSurface(t->second);
#endif
}
#include "navigation.inc"
#include "print_find.inc"
#include "permissions.inc"
#include "questions.inc"
#include "agent_dialogs.inc"
#include "certificates.inc"
#include "owncef_native.inc"
#include "native_text_input.inc"
#include "original_pdf.inc"
#include "original_pdf_presence.inc"
#include "owncef_files.inc"
#include "downloads.inc"
#include "history.inc"
#include "media.inc"
#include "health.inc"
#include "context_menu.inc"
#include "lifecycle.inc"
#include "native_switch_group.inc"
#include "html_load.inc"

#include "request_read.inc"

class Client : public CefClient, public CefLifeSpanHandler, public CefLoadHandler, public CefDisplayHandler, public CefRequestHandler, public CefDialogHandler, public CefJSDialogHandler, public CefFindHandler, public CefPermissionHandler, public CefDownloadHandler, public CefContextMenuHandler {
  std::string profile_, tab_, opener_;
  NSString* creationURL_;
  bool foreground_;
  NSDictionary* popupSource_;
 public:
  Client(std::string profile, std::string tab, std::string opener = "", NSString* url = nil, bool foreground = true, NSDictionary* source = nil)
    : profile_(profile), tab_(tab), opener_(opener), creationURL_(url), foreground_(foreground), popupSource_(source) {}
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame>, CefRefPtr<CefRequest>,
      bool is_navigation, bool, const CefString&, bool&) override {
    if (auto policy = ReadPolicyForBrowser(b)) return new ReadResourceGuard(std::move(policy));
    return HTMLRequestHandler(b, is_navigation);
  }
  CefRefPtr<CefDialogHandler> GetDialogHandler() override { return this; }
  CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }
  bool OnJSDialog(CefRefPtr<CefBrowser> b, const CefString& origin, JSDialogType type,
      const CefString& message, const CefString& text, CefRefPtr<CefJSDialogCallback> callback,
      bool& suppress) override {
    if (IsReadBrowser(b)) { suppress = true; return false; }
    return OpenNativeDialog(Find(b), Str(origin), type == JSDIALOGTYPE_ALERT ? @"alert" :
      type == JSDIALOGTYPE_CONFIRM ? @"confirm" : @"prompt", Str(message), Str(text), callback, suppress);
  }
  bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser> b, const CefString& message, bool,
      CefRefPtr<CefJSDialogCallback> callback) override {
    if (IsReadBrowser(b)) { callback->Continue(false, CefString()); return true; }
    bool suppress = false;
    return OpenNativeDialog(Find(b), Str(b->GetMainFrame()->GetURL()), @"beforeunload",
      Str(message), @"", callback, suppress);
  }
  void OnResetDialogState(CefRefPtr<CefBrowser> b) override {
    if (auto tab = Find(b)) CancelNativeDialogs(tab->id);
  }
  bool OnSelectClientCertificate(CefRefPtr<CefBrowser> b, bool, const CefString&, int,
      const X509CertificateList&, CefRefPtr<CefSelectClientCertificateCallback> callback) override {
    if (!IsReadBrowser(b)) return false;
    callback->Select(nullptr); return true;
  }
  bool CanDownload(CefRefPtr<CefBrowser> b, const CefString&, const CefString&) override {
    return !IsReadBrowser(b);
  }
  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame> frame,
                                CefProcessId source, CefRefPtr<CefProcessMessage> message) override {
    if (source == PID_RENDERER && HealthMessage(Find(b), frame, message)) return true;
    if (source == PID_RENDERER && MediaFrameMessage(Find(b), frame, message)) return true;
    if (source != PID_RENDERER || !frame || !frame->IsValid() || !frame->IsMain() || message->GetName() != "yab.media.renderer") return false;
    auto t = Find(b); if (!t) return true;
    auto args = message->GetArgumentList();
    if (args->GetSize() != 1 || args->GetType(0) != VTYPE_INT) return true;
    pid_t pid = args->GetInt(0);
    struct proc_bsdinfo info = {};
    if (pid <= 0 || proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info) || info.pbi_ppid != getpid()) return true;
    // Isolated worlds create contexts too. Their repeated PID report must
    // not cancel an input challenge for the very same renderer.
    if (t->rendererPID != pid) HealthReset(t, true);
    t->rendererPID = pid;
    t->rendererBorn = info.pbi_start_tvsec * 1000000ULL + info.pbi_start_tvusec;
    State(t, @{ @"rendererPID": @(pid), @"nativeDiscard": NativeHookCapabilities()[@"nativeDiscard"],
      @"audible": @(t->audible), @"audibleSource": YABCORE_NATIVE_AUDIBLE ? @"native" : @"page" });
    return true;
  }
  CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }
  bool RunContextMenu(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame> frame, CefRefPtr<CefContextMenuParams> params,
                      CefRefPtr<CefMenuModel> model, CefRefPtr<CefRunContextMenuCallback> callback) override {
    if (IsReadBrowser(b)) { callback->Cancel(); return true; }
    return OpenPageMenu(Find(b), frame, params, model, callback);
  }
  bool OnBeforeDownload(CefRefPtr<CefBrowser> b, CefRefPtr<CefDownloadItem> item,
      const CefString& name, CefRefPtr<CefBeforeDownloadCallback> callback) override {
    if (IsReadBrowser(b)) return true; // Never fall back to Chrome download UI.
    return BeginDownload(Find(b), item, Str(name), callback);
  }
  void OnDownloadUpdated(CefRefPtr<CefBrowser> b, CefRefPtr<CefDownloadItem> item,
      CefRefPtr<CefDownloadItemCallback> callback) override { UpdateDownload(b, item, callback); }
  bool OnCertificateError(CefRefPtr<CefBrowser> b, cef_errorcode_t code, const CefString& url,
      CefRefPtr<CefSSLInfo> info, CefRefPtr<CefCallback> callback) override {
    if (IsReadBrowser(b)) return false;
    return AskCertificate(Find(b), code, Str(url), info, callback);
  }
  bool GetAuthCredentials(CefRefPtr<CefBrowser> b, const CefString& origin, bool proxy,
                          const CefString& host, int port, const CefString& realm,
                          const CefString& scheme, CefRefPtr<CefAuthCallback> callback) override {
    if (IsReadBrowser(b)) { callback->Cancel(); return true; }
    AskAuthentication(b, Str(origin), proxy, Str(host), port, Str(realm), Str(scheme), callback);
    return true;
  }
  bool OnRequestMediaAccessPermission(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame> frame,
      const CefString& origin, uint32_t mask, CefRefPtr<CefMediaAccessCallback> callback) override {
    if (IsReadBrowser(b)) { if (callback) callback->Cancel(); return true; }
    auto* tab = Find(b);
    auto frameBrowser = frame && frame->IsValid() ? frame->GetBrowser() : nullptr;
    const bool sameBrowserFrame = tab && tab->browser && tab->browser->IsSame(b) &&
        frameBrowser && frameBrowser->IsSame(b);
    return AskMedia(tab, Str(origin), mask, callback, sameBrowserFrame);
  }
  bool OnShowPermissionPrompt(CefRefPtr<CefBrowser> b, uint64_t prompt, const CefString& origin,
      uint32_t mask, CefRefPtr<CefPermissionPromptCallback> callback) override {
    if (IsReadBrowser(b)) { callback->Continue(CEF_PERMISSION_RESULT_DENY); return true; }
    return AskPermission(Find(b), prompt, Str(origin), mask, callback);
  }
  void OnDismissPermissionPrompt(CefRefPtr<CefBrowser> b, uint64_t prompt, cef_permission_request_result_t) override {
    DismissPermission(Find(b), prompt);
  }
  void OnFindResult(CefRefPtr<CefBrowser> b, int identifier, int count,
                    const CefRect&, int ordinal, bool final) override {
    NativeFindResult(Find(b), identifier, count, ordinal, final);
  }
#if YABCORE_NATIVE_FILE_SOURCE
  bool OnFileDialogForFrame(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame> frame,
      CefRefPtr<CefDictionaryValue> source, const CefString&, const CefString&,
      CefRefPtr<CefFileDialogCallback> callback) override {
    if (IsReadBrowser(b)) { callback->Cancel(); return true; }
    return NativeFileDialog(Find(b), b, frame, source, callback);
  }
  void OnFileDialogClosed(CefRefPtr<CefBrowser> b, const CefString& request,
      const CefString&) override { NativeFileClosed(Find(b), request); }
#endif
  bool OnFileDialog(CefRefPtr<CefBrowser> b, FileDialogMode mode,
                    const CefString&, const CefString&,
                    const std::vector<CefString>&, const std::vector<CefString>&,
                    const std::vector<CefString>&,
                    CefRefPtr<CefFileDialogCallback> callback) override {
    if (IsReadBrowser(b)) { callback->Cancel(); return true; }
    auto t = Find(b);
    if (!t || !t->extensionPath || ![Str(b->GetMainFrame()->GetURL()) isEqual:@"chrome://extensions/"]) return OpenFilePick(t, mode, callback);
    NSString* path = t->extensionPath;
    t->extensionPath = nil;
    callback->Continue({CefString(Key(path))});
    return true;
  }
  bool OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int,
      const CefString& target, const CefString&, WindowOpenDisposition disposition, bool gesture,
      const CefPopupFeatures& features, CefWindowInfo&, CefRefPtr<CefClient>& client,
      CefBrowserSettings&, CefRefPtr<CefDictionaryValue>&, bool*) override {
    auto owner = Find(browser);
    if (IsReadBrowser(browser) || stopping || !owner || owner->closing || tabs.size() >= 256) return true;
    // The disposition comes from Chromium's actual child WebContents, not
    // the target URL or a page binding. Preserve that live browser for PiP.
    NSDictionary* source = @{@"url": frame ? Str(frame->GetURL()) : @"", @"main": @(frame && frame->IsMain()), @"gesture": @(gesture),
      @"documentPiP": @(disposition == CEF_WOD_NEW_PICTURE_IN_PICTURE),
      @"width": @(features.widthSet ? features.width : 480), @"height": @(features.heightSet ? features.height : 320)};
    client = new Client(owner->profile, "", owner->id, Str(target), disposition != CEF_WOD_NEW_BACKGROUND_TAB, source);
    return false;
  }
  void OnAfterCreated(CefRefPtr<CefBrowser> b) override {
    // Chrome can reuse a Browser's Client when restoring/adding WebContents.
    // The original tab.create or OnBeforePopup request authorizes one browser.
    auto tab = tab_; tab_.clear();
    auto opener = opener_; opener_.clear();
    NSString* url = creationURL_; creationURL_ = nil;
    NSDictionary* source = popupSource_; popupSource_ = nil;
    Attach(b, profile_, tab, opener, url, foreground_, source);
  }
  void OnBeforeClose(CefRefPtr<CefBrowser> b) override {
#if YABCORE_CLOSE_PREFLIGHT
    NativeCloseScope closeScope;
#endif
    OriginalPDFPresenceClosed(b->GetIdentifier());
    OriginalPDFBrowserClosed(b->GetIdentifier(), @"Original PDF browser closed");
    NativeTextInputClosed(b);
    ReadPageClosed(b);
    if (getenv("YAB_CEF_TRACE_CDP")) fprintf(stderr, "YabCore closing: browser=%d at=%.6f\n", b->GetIdentifier(), Now());
    CancelPending(b->GetIdentifier(), @"Tab closed");
    auto t = Find(b); if (t) {
#if YABCORE_EXTENSION_HOOKS
      NativeExtensionOwnerClosed(t);
#endif
#if YABCORE_CLOSE_PREFLIGHT
      LifecycleBeforeClose(*t);
#endif
      Event(@"tab.closed", t); std::string id = t->id;
      CancelFilePick(id); CancelQuestions(id); CancelPageMenu(id);
      for (auto i = authAttempts.begin(); i != authAttempts.end();) {
        if (i->first.rfind(id + "|", 0) == 0) i = authAttempts.erase(i); else ++i;
      }
      CancelPrintFind(*t, @"Tab closed"); nativeFinds.erase(id); MediaForget(id);
      t->observer = nullptr; t->browser = nullptr; t->window = nullptr; t->view = nullptr;
      tabs.erase(id); ForgetReadPage(id);
    }
    browserTabs.erase(b->GetIdentifier());
    if (stopping && tabs.empty()) QuitOnce();
  }
  void OnAddressChange(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame> frame, const CefString& url) override {
    if (frame->IsMain()) {
      if (auto t = Find(b)) t->themeReady = false;
      State(Find(b), @{@"url": Str(url)});
    }
  }
  void OnMediaAccessChange(CefRefPtr<CefBrowser> b, bool video, bool audio) override { MediaAccess(Find(b), video, audio); }
  void OnFullscreenModeChange(CefRefPtr<CefBrowser> b, bool fullscreen) override { MediaFullscreen(Find(b), fullscreen); }
#if YABCORE_NATIVE_VIDEO_PIP
  void OnNativeVideoPiPState(CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefDictionaryValue> state) override {
    NativePiPChanged(Find(browser), browser, state);
  }
#endif
#if YABCORE_NATIVE_CAPTURE_ACTIVITY
  void OnNativeCaptureState(CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefDictionaryValue> state) override {
    NativeCaptureChanged(Find(browser), browser, state);
  }
#endif
#if YABCORE_NATIVE_MEDIA_SESSION
  void OnNativeMediaSessionState(CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefDictionaryValue> state) override {
    NativeMediaChanged(Find(browser), browser, state);
  }
#endif
#if YABCORE_NATIVE_AUDIBLE
  void OnAudioStateChanged(CefRefPtr<CefBrowser> b, bool audible) override { NativeAudible(Find(b), audible); MediaNativeAudible(Find(b), audible); }
#endif
#if YABCORE_BACKGROUND_COLOR
  void OnBackgroundColorChange(CefRefPtr<CefBrowser> b, cef_color_t color, bool has) override { NativeBackground(Find(b), color, has); }
#endif
#if YABCORE_SELECT_MENU
  bool OnExternalSelectMenu(CefRefPtr<CefBrowser> b, CefRefPtr<CefDictionaryValue> menu) override { return NativeSelectOpen(Find(b), menu); }
  void OnExternalSelectMenuDismissed(CefRefPtr<CefBrowser> b, int token) override { NativeSelectClosed(Find(b), token); }
#endif
#if YABCORE_NATIVE_PRINT
  void OnPrintRequest(CefRefPtr<CefBrowser> b, CefRefPtr<CefDictionaryValue> request) override { NativePrintRequest(Find(b), request); }
  void OnPrintRequestWithdrawn(CefRefPtr<CefBrowser> b, const CefString& request) override { NativePrintWithdrawn(Find(b), request.ToString()); }
#endif
#if YABCORE_DISCARD_NOTIFY
  void OnPageDiscardedChange(CefRefPtr<CefBrowser> b, bool discarded) override { NativeDiscarded(Find(b), discarded); }
#endif
#if YABCORE_EXTENSION_HOOKS
  void OnExtensionPopup(CefRefPtr<CefBrowser> b, CefRefPtr<CefDictionaryValue> popup) override { NativeExtensionPopup(Find(b), popup); }
  void OnExtensionTabCreated(CefRefPtr<CefBrowser> b, CefRefPtr<CefDictionaryValue> info) override { NativeExtensionTab(Find(b), info); }
#if YABCORE_NATIVE_PAGE
  void OnExternalPageFrame(CefRefPtr<CefBrowser> b, CefRefPtr<CefDictionaryValue> state) override { NativePageFrame(Find(b), state); }
#endif
#endif
#if YABCORE_TEXT_INPUT
  void OnExternalTextInputState(CefRefPtr<CefBrowser> b, CefRefPtr<CefDictionaryValue> state) override { NativeTextState(Find(b), state); }
#endif
#if YABCORE_CLOSE_PREFLIGHT
  void OnClosePreflightState(CefRefPtr<CefBrowser> b, CefRefPtr<CefDictionaryValue> state) override { NativeClosePreflight(Find(b), state); }
#endif
  void OnTitleChange(CefRefPtr<CefBrowser> b, const CefString& title) override {
    if (auto t = Find(b)) { t->title = Str(title); State(t, @{@"title": t->title}); }
  }
  // The link under the pointer, as Chromium's status bubble says it. The app
  // admits it only after the pointer's own moves (ChromiumPage+Hover).
  void OnStatusMessage(CefRefPtr<CefBrowser> b, const CefString& value) override {
    auto t = Find(b); if (!t || t->internal) return;
    Event(@"page.hover", t, @{@"url": Str(value) ?: @""});
  }
  void OnFaviconURLChange(CefRefPtr<CefBrowser> b, const std::vector<CefString>& urls) override { State(Find(b), @{@"faviconURL": urls.empty() ? (id)NSNull.null : Str(urls[0])}); }
  void OnLoadingStateChange(CefRefPtr<CefBrowser> b, bool loading, bool back, bool forward) override {
    if (loading) Event(@"page.started", Find(b));
    State(Find(b), @{@"loading": @(loading), @"canGoBack": @(back), @"canGoForward": @(forward)});
    if (!loading) if (auto t = Find(b)) InstallTheme(t->id);
  }
  bool OnBeforeBrowse(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame> frame, CefRefPtr<CefRequest>, bool, bool) override {
    if(frame&&frame->IsMain())OriginalPDFPresenceSuspend(b->GetIdentifier());
    OriginalPDFBrowserClosed(b->GetIdentifier(), @"Original PDF native navigation started");
    return false;
  }
  void OnLoadStart(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame> frame, TransitionType) override {
    if(frame->IsMain())OriginalPDFPresenceSuspend(b->GetIdentifier());
    OriginalPDFBrowserClosed(b->GetIdentifier(), @"Original PDF native document changed");
    if (frame->IsMain()) if (auto t = Find(b)) {
      ++t->documentGeneration;
      CancelPrintFind(*t, @"Document changed");
      CancelQuestions(t->id); CancelPageMenu(t->id);
      for (auto i = authAttempts.begin(); i != authAttempts.end();) {
        if (i->first.rfind(t->id + "|", 0) == 0) i = authAttempts.erase(i); else ++i;
      }
      Event(@"page.committed", t, @{@"url": Str(frame->GetURL())});
      MediaReset(t);
      t->themeReady = false; t->crashed = false;
#if YABCORE_OWNCEF_SURFACES
      // A renderer restart can reuse the window compositor's unchanged
      // CAContext. Rebind the client's cleared host without polling or
      // pretending that load start acknowledges frame presentation.
      PublishOwnCEFSurface(*t);
#endif
      State(t, @{@"themeColor": NSNull.null, @"faviconURL": NSNull.null});
    }
  }
  void OnLoadEnd(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame> frame, int) override {
    if (frame->IsMain()) if (auto t = Find(b)) {
      OriginalPDFPresenceDocumentEnded(b);
      InstallTheme(t->id); Event(@"page.finished", t);
      // The blank document that brought up the agent is no Back entry.
      if (t->scripts.blankFirst && frame->GetURL() != "about:blank" && t->domainsReady) {
        t->scripts.blankFirst = false;
        std::string id = t->id;
        CDP(*t, @"Page.resetNavigationHistory", @{}, [id](NSDictionary*, NSString*) {
          auto found = tabs.find(id);
          if (found == tabs.end() || !found->second.browser) return;
          auto browser = found->second.browser;
          State(&found->second, @{@"canGoBack": @(browser->CanGoBack()), @"canGoForward": @(browser->CanGoForward())});
        });
      }
    }
  }
  void OnLoadError(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame> frame, ErrorCode code, const CefString& text, const CefString& url) override {
    if (frame->IsMain()) Event(@"page.loadError", Find(b), @{@"code": @(code), @"message": Str(text), @"url": Str(url)});
  }
  bool OnRenderProcessUnresponsive(CefRefPtr<CefBrowser> b,
                                  CefRefPtr<CefUnresponsiveProcessCallback>) override {
    auto t = Find(b);
    if (!t || t->internal) return false;
    HealthSignal(t, false);
    // Yab owns the existing Wait/Reload card. A hidden Chrome dialog cannot
    // answer for the hosted page; leave its renderer running while waiting.
    return true;
  }
  void OnRenderProcessResponsive(CefRefPtr<CefBrowser> b) override {
    auto t = Find(b);
    // Input ACKs and compositor responses do not answer our independent
    // main-thread challenge. Only its matching native pong can do that.
    if (t && t->healthToken.empty()) HealthSignal(t, true);
  }
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> b, TerminationStatus status, int code, const CefString& text) override {
    OriginalPDFPresenceClosed(b->GetIdentifier());
    OriginalPDFBrowserClosed(b->GetIdentifier(), @"Original PDF renderer lost");
    if (auto t = Find(b)) { CancelPrintFind(*t, @"Renderer crashed"); CancelQuestions(t->id); CancelPageMenu(t->id); HealthReset(t, false); MediaReset(t, true); }
    // The CAContext belongs to the native window compositor, not this
    // renderer. Only its native reset callback invalidates the cached handle.
    // page.crash clears the client host; main-frame load rebinds that handle.
    if (auto t = Find(b)) { ++t->documentGeneration; t->rendererPID = 0; t->rendererBorn = 0; t->crashed = true; t->themeReady = false; t->worlds.clear(); t->contextNames.clear(); t->lastLayer = nil; Event(@"page.crash", t, @{@"status": @(status), @"code": @(code), @"message": Str(text)}); }
    CancelPending(b->GetIdentifier(), @"Renderer crashed");
  }
  IMPLEMENT_REFCOUNTING(Client);
};
// The frontend tab reserved for each inspected browser, during ShowDevTools.
static std::map<int, std::string> devToolsAsked;
class Window : public CefWindowDelegate {
  std::string id_;
  CefRefPtr<CefBrowserView> view_;
 public:
  Window(std::string id, CefRefPtr<CefBrowserView> view) : id_(id), view_(view) {}
  cef_runtime_style_t GetWindowRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }
  bool IsFrameless(CefRefPtr<CefWindow>) override { return true; }
#if YABCORE_OWNCEF_SURFACES
  void OnAcceleratedFrame(CefRefPtr<CefWindow>, uint32_t context,
                           const CefSize& pixels, float scale) override {
    OwnCEFFrame(id_, context, pixels, scale);
  }
#endif
  CefRect GetInitialBounds(CefRefPtr<CefWindow>) override {
    auto t = tabs.find(id_); return CefRect(80, 120, t == tabs.end() ? 800 : t->second.width, t == tabs.end() ? 600 : t->second.height);
  }
  void OnWindowCreated(CefRefPtr<CefWindow> w) override {
    auto t = tabs.find(id_); if (t == tabs.end()) { w->Close(); return; }
    t->second.window = w; t->second.view = view_;
#if YABCORE_EXTERNAL_HOST
    t->second.externallyHosted = w->EnableExternalHosting();
    if (!t->second.externallyHosted) {
      Event(@"page.loadError", &t->second,
            @{@"message": @"CEF external hosting was refused", @"code": @-1});
      NSString* request = t->second.createRequest;
      tabs.erase(t);
      Reply(request, nil, @"CEF external hosting was refused");
      w->Close();
      return;
    }
#endif
    // Bind the WebContents visibility observer before its first Show().
    w->AddChildView(view_); t->second.native = Native(w);
    MediaProducerWindow(t->second.native);
    if (t->second.externallyHosted) {
      t->second.native.ignoresMouseEvents = YES;
      if (t->second.visible) w->Show();
    } else {
      Conceal(t->second.native); w->Show(); Conceal(t->second.native);
      if (!t->second.visible) [t->second.native orderOut:nil];
    }
  }
  bool CanClose(CefRefPtr<CefWindow>) override { auto b = view_ ? view_->GetBrowser() : nullptr; return !b || b->GetHost()->TryCloseBrowser(); }
  void OnWindowDestroyed(CefRefPtr<CefWindow>) override { view_ = nullptr; }
  IMPLEMENT_REFCOUNTING(Window);
};
class View : public CefBrowserViewDelegate {
 public:
  cef_runtime_style_t GetBrowserRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }
  ChromeToolbarType GetChromeToolbarType(CefRefPtr<CefBrowserView>) override { return CEF_CTT_NONE; }
  bool UseFramelessWindowForPictureInPicture(CefRefPtr<CefBrowserView>) override { return true; }
  void OnBrowserCreated(CefRefPtr<CefBrowserView> view, CefRefPtr<CefBrowser> b) override { if (auto t = Find(b)) t->view = view; }
  bool OnPopupBrowserViewCreated(CefRefPtr<CefBrowserView> owner, CefRefPtr<CefBrowserView> popup, bool devTools) override {
    if (devTools) {
      // Arrives before the frontend's OnAfterCreated. An id no request reserved
      // (Chrome's own F12 route) has no tab: its window closes as it is made.
      auto opener = owner ? owner->GetBrowser() : nullptr;
      auto asked = opener ? devToolsAsked.find(opener->GetIdentifier()) : devToolsAsked.end();
      CefWindow::CreateTopLevelWindow(new Window(asked == devToolsAsked.end() ? "" : asked->second, popup));
      return true;
    }
    auto b = popup->GetBrowser(); if (auto t = Find(b)) { CefWindow::CreateTopLevelWindow(new Window(t->id, popup)); return true; }
    return false;
  }
  IMPLEMENT_REFCOUNTING(View);
};
static std::string Create(std::string profile, NSString* url, NSString* request, bool internal = false) {
  std::string id = "tab-" + std::to_string(++tabSequence);
  Tab t; t.id = id; t.profile = profile; t.createRequest = request; t.internal = internal;
  t.scriptBootstrapAllowed = !url.length;
  tabs.emplace(id, std::move(t));
  CefBrowserSettings settings; settings.background_color = 0xffffffff;
  if (NativeExtensionWindows() && !internal) {
    tabs.at(id).nativeExtensions = true;
    CefWindowInfo info; info.runtime_style = CEF_RUNTIME_STYLE_CHROME;
    info.bounds = CefRect(80, 120, 800, 600);
    auto browser = CefBrowserHost::CreateBrowserSync(info, new Client(profile, id), Key(url), settings, nullptr, profiles.at(profile).context);
    if (!browser) { tabs.erase(id); Reply(request, nil, @"Could not create the native extension host"); return ""; }
    tabs.at(id).native = ExtensionBrowserWindow(browser);
    Conceal(tabs.at(id).native);
    return id;
  }
  auto view = CefBrowserView::CreateBrowserView(new Client(profile, id), Key(url), settings, nullptr, profiles.at(profile).context, new View);
  if (!view) { tabs.erase(id); Reply(request, nil, @"Could not create BrowserView"); return ""; }
  tabs.at(id).view = view;
  CefWindow::CreateTopLevelWindow(new Window(id, view));
  return id;
}
#include "devtools.inc"
static void PollLayers() {
  NSMutableSet* known = [NSMutableSet new];
  for (auto& [id, tab] : tabs) {
    HealthPoll(tab);
    if (!tab.view && tab.browser) tab.view = CefBrowserView::GetForBrowser(tab.browser);
    if (!tab.window && tab.view) tab.window = tab.view->GetWindow();
    if (!tab.native && tab.window) tab.native = Native(tab.window);
    if (!tab.native && tab.browser) {
      NSView* native = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(tab.browser->GetHost()->GetWindowHandle());
      tab.native = [(NSObject*)native isKindOfClass:NSWindow.class] ? (NSWindow*)(NSObject*)native : native.window;
    }
    if (!tab.native) continue;
    MediaProducerWindow(tab.native);
    [known addObject:@(tab.native.windowNumber)];
    if (!tab.externallyHosted) Conceal(tab.native);
    // A Chrome-created tab can still share its owner's native window before
    // adoption. Its default geometry must not compete with that owner.
    if (tab.adopted && !tab.externalPage && (tab.nativeExtensions || tab.fitPage)) ResizeExtensionWindow(tab.native, tab.width, tab.height);
    if (!tab.themeReady && !tab.crashed && tab.browser && !tab.browser->IsLoading() && Now() - tab.themeAttempt > 0.5) InstallTheme(id);
#if !YABCORE_OWNCEF_SURFACES
    uint32_t cid = Context(tab.native);
    NSRect page = tab.nativeExtensions || tab.fitPage ? ExtensionPageRect(tab.native) : NSZeroRect;
    NSDictionary* state = @{@"contextId": @(cid), @"width": @(tab.width), @"height": @(tab.height),
      @"pageX": @(page.origin.x), @"pageY": @(page.origin.y),
      @"scale": @(tab.native.backingScaleFactor), @"requestedScale": @(tab.scale), @"visible": @(tab.visible)};
    NSString* encoded = JSON(state);
    if (![encoded isEqual:tab.lastLayer]) { tab.lastLayer = encoded; if (!tab.internal) Event(@"layer.changed", &tab, state); }
#endif
  }
  // Native Chrome widgets (including extension action popups) are independent
  // contexts. Report additions, movement, context replacement and disappearance.
  static NSMutableDictionary* previous = [NSMutableDictionary new];
  NSMutableDictionary* current = [NSMutableDictionary new];
  for (NSWindow* window in NSApp.windows) {
    if ([known containsObject:@(window.windowNumber)]) continue;
    Conceal(window);
    uint32_t cid = Context(window);
    if (getenv("YAB_CEF_TRACE_CDP")) {
      static NSMutableSet* traced = [NSMutableSet new];
      NSString* key = [NSString stringWithFormat:@"%ld:%u:%ld:%d", (long)window.windowNumber, cid, (long)window.parentWindow.windowNumber, window.isVisible];
      if (![traced containsObject:key]) {
        [traced addObject:key];
        fprintf(stderr, "YabCore widget window=%ld parent=%ld context=%u visible=%d class=%s\n", (long)window.windowNumber, (long)window.parentWindow.windowNumber, cid, window.isVisible, NSStringFromClass(window.class).UTF8String);
      }
    }
    if (!cid || !window.isVisible) continue;
    Tab* owner = nullptr;
    for (auto& [id, tab] : tabs) if (window.parentWindow == tab.native) { owner = &tab; break; }
    NSRect frame = window.frame;
    if (owner) {
      NSRect content = [owner->native convertRectToScreen:owner->native.contentView.bounds];
      frame.origin = NSMakePoint(frame.origin.x - content.origin.x, NSMaxY(content) - NSMaxY(frame));
    }
    NSDictionary* row = @{@"popup": @(window.windowNumber).stringValue, @"contextId": @(cid),
      @"x": @(frame.origin.x), @"y": @(frame.origin.y), @"width": @(frame.size.width), @"height": @(frame.size.height),
      @"scale": @(window.backingScaleFactor), @"tab": owner ? (NSObject*)@(owner->id.c_str()) : NSNull.null,
      @"coordinateSpace": owner ? @"page" : @"screenBottomLeft"};
    NSString* key = @(window.windowNumber).stringValue; current[key] = row;
    if (![JSON(previous[key]) isEqual:JSON(row)]) Event(@"popup.layer", nullptr, row);
  }
  for (NSString* key in previous) if (!current[key]) Event(@"popup.closed", nullptr, @{@"popup": key});
  previous = current;
}
static void Input(Tab& tab, NSDictionary* p, NSString* request) {
  const std::string tabID = tab.id;
  NSWindow* w = tab.native;
  NSView* view = FindView(w.contentView.superview ?: w.contentView, @"RenderWidgetHostViewCocoa");
  if (!view) { Reply(request, nil, @"Page input view not ready"); return; }
  NSString* kind = S(p, @"kind");
  NSEventModifierFlags flags = [p[@"modifiers"] unsignedLongLongValue];
  double x = [p[@"x"] doubleValue], y = [p[@"y"] doubleValue];
  NSPoint point = [view convertPoint:NSMakePoint(x, view.isFlipped ? y : view.bounds.size.height - y) toView:nil];
  // The client's input context names the UTF-16 range an edit replaces in
  // the focused field (a held letter's accent replaces the letter typed).
  // The page view reads it as Chromium's own client does: ImeCommitText or
  // ImeSetComposition with that range. Absent, it replaces nothing.
  NSRange replacement = NSMakeRange(NSNotFound, 0);
  if (p[@"replacementStart"] || p[@"replacementLength"]) {
    double start = [p[@"replacementStart"] doubleValue], length = [p[@"replacementLength"] doubleValue];
    if (![p[@"replacementStart"] isKindOfClass:NSNumber.class] || ![p[@"replacementLength"] isKindOfClass:NSNumber.class] ||
        start < 0 || length < 0 || std::trunc(start) != start || std::trunc(length) != length || start + length > INT32_MAX) {
      Reply(request, nil, @"Invalid replacement range"); return;
    }
    replacement = NSMakeRange((NSUInteger)start, (NSUInteger)length);
  }
  if ([kind isEqual:@"text"]) {
    if (![view respondsToSelector:@selector(insertText:replacementRange:)]) { Reply(request, nil, @"View has no text input client"); return; }
    [(id<NSTextInputClient>)view insertText:S(p, @"text") replacementRange:replacement];
  } else if ([kind isEqual:@"compose"] || [kind isEqual:@"unmark"]) {
    // The client's own input method composes; the page's view only shows it.
    // Committing goes through kind "text" (insertText ends the composition).
    if (![view respondsToSelector:@selector(setMarkedText:selectedRange:replacementRange:)]) { Reply(request, nil, @"View has no text input client"); return; }
    if ([kind isEqual:@"unmark"]) [(id<NSTextInputClient>)view unmarkText];
    else {
      NSString* text = S(p, @"text") ?: @"";
      NSUInteger location = MIN((NSUInteger)[p[@"selectionStart"] unsignedIntegerValue], text.length);
      NSUInteger length = MIN((NSUInteger)[p[@"selectionLength"] unsignedIntegerValue], text.length - location);
      [(id<NSTextInputClient>)view setMarkedText:text selectedRange:NSMakeRange(location, length) replacementRange:replacement];
    }
  } else if ([kind isEqual:@"keyDown"] || [kind isEqual:@"keyUp"]) {
    NSEvent* event = [NSEvent keyEventWithType:[kind isEqual:@"keyDown"] ? NSEventTypeKeyDown : NSEventTypeKeyUp
      location:point modifierFlags:flags timestamp:Now() windowNumber:w.windowNumber context:nil
      characters:S(p, @"characters") charactersIgnoringModifiers:S(p, @"unmodified") isARepeat:[p[@"repeat"] boolValue] keyCode:[p[@"keyCode"] unsignedShortValue]];
    if (tab.externallyHosted) {
      // Same reason as the mouse: the producer window is not visible.
      NSResponder* target = [w.firstResponder isKindOfClass:NSView.class] && [(NSView*)w.firstResponder isDescendantOf:w.contentView] ? w.firstResponder : view;
      fprintf(stderr, "YabCore key %s: window visible %d, first responder %s\n", kind.UTF8String, (int)w.isVisible, NSStringFromClass(target.class).UTF8String);
      if ([kind isEqual:@"keyDown"]) [target keyDown:event]; else [target keyUp:event];
    } else {
      [w sendEvent:event];
    }
  } else if ([kind isEqual:@"wheel"]) {
    CGEventRef cg = CGEventCreateScrollWheelEvent(nullptr, kCGScrollEventUnitPixel, 2, (int32_t)[p[@"deltaY"] doubleValue], (int32_t)[p[@"deltaX"] doubleValue]);
    if (!cg) { Reply(request, nil, @"Cannot create wheel event"); return; }
    CGEventSetIntegerValueField(cg, kCGScrollWheelEventScrollPhase, [p[@"phase"] longLongValue]);
    CGEventSetIntegerValueField(cg, kCGScrollWheelEventMomentumPhase, [p[@"momentumPhase"] longLongValue]);
    CGEventSetFlags(cg, static_cast<CGEventFlags>(flags));
    NSPoint screen = [w convertPointToScreen:point];
    CGEventSetLocation(cg, CGPointMake(screen.x, NSScreen.screens.firstObject.frame.size.height - screen.y));
    CGEventSetIntegerValueField(cg, kCGMouseEventWindowUnderMousePointer, w.windowNumber);
    CGEventSetIntegerValueField(cg, kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent, w.windowNumber);
    NSEvent* event = [NSEvent eventWithCGEvent:cg];
    if (!event.window) {
      // A windowless NSEvent reports a screen point as locationInWindow.
      // We invoke this view directly, so supply its window-base point instead.
      CGEventSetLocation(cg, CGPointMake(point.x, NSScreen.screens.firstObject.frame.size.height - point.y));
      event = [NSEvent eventWithCGEvent:cg];
    }
    fprintf(stderr, "YabCore wheel: event window %ld, target %ld, location %s, delta %.2f\n", (long)event.windowNumber, (long)w.windowNumber, NSStringFromPoint(event.locationInWindow).UTF8String, event.scrollingDeltaY);
    [view scrollWheel:event]; CFRelease(cg);
  } else {
    NSDictionary* types = @{@"mouseDown": @"mousePressed", @"mouseUp": @"mouseReleased", @"mouseMove": @"mouseMoved", @"mouseDrag": @"mouseMoved", @"rightDown": @"mousePressed", @"rightUp": @"mouseReleased"};
    if (!types[kind]) { Reply(request, nil, @"Unknown input kind"); return; }
    if (tab.externallyHosted) {
      NSDictionary* nativeTypes = @{@"mouseDown": @(NSEventTypeLeftMouseDown), @"mouseUp": @(NSEventTypeLeftMouseUp),
        @"mouseMove": @(NSEventTypeMouseMoved), @"mouseDrag": @(NSEventTypeLeftMouseDragged),
        @"rightDown": @(NSEventTypeRightMouseDown), @"rightUp": @(NSEventTypeRightMouseUp)};
      NSEvent* event = [NSEvent mouseEventWithType:(NSEventType)[nativeTypes[kind] unsignedIntegerValue] location:point modifierFlags:flags timestamp:Now()
      windowNumber:w.windowNumber context:nil eventNumber:0 clickCount:p[@"clickCount"] ? [p[@"clickCount"] integerValue] : 1 pressure:[kind hasSuffix:@"Down"] ? 1 : 0];
      // An externally hosted producer window is never ordered in, and AppKit
      // does not route mouse events to a window that is not visible. Deliver
      // straight to the page view, taking first responder as AppKit would.
      NSDictionary* selectors = @{@"mouseDown": @"mouseDown:", @"mouseUp": @"mouseUp:", @"mouseMove": @"mouseMoved:",
        @"mouseDrag": @"mouseDragged:", @"rightDown": @"rightMouseDown:", @"rightUp": @"rightMouseUp:"};
      SEL action = NSSelectorFromString(selectors[kind]);
      if (![view respondsToSelector:action]) { Reply(request, nil, @"Page view cannot take this mouse event"); return; }
      if ([kind hasSuffix:@"Down"] && w.firstResponder != view) [w makeFirstResponder:view];
      fprintf(stderr, "YabCore mouse %s: window visible %d, event window %ld, target %ld, view window %ld\n", kind.UTF8String,
              (int)w.isVisible, (long)event.windowNumber, (long)w.windowNumber, (long)view.window.windowNumber);
      ((void (*)(id, SEL, NSEvent*))objc_msgSend)(view, action, event);
      auto live = tabs.find(tabID);
      if (live != tabs.end()) HealthInput(live->second);
      Reply(request); return;
    }
    if (getenv("YAB_CEF_TRACE_INPUT")) {
      static int traced = 0;
      if (traced++ < 12) {
        NSView* hit = [w.contentView hitTest:[w.contentView.superview convertPoint:point fromView:nil]];
        fprintf(stderr, "YabCore input %s at %s window %ld visible=%d key=%d alpha=%.1f ignores=%d accepts=%d hit=%s rwhv=%s frame=%s\n", kind.UTF8String,
          NSStringFromPoint(point).UTF8String, (long)w.windowNumber, w.isVisible, w.isKeyWindow, w.alphaValue, w.ignoresMouseEvents, w.acceptsMouseMovedEvents,
          hit ? NSStringFromClass(hit.class).UTF8String : "nil", NSStringFromClass(view.class).UTF8String, NSStringFromRect(view.frame).UTF8String);
      }
    }
    // Cocoa's hidden producer view can discard even directly delivered mouse
    // events. The real page's trusted input route does not depend on that
    // window being key or underneath the system pointer. Match the existing
    // scripts.input route; the app still records the original native gesture.
    int modifiers = (flags & NSEventModifierFlagOption ? 1 : 0) | (flags & NSEventModifierFlagControl ? 2 : 0) |
                    (flags & NSEventModifierFlagCommand ? 4 : 0) | (flags & NSEventModifierFlagShift ? 8 : 0);
    bool right = [kind hasPrefix:@"right"], moved = [kind isEqual:@"mouseMove"], dragged = [kind isEqual:@"mouseDrag"];
    bool pressed = [types[kind] isEqual:@"mousePressed"];
    double zoom = std::pow(1.2, tab.browser->GetHost()->GetZoomLevel());
    int clicks = moved || dragged ? 0 : std::max(1, [p[@"clickCount"] intValue]);
    // CDP acknowledges after the page's handler. Arm before dispatch so a
    // handler stuck on the renderer's main thread cannot postpone its probe.
    HealthInput(tab);
    CDP(tab, @"Input.dispatchMouseEvent", @{@"type": types[kind], @"x": @(x / zoom), @"y": @(y / zoom),
      @"button": moved ? @"none" : right ? @"right" : @"left", @"buttons": @(pressed ? (right ? 2 : 1) : dragged ? 1 : 0),
      @"clickCount": @(clicks), @"modifiers": @(modifiers)},
      [request](NSDictionary* value, NSString* error) { Reply(request, value, error); });
    return;
  }
  auto live = tabs.find(tabID);
  if (live != tabs.end()) HealthInput(live->second);
  Reply(request);
}
static NSString* Validate(NSDictionary* p) {
  for (NSString* key in @[@"profile", @"tab", @"url", @"world", @"name", @"path", @"extension", @"kind", @"text", @"characters", @"unmodified", @"request", @"download", @"user", @"password"])
    if (p[key] && (![p[key] isKindOfClass:NSString.class] || [p[key] length] > 262144)) return @"Invalid string parameter";
  // Dark Reader is 346 KB before its evaluation wrapper. Script code has a
  // separate bounded allowance; ordinary input strings keep their old limit.
  for (NSString* key in @[@"function", @"expression"])
    if (p[key] && (![p[key] isKindOfClass:NSString.class] || [p[key] lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 1024 * 1024)) return @"Invalid script source";
  for (NSString* key in @[@"width", @"height", @"scale", @"x", @"y", @"deltaX", @"deltaY", @"modifiers", @"keyCode", @"phase", @"momentumPhase", @"clickCount", @"replacementStart", @"replacementLength"])
    if (p[key] && (![p[key] isKindOfClass:NSNumber.class] || !std::isfinite([p[key] doubleValue]) || fabs([p[key] doubleValue]) > 1e15)) return @"Invalid numeric parameter";
  for (NSString* key in @[@"private", @"visible", @"enabled", @"accept", @"repeat", @"userGesture", @"muted", @"forward", @"allow"])
    if (p[key] && ![p[key] isKindOfClass:NSNumber.class]) return @"Invalid boolean parameter";
  return nil;
}
static void ProfileOpened(const std::string& key) {
  auto found = profiles.find(key);
  if (found == profiles.end()) return;
  found->second.ready = true;
  NSString* name = @(key.c_str());
  for (NSString* waiting : found->second.waiting) Reply(waiting, @{@"profile": name, @"private": @(found->second.privateMode)});
  found->second.waiting.clear();
}
class ProfileHandler : public CefRequestContextHandler {
  std::string key_;
 public:
  explicit ProfileHandler(std::string key) : key_(std::move(key)) {}
  void OnRequestContextInitialized(CefRefPtr<CefRequestContext>) override {
    // Leave CEF's callback first: the caller's next request may create a tab.
    std::string key = key_;
    dispatch_async(dispatch_get_main_queue(), ^{ ProfileOpened(key); });
  }
  IMPLEMENT_REFCOUNTING(ProfileHandler);
};
static void Request(NSDictionary* request) {
  NSString* id = S(request, @"id"); NSString* method = S(request, @"method");
  if (!id.length || id.length > 128 || requests.count(Key(id))) { wire.Close(); Shutdown(); return; }
  requests.emplace(Key(id), Now() + 20);
  if (getenv("YAB_CEF_TRACE_CDP")) fprintf(stderr, "YabCore request id=%s method=%s tab=%s\n", id.UTF8String, method.UTF8String, ([request[@"params"] isKindOfClass:NSDictionary.class] ? S(request[@"params"], @"tab") : @"").UTF8String);
  if (![request[@"v"] isEqual:@1]) { Reply(id, nil, @"Unsupported protocol version"); return; }
  if (!hello) {
    if (![method isEqual:@"hello"]) { Reply(id, nil, @"hello must be the first request"); return; }
    hello = true;
    original_caller::Hello([request[@"params"] isKindOfClass:NSDictionary.class] ? request[@"params"] : @{});
    NativeSwitchGroupsHello();
    for (auto& [key, tab] : tabs) {
      tab.lastLayer = nil;
#if YABCORE_OWNCEF_SURFACES
      PublishOwnCEFSurface(tab);
#endif
      if (!tab.adopted && tab.creationAnnounced) Event(@"tab.created", &tab, CreatedState(tab));
    }
    Reply(id, @{@"version": @1, @"engine": @"CEF 156 Chrome style", @"capabilities": @[@"profiles", @"tabs", @"layerContexts", @"input", @"isolatedScripts", @"bindings", @"dialogs", @"extensionsExperimental"],
      @"layerContextSource": YABCORE_OWNCEF_SURFACES ? @"cefCallback" : @"windowTreePolling",
      @"externalHostingSupported": @(YABCORE_EXTERNAL_HOST), @"nativeHooks": NativeHookCapabilities(),
      @"nativeGroupSource": NativeSnapshotPeerIdentity(),
      @"nativeOriginalCaller": original_caller::Receipt(S(NativeSnapshotPeerIdentity(), @"helperOwner"), S(NativeSnapshotPeerIdentity(), @"connection")),
      @"limitations": @[@"nativeScaleOnly", @"nativeSelectNotHosted", @"focusAndIMEUnverified", @"extensionActionTabIdentityUnverified", @"developmentSigning"]}); return;
  }
  if (requests.size() > 256) { Reply(id, nil, @"Too many pending requests"); return; }
  NSDictionary* p = request[@"params"] ?: @{};
  if (![p isKindOfClass:NSDictionary.class]) { Reply(id, nil, @"params must be an object"); return; }
  if (NSString* error = Validate(p)) { Reply(id, nil, error); return; }
  if (stopping) { Reply(id, nil, @"Helper is shutting down"); return; }
  if ([method isEqual:@"originalCaller.diagnostic"]) {
    auto diagnostic=original_caller::DiagnosticReceipt(S(NativeSnapshotPeerIdentity(), @"helperOwner"), S(NativeSnapshotPeerIdentity(), @"connection"));
    if (!diagnostic) Reply(id,nil,@"Original diagnostic connection unavailable");
    else Reply(id,diagnostic);
    return;
  }
  if ([method isEqual:@"shutdown"]) { Reply(id); stopping = true; dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ Shutdown(); }); return; }
  if (ReadPageRequest(method, p, id)) return;
  if ([method isEqual:@"profile.open"]) {
    NSString* profile = S(p, @"profile");
    NSCharacterSet* invalid = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"] invertedSet];
    if (!profile.length || profile.length > 100 || [profile rangeOfCharacterFromSet:invalid].location != NSNotFound) { Reply(id, nil, @"Profile must be a short alphanumeric identifier"); return; }
    auto found = profiles.find(Key(profile));
    bool privateMode = [p[@"private"] boolValue];
    if (found != profiles.end()) {
      if (found->second.privateMode != privateMode) Reply(id, nil, @"Profile already exists with different privacy");
      else if (!found->second.ready) found->second.waiting.push_back(id);
      else Reply(id, @{@"profile": profile, @"private": @(privateMode)});
      return;
    }
    if (profiles.size() >= 64) { Reply(id, nil, @"Profile limit reached"); return; }
    CefRequestContextSettings settings;
    if (!privateMode) {
      // Chrome style requires immediate children of root_cache_path. Nested
      // paths silently fall back to an off-the-record profile in CEF 156.
      NSString* path = [dataRoot stringByAppendingFormat:@"/space-%@", profile];
      CefString(&settings.cache_path) = path.UTF8String;
      settings.persist_session_cookies = true;
    }
    auto context = CefRequestContext::CreateContext(settings, new ProfileHandler(Key(profile)));
    if (!context) { Reply(id, nil, @"Cannot create profile"); return; }
    profiles[Key(profile)] = {context, privateMode, false, {id}}; return;
  }
  if ([method isEqual:@"profile.close"]) {
    auto profile = profiles.find(Key(S(p, @"profile")));
    if (profile == profiles.end()) { Reply(id, nil, @"Unknown profile"); return; }
    for (auto& [key, t] : tabs) if (t.profile == profile->first) { Reply(id, nil, @"Close profile tabs first"); return; }
    profiles.erase(profile); Reply(id); return;
  }
  if ([method isEqual:@"extension.open"]) {
    std::string profile = Key(S(p, @"profile"));
    auto found = profiles.find(profile);
    if (found == profiles.end()) { Reply(id, nil, @"Unknown profile"); return; }
    if (found->second.privateMode) { Reply(id, nil, @"Extension management is unavailable in private profiles"); return; }
    if (tabs.size() >= 256) { Reply(id, nil, @"Tab limit reached"); return; }
    Create(profile, @"chrome://extensions/", id, true); return;
  }
  if ([method isEqual:@"tab.create"]) {
    std::string profile = Key(S(p, @"profile"));
    if (!profiles.count(profile)) { Reply(id, nil, @"Unknown profile"); return; }
    if (tabs.size() >= 256) { Reply(id, nil, @"Tab limit reached"); return; }
    // Explicitly empty means CEF's native no-navigation bootstrap. Missing
    // URL retains the wire's previous default for other clients.
    Create(profile, p[@"url"] ? S(p, @"url") : @"about:blank", id); return;
  }
  if ([method isEqual:@"extension.consent.capabilities"]) {
    Reply(id, @{@"nativeConsent": @(YABCORE_EXTENSION_CONSENT)}); return;
  }
  if (DownloadRequest(S(p, @"tab"), method, p, id)) return;
#if YABCORE_EXTENSION_CONSENT
  if ([method isEqual:@"extension.consent.reply"]) { ConsentReply(p, id); return; }  // Profile-level, no tab.
#endif
  if ([method isEqual:@"tabs.group"]) { TabsGroupRequest(p, id); return; }
  if (OriginalPDFGlobalRequest(method, p, id)) return;
  if (NativeSwitchGroupRequest(method, p, id)) return;
  if (LifecycleBatchRequest(method, p, id)) return;
  auto found = tabs.find(Key(S(p, @"tab")));
  if (found == tabs.end() || !found->second.browser || found->second.closing) { Reply(id, nil, @"Unknown or unready tab"); return; }
  Tab& t = found->second;
  if (IsReadTab(&t)) { Reply(id, nil, @"Task read pages require dedicated read.page transport"); return; }
  if (!t.adopted && ![@[@"tab.adopt", @"tab.close", @"tab.state"] containsObject:method]) {
    Reply(id, nil, @"Adopt this Chrome-created tab first"); return;
  }
  auto b = t.browser;
  if ([method isEqual:@"tab.readiness"]) { Readiness(t, p, id); return; }
  if (DevToolsRequest(t, method, p, id)) return;
  if (NavigationRequest(t, method, p, id)) return;
  if (OriginalPDFPresenceRequest(t, method, p, id)) return;
  if (OriginalPDFRequest(t, method, p, id)) return;
  if (PrintFindRequest(t, method, p, id)) return;
  if (QuestionRequest(t, method, p, id)) return;
  if (HistoryRequest(t, method, p, id)) return;
  if (MediaRequest(t, method, p, id)) return;
  if (ContextMenuRequest(t, method, p, id)) return;
  if (PermissionRequest(t, method, p, id)) return;
  if (LifecycleRequest(t, method, p, id)) return;
  if (HTMLLoadRequest(t, method, p, id)) return;
  if (NativeTextInputRequest(t, method, p, id)) return;
  if (NativeHookRequest(t, method, p, id)) return;
  if (DRMCookieCommand(t, method, p, id)) return;
  if (ExtensionBridgeCommand(t, method, p, id)) return;
  if (ExtensionActionCommand(t, method, p, id)) return;
  if ([method isEqual:@"extension.actions"] || [method isEqual:@"extension.pressAction"]) {
    if (!t.nativeExtensions || t.internal) { Reply(id, nil, @"Native action diagnostics require the opt-in normal-window path"); return; }
    if ([method isEqual:@"extension.pressAction"]) {
      NSString* error = nil;
      if (!ExtensionPressNamedAction(t.native, S(p, @"name"), &error)) { Reply(id, nil, error); return; }
    }
    Reply(id, @{@"buttons": ExtensionActionButtons(t.native), @"widgets": ExtensionActionWidgets(t.native, Context),
      @"nativeWindow": @(t.native.windowNumber), @"keyWindow": @(t.native.isKeyWindow), @"appActive": @(NSApp.isActive)});
  }
  else if ([method isEqual:@"tab.adopt"]) {
    if (!t.adopted && !t.creationAnnounced) { Reply(id, nil, @"No native tab creation request"); return; }
    if (![S(p, @"profile") isEqual:@(t.profile.c_str())] || !p[@"private"] ||
        [p[@"private"] boolValue] != profiles.at(t.profile).privateMode) {
      Reply(id, nil, @"Adoption profile/privacy mismatch"); return;
    }
    t.adopted = true; t.lastLayer = nil; Reply(id, CreatedState(t));
    State(&t, @{@"url": Str(b->GetMainFrame()->GetURL()), @"title": t.title,
      @"loading": @(b->IsLoading()), @"canGoBack": @(b->CanGoBack()), @"canGoForward": @(b->CanGoForward())});
  }
  else if ([method isEqual:@"tab.close"]) { t.closing = true; Reply(id); b->GetHost()->CloseBrowser(true); }
  else if ([method isEqual:@"tab.navigate"]) {
    if (!S(p, @"url").length) { Reply(id, nil, @"url is required"); return; }
    NSString* url = S(p, @"url");
    NSString* referrer = S(p, @"referrer");
    if (p[@"referrer"]) {
      NSURLComponents* parts = [NSURLComponents componentsWithString:referrer];
      if (!referrer.length || ![@[@"http", @"https"] containsObject:parts.scheme.lowercaseString]
          || !parts.host.length || parts.user || parts.password || parts.fragment
          || [referrer rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound) {
        Reply(id, nil, @"Invalid navigation referrer"); return;
      }

    }
    std::string tabID = t.id;
    // CEF's unnavigated bootstrap has no renderer document, so its DevTools
    // agent (and every CDP call) waits for the first real one. Never hold the
    // first navigation behind the hook there.
    if (!t.domainsReady && (!b->HasDocument() || !referrer.length)) {
      if (!referrer.length) {
        // Hook the first document right after DevTools attaches, in the
        // current document as well as later ones.
        ++t.documentGeneration; t.drmFrames.clear();
        b->GetMainFrame()->LoadURL(Key(url)); Reply(id);
        InstallDRM(t, [](NSDictionary*, NSString* error) {
          if (error) fprintf(stderr, "YabCore DRM hook after first navigation: %s\n", error.UTF8String);
        }, true);
        return;
      }
      // Page.navigate carries the referrer but needs an agent: load a blank
      // document first and drop that entry once the real one has loaded.
      t.scripts.blankFirst = true;
      ++t.documentGeneration; t.drmFrames.clear();
      b->GetMainFrame()->LoadURL("about:blank");
    }
    InstallDRM(t, [id, tabID, url, referrer](NSDictionary*, NSString* error) {
      auto t = tabs.find(tabID);
      if (error || t == tabs.end() || t->second.closing) { Reply(id, nil, error ?: @"Tab closed"); return; }
      ++t->second.documentGeneration; t->second.drmFrames.clear();
      if (referrer.length) {
        // LoadRequest requires an existing initiator origin in CEF. A fresh
        // replacement tab has none; Page.navigate accepts the referrer directly.
        DRMCDP(tabID, @"Page.navigate", @{@"url": url, @"referrer": referrer,
                @"referrerPolicy": @"strictOriginWhenCrossOrigin"},
          [id](NSDictionary* result, NSString* error) {
            NSString* failure = S(result, @"errorText");
            Reply(id, result, error ?: (failure.length ? failure : nil));
          }, Now() + 10);
      } else { t->second.browser->GetMainFrame()->LoadURL(Key(url)); Reply(id); }

    });
  } else if ([method isEqual:@"tab.back"]) { if (b->CanGoBack()) { ++t.documentGeneration; t.drmFrames.clear(); b->GoBack(); } Reply(id); }
  else if ([method isEqual:@"tab.forward"]) { if (b->CanGoForward()) { ++t.documentGeneration; t.drmFrames.clear(); b->GoForward(); } Reply(id); }
  else if ([method isEqual:@"tab.reload"]) { ++t.documentGeneration; t.drmFrames.clear(); if ([p[@"fromOrigin"] boolValue]) b->ReloadIgnoreCache(); else b->Reload(); Reply(id); }
  else if ([method isEqual:@"tab.stop"]) { b->StopLoad(); Reply(id); }
  else if ([method isEqual:@"media.mute"]) {
    if (!p[@"muted"]) { Reply(id, nil, @"muted is required"); return; }
    b->GetHost()->SetAudioMuted([p[@"muted"] boolValue]);
    State(&t, @{@"audioMuted": @(b->GetHost()->IsAudioMuted())});
    Reply(id, @{@"muted": @(b->GetHost()->IsAudioMuted())});
  } else if ([method isEqual:@"page.killRenderer"]) {
    struct proc_bsdinfo info = {};
    pid_t pid = t.rendererPID;
    if (p[@"rendererPID"] && [p[@"rendererPID"] intValue] != pid) {
      Reply(id, nil, @"Renderer changed before termination"); return;
    }
    if (pid <= 0 || proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info) ||
        info.pbi_ppid != getpid() || info.pbi_start_tvsec * 1000000ULL + info.pbi_start_tvusec != t.rendererBorn) {
      Reply(id, nil, @"Renderer identity is unavailable or has changed"); return;
    }
    if (kill(pid, SIGKILL) != 0) { Reply(id, nil, @"Cannot end renderer"); return; }
    Reply(id);
  }
  else if ([method isEqual:@"tab.state"]) {
    // CEF can clear HasDocument after a same-document navigation while the
    // renderer and its default main-frame context are still alive.
    bool hasMainContext = std::any_of(t.scripts.contexts.begin(), t.scripts.contexts.end(), [&t](const auto& entry) {
      const auto& context = entry.second;
      return context.isDefault && !context.session.length && context.frame.length && [context.frame isEqual:t.scripts.mainFrame];
    });
    Reply(id, @{@"url": Str(b->GetMainFrame()->GetURL()), @"loading": @(b->IsLoading()), @"canGoBack": @(b->CanGoBack()), @"canGoForward": @(b->CanGoForward()), @"hasDocument": @(b->HasDocument()), @"hasMainContext": @(hasMainContext),
      @"cachePath": Str(b->GetHost()->GetRequestContext()->GetCachePath()), @"devToolsReady": @(t.domainsReady),
      @"nativeExtensionWindow": @(t.nativeExtensions), @"nativeWindow": @(t.native.windowNumber),
      @"contextId": @(t.externalPage ? t.surface.context : Context(t.native)),
      @"nativePage": t.nativePageReceipt ?: (::id)NSNull.null,
      @"pageRect": t.externalPage ? (::id)(t.nativePageReceipt ?: @{}) : (::id)NSStringFromRect(ExtensionPageRect(t.native)),
      @"rendererPID": @(t.rendererPID), @"audioMuted": @(b->GetHost()->IsAudioMuted()),
      @"audible": @(t.audible), @"focused": @(t.focused), @"discarded": @(t.discarded), @"frozen": @(t.frozen), @"backgroundColor": t.backgroundColor ?: (::id)NSNull.null,
      @"geometry": @{@"windowClass": t.native ? NSStringFromClass(t.native.class) : @"",
        @"frame": t.native ? NSStringFromRect(t.native.frame) : @"", @"content": t.native ? NSStringFromRect(t.native.contentView.frame) : @"",
        @"styleMask": @(t.native.styleMask), @"requested": @[@(t.width), @(t.height)], @"views": @(t.window != nullptr)},
      // Physical AppKit state is distinct from delegated Chromium visibility
      // and activation. Keep both observable for the external-host proofs.
      @"producer": @{@"visible": @(t.native.isVisible), @"key": @(t.native.isKeyWindow),
        @"externallyHosted": @(t.externallyHosted),
        @"windowNumber": @(t.native.windowNumber),
        @"onScreen": WindowOnScreen(t.native) ?: (::id)NSNull.null,
        @"appActive": @(NSApp.isActive), @"alpha": @(t.native.alphaValue),
        @"logicalVisible": @(t.externalPage ? t.visible : t.window && t.window->IsVisible()),
        @"logicalActive": @(t.externalPage ? t.focused : t.window && t.window->IsActive())}});
  } else if ([method isEqual:@"tab.resize"]) {
    double width = [p[@"width"] doubleValue], height = [p[@"height"] doubleValue], scale = [p[@"scale"] doubleValue];
    if (width < 1 || height < 1 || width > 16384 || height > 16384 || scale < 0.5 || scale > 4 || (!t.window && !t.nativeExtensions && !t.fitPage && !t.externalPage)) { Reply(id, nil, @"Invalid size or unready window"); return; }
    t.width = width; t.height = height; t.scale = scale;
    const bool fitWindow = !t.externalPage && (t.nativeExtensions || t.fitPage);
    if (fitWindow) ResizeExtensionWindow(t.native, width, height);
    NSString* serial = S(p, @"serial");
#if YABCORE_OWNCEF_SURFACES
    // Arm before SetSize: a synchronous CA frame may arrive during it.
    t.resizeSerial = serial.length ? serial : nil;
    t.resizeWidth = (int)ceil(width); t.resizeHeight = (int)ceil(height);
#endif
#if YABCORE_NATIVE_PAGE
    if (t.externalPage) {
      if (!b->GetHost()->SetExternalPageSize(CefSize((int)ceil(width), (int)ceil(height)))) {
        t.resizeSerial = nil;
        Reply(id, nil, @"Native page geometry owner is unavailable or refused the size"); return;
      }
    } else
#endif
    if (!fitWindow) t.window->SetSize(CefSize((int)ceil(width), (int)ceil(height)));
    t.lastLayer = nil;
    Reply(id, @{@"requestedScale": @(scale), @"actualScale": @(t.native.backingScaleFactor),
                @"resizeAck": @(YABCORE_OWNCEF_SURFACES && serial.length > 0)});
#if YABCORE_OWNCEF_SURFACES
    AcknowledgeResize(t);  // A no-op size is already presented.
#endif
  } else if ([method isEqual:@"tab.visible"]) {
    t.visible = [p[@"visible"] boolValue];
    if (!t.visible) CancelFilePick(t.id);
#if YABCORE_NATIVE_PAGE
    if (t.externalPage) {
      if (!b->GetHost()->SetExternalPageVisibility(t.visible)) {
        Reply(id, nil, @"Native page visibility owner is unavailable"); return;
      }
      if (!t.visible) t.focused = false;
    } else
#endif
    if (t.externallyHosted) {
      if (t.visible) t.window->Show(); else { t.window->Hide(); t.focused = false; }
    } else {
      if (t.visible) { Conceal(t.native); [t.native orderFront:nil]; } else [t.native orderOut:nil];
    }
    t.lastLayer = nil;
#if YABCORE_OWNCEF_SURFACES
    PublishOwnCEFSurface(t);
#endif
#if YABCORE_DISCARD
    if (t.visible) {
      // Showing a page unfreezes it; a discarded one resumes its selected entry.
      if (t.frozen) { t.frozen = false; State(&t, @{@"frozen": @NO}); }
      if (t.discarded) {
        // Showing the page may already have started the restore on Chromium's side
        // (then RestoreDiscardedPage reports nothing left to do); either way the
        // client's discarded state ends here.
        b->GetHost()->RestoreDiscardedPage();
        NativeDiscarded(&t, false);
      }
    }
#endif
    if (!t.visible && t.domainsReady) {
      // Retire each target's CDP focus capturer before acknowledging hide.
      auto sessions = std::make_shared<std::vector<std::string>>(t.scripts.sessions.begin(), t.scripts.sessions.end());
      if (sessions->empty()) sessions->push_back("");
      auto remaining = std::make_shared<size_t>(sessions->size());
      auto failure = std::make_shared<NSString*>(nil);
      for (const auto& session : *sessions) {
        CDP(t, @"Emulation.setFocusEmulationEnabled", @{@"enabled": @NO},
          [id, remaining, failure](NSDictionary*, NSString* error) {
            if (error) *failure = error;
            if (!--*remaining) Reply(id, @{}, *failure);
          }, @(session.c_str()));
      }
      return;
    }
    Reply(id);
  } else if ([method isEqual:@"input.send"]) Input(t, p, id);
  else if (NativeDialogRequest(t, method, p, id)) { return;
  } else if ([method isEqual:@"page.snapshot"]) {
    NSDictionary* proof = p[@"document"];
    if (!DocumentMatches(t, proof)) { Reply(id, nil, @"Snapshot document changed"); return; }
    std::string tabID = t.id;
    uint64_t generation = t.documentGeneration;
    // CDP captures the renderer; AppKit cacheDisplay cannot read CALayerHost.
    CDP(t, @"Page.captureScreenshot", @{@"format": @"png", @"captureBeyondViewport": @NO},
      [id, tabID, generation, proof](NSDictionary* r, NSString* e) {
        auto found = tabs.find(tabID);
        if (found == tabs.end() || found->second.documentGeneration != generation || !DocumentMatches(found->second, proof)) {
          Reply(id, nil, @"Snapshot document changed"); return;
        }
        Reply(id, r, e);
      });
  } else if (AgentRequest(t, method, id)) {
    return;
  } else if (ScriptRequest(t, method, p, id)) {
    return;
  } else if ([method isEqual:@"script.document"]) {
    if (!DocumentMatches(t, p[@"document"])) { Reply(id, nil, @"Target document changed"); return; }
    NSString* expression = S(p, @"expression");
    if (!expression.length) { Reply(id, nil, @"expression is required"); return; }
    Eval(t, expression, [p[@"document"][@"context"] intValue], [id](NSDictionary* r, NSString* e) {
      if (e) Reply(id, nil, e);
      else if (r[@"exceptionDetails"]) Reply(id, nil, JSON(r[@"exceptionDetails"]));
      else Reply(id, r[@"result"][@"value"] ?: NSNull.null);
    }, [p[@"userGesture"] boolValue]);
  } else if ([method isEqual:@"script.evaluate"] || [method isEqual:@"script.bind"]) {
    NSString* world = S(p, @"world");
    if (!world.length || world.length > 128 || [world hasPrefix:@"__yab"]) { Reply(id, nil, @"A non-reserved world name is required"); return; }
    Completion fail = [id](NSDictionary*, NSString* e) { Reply(id, nil, e); };
    if ([method isEqual:@"script.bind"]) {
      NSString* name = S(p, @"name");
      if (!name.length || name.length > 128 || [name hasPrefix:@"__yab"]) { Reply(id, nil, @"Invalid binding name"); return; }
      t.bindings[Key(name)].insert(Key(world));
      // A binding asked for before DevTools attaches is kept and added when
      // the agent attaches (OnDevToolsAgentAttached re-adds every binding).
      if (!t.transportReady) { Reply(id, @{@"pending": @YES}); return; }
      CDP(t, @"Runtime.addBinding", @{@"name": name, @"executionContextName": world}, [id](NSDictionary* r, NSString* e) { Reply(id, r, e); });
    } else {
      NSString* function = S(p, @"function"); if (!function.length) { Reply(id, nil, @"function is required"); return; }
      ::id args = p[@"arguments"] ?: NSNull.null; bool gesture = [p[@"userGesture"] boolValue];
      if (!DocumentMatches(t, p[@"document"])) { Reply(id, nil, @"Target document changed"); return; }
      NSDictionary* document = p[@"document"];
      WithWorld(t.id, world, [id, function, args, gesture, document](Tab& tab, int context) {
        if (!DocumentMatches(tab, document)) { Reply(id, nil, @"Target document changed"); return; }
        CDP(tab, @"Runtime.callFunctionOn", @{@"functionDeclaration": function, @"executionContextId": @(context),
          @"arguments": @[@{@"value": args}], @"awaitPromise": @YES, @"returnByValue": @YES, @"userGesture": @(gesture)},
          [id](NSDictionary* r, NSString* e) {
            if (e) Reply(id, nil, e);
            else if (r[@"exceptionDetails"]) Reply(id, nil, [@"JavaScript exception: " stringByAppendingString:JSON(r[@"exceptionDetails"])]);
            else if (r[@"result"][@"unserializableValue"] || [r[@"result"][@"subtype"] isEqual:@"error"]) Reply(id, nil, @"Script result is not JSON serializable");
            else if (!r[@"result"][@"value"] && ![r[@"result"][@"type"] isEqual:@"undefined"]) Reply(id, nil, @"Script result is not JSON serializable");
            else Reply(id, r[@"result"][@"value"] ?: NSNull.null);
          });
      }, fail);
    }
  } else if ([method isEqual:@"extension.load"]) {
    NSString* path = S(p, @"path");
    BOOL directory = NO;
    if (!path.isAbsolutePath || ![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory] || !directory) { Reply(id, nil, @"Extension path must be an existing absolute directory"); return; }
    if (![Str(b->GetMainFrame()->GetURL()) isEqual:@"chrome://extensions/"]) { Reply(id, nil, @"Use a chrome://extensions/ management tab in the target profile"); return; }
    if (t.extensionLoadPending) { Reply(id, nil, @"An extension load is already pending"); return; }
    t.extensionLoadPending = true; t.extensionPath = path;
    std::string tab = t.id;
    // Chrome owns installation and validation. Its directory chooser receives
    // only the path explicitly supplied by this IPC request, in this profile.
    NSString* expression = @"(async()=>{await chrome.developerPrivate.updateProfileConfiguration({inDeveloperMode:true});const error=await chrome.developerPrivate.loadUnpacked({failQuietly:true,populateError:true});if(error)throw new Error(JSON.stringify(error));return true})()";
    Eval(t, expression, 0, [id, tab](NSDictionary* r, NSString* e) {
      auto current = tabs.find(tab);
      if (current != tabs.end()) { current->second.extensionLoadPending = false; current->second.extensionPath = nil; }
      Reply(id, r[@"result"][@"value"] ?: NSNull.null, e);
    }, true);
  } else if ([method isEqual:@"extension.list"] || [method isEqual:@"extension.review"] || [method isEqual:@"extension.setEnabled"] || [method isEqual:@"extension.remove"] || [method isEqual:@"extension.removalState"]) {
    // Chrome's privileged extension-management UI is kept in this profile.
    // The caller supplies a chrome://extensions tab, never an arbitrary page.
    if (![Str(b->GetMainFrame()->GetURL()) isEqual:@"chrome://extensions/"]) { Reply(id, nil, @"Use a chrome://extensions management tab in the target profile"); return; }
    NSString* error = nil;
    NSString* expression = ExtensionExpression(method, p, &error, YABCORE_EXTENSION_CONSENT);
    if (error) { Reply(id, nil, error); return; }
    // Propagate the native removal confirmation through Chrome's gesture check.
    // ExtensionExpression rejects removal without that explicit confirmation.
    Eval(t, expression, 0, [id](NSDictionary* r, NSString* e) { Reply(id, r[@"result"][@"value"] ?: NSNull.null, e); },
         [method isEqual:@"extension.remove"] && [p[@"userApproved"] isEqual:@YES]);
  } else Reply(id, nil, @"Unknown method");
}
void Shutdown() {
  stopping = true;
  if (!contextInitialized || shutdownStarted) return;
  shutdownStarted = true;
  std::vector<CefRefPtr<CefBrowser>> browsers;
  NSMutableSet* producers = [NSMutableSet new];
  for (auto i = tabs.begin(); i != tabs.end();) {
    auto& t = i->second;
    t.closing = true;
    if (t.native) [producers addObject:t.native];
    if (t.browser) { browsers.push_back(t.browser); ++i; }
    else { Reply(t.createRequest, nil, @"Client exited during tab creation"); i = tabs.erase(i); }
  }
  fprintf(stderr, "YabCore shutdown: closing %zu browsers\n", browsers.size());
  for (auto b : browsers) b->GetHost()->CloseBrowser(true);
  // Chrome menus, extension action widgets and native confirmation windows
  // are not necessarily children of a registered producer. Hide every extra
  // window at once; CEF's own teardown destroys them. Closing a views widget
  // from AppKit here could strand its browser's close sequence.
  for (NSWindow* window in [NSApp.windows copy]) if (![producers containsObject:window]) [window orderOut:nil];
  if (browsers.empty()) { QuitOnce(); return; }
  // A browser whose close never completes must not keep the helper and its
  // GPU/utility children alive after its client is gone.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    if (tabs.empty()) return;
    fprintf(stderr, "YabCore shutdown: %zu browsers did not close, quitting anyway\n", tabs.size());
    QuitOnce();
  });
  // Last resort if the message loop itself is wedged. Children see the
  // browser process vanish and exit on their own.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    fprintf(stderr, "YabCore shutdown: message loop wedged, exiting\n");
    _exit(3);
  });
}
class App : public CefApp, public CefBrowserProcessHandler {
  NSString* socket_;
  NSString* bundle_;
 public:
  App(NSString* root, NSString* socket) : socket_(socket), bundle_(NSBundle.mainBundle.bundlePath) { dataRoot = root; }
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }
  CefRefPtr<CefClient> GetDefaultClient() override { return new Client("", ""); }
#if YABCORE_EXTENSION_CONSENT
  void OnExtensionConsent(CefRefPtr<CefBrowser> b, CefRefPtr<CefDictionaryValue> request, CefRefPtr<CefExtensionConsentCallback> callback) override { NativeConsentRequest(Find(b), request, callback); }
  void OnExtensionConsentWithdrawn(const CefString& request) override { NativeConsentWithdrawn(request.ToString()); }
#endif
  void OnBeforeCommandLineProcessing(const CefString&, CefRefPtr<CefCommandLine> command) override {
    // The global context must not follow Chrome's last-used space profile.
    command->AppendSwitchWithValue("profile-directory", "Default");
    command->AppendSwitch("no-first-run");
#if YABCORE_NATIVE_PAGE
    // Default Chrome-created pages get independent hidden native endpoints
    // before OnAfterCreated publishes tab.created.
    command->AppendSwitch("yab-external-default-windows");
#endif
    command->AppendSwitch("no-default-browser-check");
    // Chrome-style CEF otherwise owns the hidden HTTP authentication prompt.
    command->AppendSwitch("disable-chrome-login-prompt");
    // The parent app owns macOS Now Playing. Preserve MediaSession actions
    // while preventing the hidden helper from registering a second OS player.
    std::string disabled = command->GetSwitchValue("disable-features").ToString();
    disabled += disabled.empty() ? "HardwareMediaKeyHandling" : ",HardwareMediaKeyHandling";
    // Chrome's macOS notification bridge asks for the OS permission under the
    // helper's name (blank icon, unasked). Yab owns that question.
    disabled += ",NativeNotifications,SystemNotifications";
    command->AppendSwitchWithValue("disable-features", disabled);
#if YABCORE_NATIVE_PRINT
    // Page-initiated prints go to the client, not Chrome's print preview.
    command->AppendSwitch("yab-native-print");
#endif
#if YABCORE_EXTENSION_CONSENT
    // Chrome's install/uninstall dialogs go to the client instead of a hidden window.
    command->AppendSwitch("yab-extension-consent");
#endif
#if YABCORE_DISCARD
    // Native discard is off by default on macOS. Keep any features already set.
    std::string features = command->GetSwitchValue("enable-features").ToString();
    features += features.empty() ? "WebContentsDiscard" : ",WebContentsDiscard";
    command->AppendSwitchWithValue("enable-features", features);
#endif
  }
  void OnBeforeChildProcessLaunch(CefRefPtr<CefCommandLine> command) override {
    // An explicit browser_subprocess_path bypasses Chrome's bundle-name
    // inference. Route JIT processes to the role-specific signed executables,
    // rather than weakening the generic utility helper's entitlements.
    auto type = command->GetSwitchValue("type").ToString();
    NSString* name = type == "renderer" ? @"YabCore Helper (Renderer)" :
      type == "gpu-process" ? @"YabCore Helper (GPU)" : nil;
    if (!name) return;
    NSString* path = [bundle_ stringByAppendingFormat:@"/Contents/Frameworks/%@.app/Contents/MacOS/%@", name, name];
    fprintf(stderr, "YabCore child %s: %s -> %s\n", type.c_str(), command->GetProgram().ToString().c_str(), path.UTF8String);
    command->SetProgram(Key(path));
  }
  void OnContextInitialized() override {
    contextInitialized = true;
    if (stopping) { Shutdown(); return; }
    fprintf(stderr, "YabCore canonical root: %s\n", dataRoot.UTF8String);
    if (!wire.Start(socket_)) { fprintf(stderr, "Cannot bind private YabCore socket\n"); QuitOnce(); return; }
    wire.onRequest = Request;
    wire.onDisconnect = [] {
      hello = false; requests.clear(); ClearOriginalPDFPresence(); ClearOriginalPDF();
      NativeSwitchGroupsDisconnected();
      // Transport::Send can overflow from a synchronous native close callback.
      // Retire the connection now, defer all native shutdown mutation until
      // the validate/commit/final callback stack has returned.
      if (nativeCloseDepth) dispatch_async(dispatch_get_main_queue(), ^{ ClearConsents(); BeginShutdown("client disconnected"); });
      else { ClearConsents(); BeginShutdown("client disconnected"); }
    };
    timer = [NSTimer timerWithTimeInterval:0.01 repeats:YES block:^(NSTimer*) {
      wire.Poll(); OriginalPDFPoll();
      if (Now() - lastPoll >= 0.1) { PollLayers(); lastPoll = Now(); }
      std::vector<Completion> expired;
      for (auto i = pending.begin(); i != pending.end();) {
        if (Now() > i->second.deadline) { expired.push_back(i->second.completion); i = pending.erase(i); } else ++i;
      }
      for (auto& completion : expired) completion(nil, @"CDP timeout");
      ExtensionBridgePoll();
      NSMutableArray* overdue = [NSMutableArray new];
      for (auto& [id, deadline] : requests) if (Now() > deadline) [overdue addObject:@(id.c_str())];
      for (NSString* id in overdue) if (!LifecycleExpireRequest(id)) Reply(id, nil, @"Operation timed out");
    }];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
  }
  ~App() override { TearDown(); }
  IMPLEMENT_REFCOUNTING(App);
};
void TearDown() {
  ClearReadPages();
  ClearOriginalPDFPresence(); ClearOriginalPDF();
  ClearPDFStreams();
  [timer invalidate]; timer = nil; wire.onDisconnect = nullptr; wire.Close();
  pending.clear(); pageQuestions.clear(); authAttempts.clear();
  nativeDownloads.clear(); nativeFinds.clear(); filePicks.clear(); pageMenus.clear();
  tabs.clear(); profiles.clear(); browserTabs.clear(); requests.clear();
}
CefRefPtr<CefApp> MakeApp(NSString* root, NSString* socket) { return new App(root, socket); }
}
