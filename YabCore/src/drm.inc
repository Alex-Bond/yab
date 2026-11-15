// Included by core.mm after CDP/Eval. Keep the DRM track out of the dispatcher.
// This binding only requests an engine change of its own native top-level URL.
// It grants no extension identity, cookie access or privileged script execution.
static void DRMWhenReady(std::string id, std::function<void(Tab&)> ready, std::function<void(NSString*)> failed, double deadline) {
  // Browser creation precedes DevTools attachment. Also leave observer callbacks
  // before sending the next command, as CEF forbids reentrant dispatch.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    auto tab = tabs.find(id);
    if (tab == tabs.end() || tab->second.closing) { failed(@"Tab closed"); return; }
    if (!tab->second.domainsReady) {
      if (Running() >= deadline) { failed(@"DRM hook timed out waiting for DevTools"); return; }
      DRMWhenReady(id, ready, failed, deadline);
      return;
    }
    ready(tab->second);
  });
}
static void DRMCDP(std::string id, NSString* method, NSDictionary* params, Completion done, double deadline) {
  DRMWhenReady(id, [method, params, done](Tab& tab) { CDP(tab, method, params, done); },
               [done](NSString* error) { done(nil, error); }, deadline);
}
static NSString* DRMHookSource() {
  return @R"JS((()=>{
        if (top !== self) return;
        // Chrome's install sheet belongs to a window nobody sees: prompt()
        // would never answer. Without the event a site offers no install.
        addEventListener('beforeinstallprompt', event => event.stopImmediatePropagation(), true);
        const notify = globalThis.__yabWidevineRejected;
        let sent = false;
        const refused = key => {
          if (sent || key !== 'com.widevine.alpha') return;
          sent = true;
          notify(JSON.stringify({keySystem:key}));
        };
        const access = navigator.requestMediaKeySystemAccess;
        if (access) navigator.requestMediaKeySystemAccess = function(key, configurations) {
          return Reflect.apply(access, this, [key, configurations]).catch(error => {
            if (error?.name === 'NotSupportedError') refused(key);
            throw error;
          });
        };
        // Shaka and others ask this instead: it answers `supported: false` and never throws.
        const capabilities = navigator.mediaCapabilities, decoding = capabilities?.decodingInfo;
        if (decoding) capabilities.decodingInfo = function(configuration) {
          return Reflect.apply(decoding, this, [configuration]).then(info => {
            if (!info.supported) refused(configuration?.keySystemConfiguration?.keySystem);
            return info;
          });
        };
      })())JS";
}
static void InstallDRM(Tab& tab, Completion done, bool runImmediately = false) {
  if (tab.drmReady) { done(@{}, nil); return; }
  // One installation at a time: a second navigation must not add a second hook.
  tab.drmWaiters.push_back(done);
  if (tab.drmInstalling) return;
  tab.drmInstalling = true;
  std::string id = tab.id;
  Completion finish = [id](NSDictionary* result, NSString* error) {
    auto t = tabs.find(id);
    if (t == tabs.end()) return;
    t->second.drmInstalling = false;
    auto waiters = std::move(t->second.drmWaiters);
    t->second.drmWaiters.clear();
    for (auto& waiter : waiters) waiter(result, error);
  };
  DRMCDP(id, @"Runtime.addBinding", @{@"name": @"__yabWidevineRejected"},
    [id, finish, runImmediately](NSDictionary*, NSString* error) {
      auto t = tabs.find(id);
      if (error || t == tabs.end()) { finish(nil, error ?: @"Tab closed"); return; }
      DRMCDP(id, @"Page.addScriptToEvaluateOnNewDocument",
        @{@"source": DRMHookSource(), @"runImmediately": @(runImmediately)},
        [id, finish](NSDictionary* result, NSString* error) {
          auto t = tabs.find(id);
          if (!error && t != tabs.end()) t->second.drmReady = true;
          NSString* outcome = error ?: (t == tabs.end() ? @"Tab closed" : nil);
          // A navigation continuation must leave CEF's observer loop first.
          // Source-built CEF rejects nested DevTools observer notifications.
          dispatch_async(dispatch_get_main_queue(), ^{ finish(result, outcome); });
        }, Running() + 10);
    }, Running() + 10);
}
