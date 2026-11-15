// A push that came through Yab's own box, handed to a site's service worker
// with no page of the site open. Chromium's Push API talks to Google's push
// service, which Yab doesn't use (docs/site-notifications.md). The door into
// a worker is the one DevTools' Push button uses: ServiceWorker.deliverPushMessage
// goes through the same router a real push does. That domain lives on a page,
// so each profile gets one internal blank page while pushes are arriving.
struct PushWaiting { NSString* origin; NSString* scope; NSString* data; NSString* request; double since; };
struct PushDoor {
  std::string tab;
  bool enabled = false;
  double lastUsed = 0;
  std::map<std::string, std::string> scopes;  // scope URL to registration id
  std::vector<PushWaiting> waiting;
};
static std::map<std::string, PushDoor> pushDoors;
static constexpr double kPushScopeWait = 3, kPushDoorIdle = 30;
static void PushDoorSend(PushDoor& door, Tab& tab) {
  for (auto i = door.waiting.begin(); i != door.waiting.end();) {
    auto registration = door.scopes.find(Key(i->scope));
    bool late = Now() - i->since > kPushScopeWait;
    if (registration == door.scopes.end() && !late) { ++i; continue; }
    PushWaiting waiting = *i;
    i = door.waiting.erase(i);
    if (registration == door.scopes.end()) { Reply(waiting.request, @{@"delivered": @NO}); continue; }
    CDP(tab, @"ServiceWorker.deliverPushMessage", @{@"origin": waiting.origin, @"registrationId": @(registration->second.c_str()), @"data": waiting.data},
        [request = waiting.request](NSDictionary*, NSString* error) { Reply(request, @{@"delivered": @(error == nil), @"error": error ?: @""}); });
  }
}
static void PushDoorPoll() {
  for (auto i = pushDoors.begin(); i != pushDoors.end();) {
    auto found = tabs.find(i->second.tab);
    if (found == tabs.end() || found->second.closing) { i = pushDoors.erase(i); continue; }
    Tab& tab = found->second;
    if (!i->second.enabled && tab.browser && tab.transportReady) {
      i->second.enabled = true;
      CDP(tab, @"ServiceWorker.enable", @{}, Ignore);
    }
    if (i->second.enabled) PushDoorSend(i->second, tab);
    if (i->second.waiting.empty() && Now() - i->second.lastUsed > kPushDoorIdle) {
      tab.closing = true;
      if (tab.browser) tab.browser->GetHost()->CloseBrowser(true);
      i = pushDoors.erase(i);
      continue;
    }
    ++i;
  }
}
static bool PushDoorEvent(Tab& tab, NSString* method, NSDictionary* params) {
  if (!tab.internal || ![method isEqual:@"ServiceWorker.workerRegistrationUpdated"]) return false;
  auto door = pushDoors.find(tab.profile);
  if (door == pushDoors.end() || door->second.tab != tab.id) return false;
  for (NSDictionary* row in params[@"registrations"]) {
    if ([row[@"isDeleted"] boolValue]) door->second.scopes.erase(Key(S(row, @"scopeURL")));
    else door->second.scopes[Key(S(row, @"scopeURL"))] = Key(S(row, @"registrationId"));
  }
  PushDoorSend(door->second, tab);
  return true;
}
static bool PushRequest(NSString* method, NSDictionary* p, NSString* request) {
  if (![method isEqual:@"push.deliver"]) return false;
  std::string profile = Key(S(p, @"profile"));
  auto found = profiles.find(profile);
  if (found == profiles.end() || found->second.privateMode) { Reply(request, @{@"delivered": @NO}); return true; }
  auto door = pushDoors.find(profile);
  if (door == pushDoors.end()) {
    std::string tab = Create(profile, @"about:blank", nil, true);
    if (tab.empty()) { Reply(request, @{@"delivered": @NO}); return true; }
    door = pushDoors.emplace(profile, PushDoor{tab}).first;
  }
  door->second.lastUsed = Now();
  door->second.waiting.push_back({S(p, @"origin"), S(p, @"scope"), S(p, @"data"), request, Now()});
  return true;
}
