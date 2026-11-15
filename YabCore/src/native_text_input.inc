// Exact original focused-document IME API adapter. No FindView/input.send/JS
// fallback exists here. All completion writes leave the native callback stack.
#if YABCORE_NATIVE_TEXT_FOCUS_API
struct NativeTextInputPending {
  std::string tab, profile;
  int browser = 0;
  NSString* request = nil;
  NSDictionary* expected = nil;  // No text or surrounding content retained.
  bool completed = false;
};
static std::map<std::string, std::shared_ptr<NativeTextInputPending>> nativeTextInputs;
static NSArray<NSString*>* NativeTextStringKeys() {
  return @[@"command", @"focusToken", @"nativeDocument", @"frameId", @"nativeFocusEpoch", @"nativeFrameFocusEpoch", @"kind"];
}
static NSArray<NSString*>* NativeTextIntegerKeys() {
  return @[@"node", @"selectionStart", @"selectionEnd", @"replacementStart", @"replacementEnd"];
}
static bool NativeTextInteger(::id value, int minimum, int maximum) {
  if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return false;
  double number = [value doubleValue];
  return std::isfinite(number) && std::trunc(number) == number && number >= minimum && number <= maximum;
}
static bool NativeTextResultMatches(const std::shared_ptr<NativeTextInputPending>& pending, NSDictionary* native) {
  bool exact = NativeTextInteger(native[@"version"], 1, 1);
  for (NSString* key in NativeTextStringKeys()) exact &= [native[key] isEqual:pending->expected[key]];
  for (NSString* key in NativeTextIntegerKeys())
    exact &= NativeTextInteger(native[key], INT_MIN, INT_MAX) && [native[key] isEqual:pending->expected[key]];
  return exact && [@[@"applied", @"rejected", @"unknown"] containsObject:S(native, @"status")];
}
static void CompleteNativeTextInput(const std::shared_ptr<NativeTextInputPending>& pending,
                                    NSDictionary* native, NSString* fallback, NSString* origin) {
  if (pending->completed) return;
  pending->completed = true;
  auto found = nativeTextInputs.find(Key(S(pending->expected, @"command")));
  if (found != nativeTextInputs.end() && found->second == pending) nativeTextInputs.erase(found);
  bool acknowledged = native && NativeTextResultMatches(pending, native);
  NSString* status = acknowledged ? S(native, @"status") : (native ? @"unknown" : fallback);
  NSMutableDictionary* result = [pending->expected mutableCopy];
  result[@"version"] = @1; result[@"status"] = status ?: @"unknown";
  result[@"tab"] = @(pending->tab.c_str()); result[@"profile"] = @(pending->profile.c_str());
  result[@"browserId"] = @(pending->browser); result[@"resultSource"] = origin;
  result[@"nativeAcknowledged"] = @(acknowledged);
  NSString* request = pending->request;
  dispatch_async(dispatch_get_main_queue(), ^{ Reply(request, result); });
}
class NativeTextInputDone : public CefExternalTextInputCallback {
  std::shared_ptr<NativeTextInputPending> pending_;
 public:
  explicit NativeTextInputDone(std::shared_ptr<NativeTextInputPending> pending) : pending_(std::move(pending)) {}
  void OnExternalTextInputResult(CefRefPtr<CefDictionaryValue> result) override {
    NSDictionary* native = result ? NativeDictionary(result) : nil;
    // This trace is produced ONLY by the real native API callback. A helper
    // timeout/OnBeforeClose unknown must never stand in for destructor proof.
    NSDictionary* trace = @{@"command": S(pending_->expected, @"command"),
      @"status": S(native, @"status"), @"exact": @(native && NativeTextResultMatches(pending_, native)),
      @"afterHelperTerminal": @(pending_->completed)};
    fprintf(stderr, "YAB_NATIVE_TEXT_ACK %s\n", JSON(trace).UTF8String);
    CompleteNativeTextInput(pending_, native, @"unknown", @"native");
  }
  IMPLEMENT_REFCOUNTING(NativeTextInputDone);
};
#endif

static void NativeTextInputClosed(CefRefPtr<CefBrowser> browser) {
#if YABCORE_NATIVE_TEXT_FOCUS_API
  std::vector<std::shared_ptr<NativeTextInputPending>> pending;
  for (const auto& [id, item] : nativeTextInputs)
    if (item->browser == browser->GetIdentifier()) pending.push_back(item);
  for (const auto& item : pending) CompleteNativeTextInput(item, nil, @"unknown", @"helper-browser-closed");
#else
  (void)browser;
#endif
}
static bool NativeTextInputRequest(Tab& tab, NSString* method, NSDictionary* p, NSString* request) {
  if (![method isEqual:@"input.text.native"]) return false;
#if YABCORE_NATIVE_TEXT_FOCUS
  if (!tab.browser || tab.closing || tab.crashed || !tab.adopted || tab.internal || !tab.visible ||
      ![S(p, @"profile") isEqual:@(tab.profile.c_str())]) {
    Reply(request, nil, @"Original native input owner is unavailable"); return true;
  }
  NSString* command = S(p, @"command"), *text = S(p, @"text"), *kind = S(p, @"kind");
  if (!command.length || [command lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 128 ||
      ![p[@"text"] isKindOfClass:NSString.class] || text.length > 65536 || ![@[@"compose", @"commit", @"unmark", @"cancel"] containsObject:kind]) {
    Reply(request, nil, @"Invalid native input command"); return true;
  }
  for (NSString* key in @[@"focusToken", @"nativeDocument", @"frameId", @"nativeFocusEpoch", @"nativeFrameFocusEpoch"])
    if (!S(p, key).length || S(p, key).length > 256) { Reply(request, nil, @"Missing native input identity"); return true; }
  if (!NativeTextInteger(p[@"node"], 1, INT_MAX) ||
      !NativeTextInteger(p[@"selectionStart"], 0, 65536) || !NativeTextInteger(p[@"selectionEnd"], 0, 65536) ||
      !NativeTextInteger(p[@"replacementStart"], -1, INT_MAX) || !NativeTextInteger(p[@"replacementEnd"], -1, INT_MAX)) {
    Reply(request, nil, @"Exact native UTF16 integers required"); return true;
  }
  int start = [p[@"selectionStart"] intValue], end = [p[@"selectionEnd"] intValue];
  int rs = [p[@"replacementStart"] intValue], re = [p[@"replacementEnd"] intValue];
  bool absent = rs == -1 && re == -1;
  if (([kind isEqual:@"compose"] ? (end < start || end > (int)text.length) : (start != 0 || end != 0)) ||
      (!absent && (rs < 0 || re < rs)) ||
      (([kind isEqual:@"unmark"] || [kind isEqual:@"cancel"]) && (text.length || !absent))) {
    Reply(request, nil, @"Invalid native composition ranges"); return true;
  }
  if (nativeTextInputs.size() >= 32 || nativeTextInputs.count(Key(command))) {
    Reply(request, nil, @"Native input command is already pending or bounded"); return true;
  }
  for (const auto& [id, item] : nativeTextInputs)
    if (item->browser == tab.browser->GetIdentifier()) {
      Reply(request, nil, @"An original native input is still pending"); return true;
    }
  auto pending = std::make_shared<NativeTextInputPending>();
  pending->tab = tab.id; pending->profile = tab.profile; pending->browser = tab.browser->GetIdentifier(); pending->request = request;
  NSMutableDictionary* echo = [NSMutableDictionary dictionary];
  for (NSString* key in NativeTextStringKeys()) echo[key] = p[key];
  for (NSString* key in NativeTextIntegerKeys()) echo[key] = p[key];
  pending->expected = echo;
  auto native = CefDictionaryValue::Create();
  for (NSString* key in NativeTextStringKeys()) native->SetString(Key(key), Key(S(p, key)));
  for (NSString* key in NativeTextIntegerKeys()) native->SetInt(Key(key), [p[key] intValue]);
  native->SetString("text", Key(text));
  nativeTextInputs.emplace(Key(command), pending);
  // false is a before-effect rejection; true owns a later exact native ACK.
  if (!tab.browser->GetHost()->SendExternalTextInput(native, new NativeTextInputDone(pending)))
    CompleteNativeTextInput(pending, nil, @"rejected", @"native-dispatch-rejected");
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    // Timeout is uncertain; it does NOT cancel, retry, finish or route input.
    CompleteNativeTextInput(pending, nil, @"unknown", @"helper-timeout");
  });
#else
  (void)tab; (void)p;
  Reply(request, nil, @"Native focused-document input API is unavailable");
#endif
  return true;
}
