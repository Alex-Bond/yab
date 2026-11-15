// Media track: a tab's sound and Now Playing state, its camera and
// microphone, a page's own full screen and Yab's play/pause/seek.
// Confined to the UI thread, keyed by tab ID, cleared on close.
struct MediaState {
  std::map<std::string, NSDictionary*> frames;  // native frame ID -> page report
  NSString* last = nil;
  bool native = false, nativeAudible = false;
  bool camera = false, microphone = false, fullscreen = false;
  std::string primary;  // frame Yab's actions go to
};
static std::map<std::string, MediaState> mediaStates;

static NSString* MediaText(id value, NSUInteger limit) {
  if (![value isKindOfClass:NSString.class]) return @"";
  NSString* text = value;
  return text.length > limit ? [text substringToIndex:limit] : text;
}
static NSNumber* MediaNumber(id value) {
  if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return @(-1);
  double v = [value doubleValue];
  return std::isfinite(v) && fabs(v) < 1e9 ? @(v) : @(-1);
}
static bool MediaBool(id value) { return [value isKindOfClass:NSNumber.class] && [value boolValue]; }
// The report is page-authored: keep only bounded, typed fields.
static NSDictionary* MediaClean(NSDictionary* raw) {
  NSMutableDictionary* out = [@{@"audible": @(MediaBool(raw[@"audible"])), @"playing": @(MediaBool(raw[@"playing"])),
    @"sessionState": MediaText(raw[@"sessionState"], 16)} mutableCopy];
  NSDictionary* s = raw[@"session"];
  if ([s isKindOfClass:NSDictionary.class]) {
    NSMutableArray* art = [NSMutableArray new];
    if ([s[@"artwork"] isKindOfClass:NSArray.class]) for (NSDictionary* a in s[@"artwork"]) {
      if (art.count >= 16 || ![a isKindOfClass:NSDictionary.class]) continue;
      NSString* src = MediaText(a[@"src"], 8192);
      NSString* scheme = [NSURL URLWithString:src].scheme.lowercaseString ?: @"";
      if ([@[@"http", @"https", @"data"] containsObject:scheme]) [art addObject:@{@"src": src, @"sizes": MediaText(a[@"sizes"], 64)}];
    }
    out[@"session"] = @{@"title": MediaText(s[@"title"], 1024), @"artist": MediaText(s[@"artist"], 1024),
      @"album": MediaText(s[@"album"], 1024), @"artwork": art};
  }
  NSDictionary* m = raw[@"media"];
  if ([m isKindOfClass:NSDictionary.class])
    out[@"media"] = @{@"t": MediaNumber(m[@"t"]), @"d": MediaNumber(m[@"d"]), @"paused": @(MediaBool(m[@"paused"])),
      @"muted": @(MediaBool(m[@"muted"])), @"loop": @(MediaBool(m[@"loop"])), @"video": @(MediaBool(m[@"video"]))};
  return out;
}
static void MediaPublish(Tab* t) {
  if (!t || t->internal) return;
  auto& state = mediaStates[t->id];
  // A detached frame that never said goodbye no longer counts.
  for (auto i = state.frames.begin(); i != state.frames.end();) {
    auto frame = t->browser ? t->browser->GetFrameByIdentifier(i->first) : nullptr;
    if (!frame || !frame->IsValid()) i = state.frames.erase(i); else ++i;
  }
  bool audible = false, playing = false;
  std::string sessionFrame, soundFrame, anyFrame;
  for (auto& [frame, report] : state.frames) {
    bool loud = [report[@"audible"] boolValue], plays = [report[@"playing"] boolValue];
    audible |= loud; playing |= plays;
    if (report[@"session"] && (sessionFrame.empty() || loud || plays)) sessionFrame = frame;
    if ((loud || plays) && (soundFrame.empty() || loud)) soundFrame = frame;
    if (report[@"media"] && anyFrame.empty()) anyFrame = frame;
  }
  // Yab's actions go to the frame playing; the name comes from that frame's
  // session, or else from a session elsewhere on the page.
  std::string primary = !soundFrame.empty() ? soundFrame : !sessionFrame.empty() ? sessionFrame : anyFrame;
  state.primary = primary;
  NSDictionary* lead = primary.empty() ? nil : state.frames[primary];
  NSDictionary* named = lead[@"session"] ? lead : sessionFrame.empty() ? nil : state.frames[sessionFrame];
  NSDictionary* payload = @{@"audible": @(state.native ? state.nativeAudible : audible),
    @"audibleSource": state.native ? @"native" : @"page", @"playing": @(playing),
    @"session": named[@"session"] ?: NSNull.null, @"sessionState": named[@"sessionState"] ?: lead[@"sessionState"] ?: @"none",
    @"media": lead[@"media"] ?: NSNull.null, @"frames": @(state.frames.size()),
    @"mainFrame": @(!primary.empty() && t->browser && t->browser->GetMainFrame() &&
                    t->browser->GetMainFrame()->GetIdentifier().ToString() == primary)};
  NSString* text = JSON(payload);
  if ([text isEqual:state.last]) return;
  state.last = text;
  Event(@"media.state", t, payload);
}
static int mediaMessages = 0, mediaErrors = 0;
static std::string mediaLastError;
static bool MediaFrameMessage(Tab* t, CefRefPtr<CefFrame> frame, CefRefPtr<CefProcessMessage> message) {
  if (message->GetName() == "yab.media.error") {
    auto args = message->GetArgumentList();
    ++mediaErrors;
    if (args->GetSize() == 1 && args->GetType(0) == VTYPE_STRING) mediaLastError = args->GetString(0).ToString().substr(0, 300);
    fprintf(stderr, "YabCore media watcher: %s\n", mediaLastError.c_str());
    return true;
  }
  if (message->GetName() != "yab.media.frame") return false;
  ++mediaMessages;
  if (!t || !frame || !frame->IsValid()) return true;
  auto args = message->GetArgumentList();
  if (args->GetSize() != 1 || args->GetType(0) != VTYPE_STRING) return true;
  std::string text = args->GetString(0).ToString();
  if (text.size() > 65536) return true;
  NSDictionary* raw = Decode(text.data(), text.size());
  auto& state = mediaStates[t->id];
  std::string id = frame->GetIdentifier().ToString();
  if (MediaBool(raw[@"gone"])) state.frames.erase(id);
  else if (state.frames.size() < 64 || state.frames.count(id)) state.frames[id] = MediaClean(raw);
  MediaPublish(t);
  return true;
}
static void MediaReset(Tab* t, bool ended = false) {
  if (!t) return;
  auto found = mediaStates.find(t->id);
  if (found == mediaStates.end()) return;
  found->second.frames.clear();
    if (ended) {
      found->second.nativeAudible = false;
      found->second.camera = found->second.microphone = found->second.fullscreen = false;
      Event(@"media.capture", t, @{@"camera": @NO, @"microphone": @NO});
      Event(@"page.fullscreen", t, @{@"fullscreen": @NO});
    }
  MediaPublish(t);
}
static void MediaForget(const std::string& id) { mediaStates.erase(id); }
#if defined(CEF_YAB_AUDIBLE_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_NATIVE_AUDIBLE 1
#else
#define YABCORE_NATIVE_AUDIBLE 0
#endif
static void MediaNativeAudible(Tab* t, bool audible) {
  if (!t) return;
  auto& state = mediaStates[t->id];
  state.native = true; state.nativeAudible = audible;
  MediaPublish(t);
}
static void MediaAccess(Tab* t, bool video, bool audio) {
  if (!t || t->internal) return;
  auto& state = mediaStates[t->id];
  state.camera = video; state.microphone = audio;
  Event(@"media.capture", t, @{@"camera": @(video), @"microphone": @(audio)});
}
static void MediaFullscreen(Tab* t, bool fullscreen) {
  if (!t || t->internal) return;
  mediaStates[t->id].fullscreen = fullscreen;
  Event(@"page.fullscreen", t, @{@"fullscreen": @(fullscreen)});
}

// Chrome style takes a page's full screen into its own window, here the
// concealed producer, which would carry it to a Space of its own nobody can
// see. Producer windows never take a Space: the transition Chromium waits
// for is reported without one, the content fills the producer, and Yab
// shows that page in a full-screen window of its own (page.fullscreen).
static char kMediaProducerFullscreen;
static void MediaProducerToggleFullScreen(id self, SEL, id) {
  NSWindow* window = self;
  bool entering = ![objc_getAssociatedObject(window, &kMediaProducerFullscreen) boolValue];
  objc_setAssociatedObject(window, &kMediaProducerFullscreen, @(entering), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  SEL will = entering ? @selector(windowWillEnterFullScreen:) : @selector(windowWillExitFullScreen:);
  SEL did = entering ? @selector(windowDidEnterFullScreen:) : @selector(windowDidExitFullScreen:);
  NSNotificationName willName = entering ? NSWindowWillEnterFullScreenNotification : NSWindowWillExitFullScreenNotification;
  NSNotificationName didName = entering ? NSWindowDidEnterFullScreenNotification : NSWindowDidExitFullScreenNotification;
  id delegate = window.delegate;
  if ([delegate respondsToSelector:will])
    ((void (*)(id, SEL, id))objc_msgSend)(delegate, will, [NSNotification notificationWithName:willName object:window]);
  __weak NSWindow* weak = window;
  // AppKit reports completion later too; Chromium's controller expects that.
  dispatch_async(dispatch_get_main_queue(), ^{
    NSWindow* strong = weak;
    id current = strong.delegate;
    if (strong && [current respondsToSelector:did])
      ((void (*)(id, SEL, id))objc_msgSend)(current, did, [NSNotification notificationWithName:didName object:strong]);
  });
}
static void MediaProducerWindow(NSWindow* window) {
  if (!window) return;
  // Yab's hosted page can move to its own full-screen Space. Its concealed
  // producer must follow that Space too, otherwise Chromium marks the
  // document hidden and pauses the video despite our hosted layer staying
  // attached. This window never becomes a full-screen primary itself.
  NSWindowCollectionBehavior behavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
    NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorIgnoresCycle |
    NSWindowCollectionBehaviorCanJoinAllApplications;
  if (window.collectionBehavior != behavior) window.collectionBehavior = behavior;
  static std::set<Class> replaced;
  Class type = window.class;  // the declared class, also under KVO
  if (replaced.count(type)) return;
  replaced.insert(type);
  class_replaceMethod(type, @selector(toggleFullScreen:), (IMP)MediaProducerToggleFullScreen, "v@:@");
}

static bool MediaRequest(Tab& t, NSString* method, NSDictionary* p, NSString* request) {
  if ([method isEqual:@"media.read"]) {
    auto& state = mediaStates[t.id];
    state.last = nil; MediaPublish(&t);
    Reply(request, @{@"camera": @(state.camera), @"microphone": @(state.microphone), @"fullscreen": @(state.fullscreen),
      @"browserFullscreen": @(t.browser->GetHost()->IsFullscreen()), @"nativeAudible": @(YABCORE_NATIVE_AUDIBLE != 0),
      @"producerFullscreen": @([objc_getAssociatedObject(t.native, &kMediaProducerFullscreen) boolValue]),
      @"producerStyleFullscreen": @((t.native.styleMask & NSWindowStyleMaskFullScreen) != 0),
      @"producerOnActiveSpace": @(t.native.isOnActiveSpace),
      @"producerVisible": @(t.native.isVisible),
      @"producerOcclusionVisible": @((t.native.occlusionState & NSWindowOcclusionStateVisible) != 0),
      @"producerCollectionBehavior": @(t.native.collectionBehavior),
      @"watcherMessages": @(mediaMessages), @"watcherErrors": @(mediaErrors), @"watcherLastError": @(mediaLastError.c_str()),
      @"healthPending": @(!t.healthToken.empty()), @"healthUnresponsive": @(t.healthUnresponsive),
      @"healthPings": @(t.healthPings), @"healthPongs": @(t.healthPongs),
      @"healthSent": @(t.healthSent), @"healthAgain": @(t.healthAgain),
      @"frames": @(state.frames.size())});
    return true;
  }
  if ([method isEqual:@"page.exitFullscreen"]) {
    t.browser->GetHost()->ExitFullscreen(true);
    Reply(request);
    return true;
  }
  if (![method isEqual:@"media.action"]) return false;
  NSString* action = S(p, @"action");
  if (![@[@"play", @"pause", @"seekto"] containsObject:action]) { Reply(request, nil, @"Unknown media action"); return true; }
  NSNumber* value = p[@"value"];
  if ([action isEqual:@"seekto"] && (![value isKindOfClass:NSNumber.class] || !std::isfinite(value.doubleValue) || value.doubleValue < 0)) {
    Reply(request, nil, @"seekto requires a time"); return true;
  }
  auto& state = mediaStates[t.id];
  std::vector<std::string> targets;
  // Pause reaches every frame playing; the rest go to the frame that leads.
  if ([action isEqual:@"pause"]) { for (auto& [frame, report] : state.frames) if ([report[@"playing"] boolValue]) targets.push_back(frame); }
  else if (!state.primary.empty()) targets.push_back(state.primary);
  int sent = 0;
  for (auto& id : targets) {
    auto frame = t.browser->GetFrameByIdentifier(id);
    if (!frame || !frame->IsValid()) continue;
    auto message = CefProcessMessage::Create("yab.media.action");
    message->GetArgumentList()->SetString(0, Key(action));
    message->GetArgumentList()->SetDouble(1, value ? value.doubleValue : 0);
    frame->SendProcessMessage(PID_RENDERER, message);
    sent++;
  }
  Reply(request, @{@"frames": @(sent)});
  return true;
}
