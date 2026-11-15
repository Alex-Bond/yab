(function () {
  // A page that offers its Chrome extension only to Chrome, told it is in
  // Chrome down to its own globals (SiteAgent.extensionHosts). The agent is
  // Chrome's already (SiteAgent.apply); what is left is what WebKit has and
  // Chrome doesn't, or the other way round: navigator.vendor,
  // navigator.userAgentData and window.chrome. In the page's own world,
  // before anything of the site's runs. Not when the agent isn't Chrome's
  // (Developer Mode's Device), so the page never hears two browsers at once.
  if (window.__yabChromeLike || !/ Chrome\//.test(navigator.userAgent)) return;
  try { Object.defineProperty(window, '__yabChromeLike', { value: true }); } catch (e) { return; }
  var major = '__YAB_MAJOR__';
  var full = major + '.0.0.0';
  var proto = Navigator.prototype;
  // Some sites, including Superhuman Mail, read appVersion separately.
  // Keep it consistent with the request's Chrome user agent.
  try {
    Object.defineProperty(proto, 'appVersion', { get: function () { return navigator.userAgent.replace(/^Mozilla\//, ''); }, configurable: true, enumerable: true });
  } catch (e) {}
  try {
    Object.defineProperty(proto, 'vendor', { get: function () { return 'Google Inc.'; }, configurable: true, enumerable: true });
  } catch (e) {}
  // Superhuman Mail registers itself for mailto: as its main view mounts, with
  // no check, and shows its error page when the call throws. WebKit has
  // neither call; here they ask nothing and change nothing.
  ['registerProtocolHandler', 'unregisterProtocolHandler'].forEach(function (name) {
    if (name in proto) return;
    try { Object.defineProperty(proto, name, { value: function () {}, writable: true, configurable: true, enumerable: true }); } catch (e) {}
  });
  if (!('userAgentData' in navigator)) {
    var brands = [{ brand: 'Chromium', version: major }, { brand: 'Google Chrome', version: major }, { brand: 'Not.A/Brand', version: '99' }];
    var low = { brands: brands, mobile: false, platform: 'macOS' };
    var high = {
      architecture: 'arm', bitness: '64', model: '', platformVersion: '10.15.7', wow64: false, uaFullVersion: full,
      fullVersionList: brands.map(function (b) { return { brand: b.brand, version: b.version === major ? full : b.version + '.0.0.0' }; }),
    };
    var data = {
      brands: brands, mobile: false, platform: 'macOS',
      getHighEntropyValues: function (hints) {
        var out = Object.assign({}, low);
        (Array.isArray(hints) ? hints : []).forEach(function (h) { if (h in high) out[h] = high[h]; });
        return Promise.resolve(out);
      },
      toJSON: function () { return low; },
    };
    try { Object.defineProperty(proto, 'userAgentData', { get: function () { return data; }, configurable: true, enumerable: true }); } catch (e) {}
  }
  // Chrome's window.chrome on a page no extension talks to: no runtime.
  // An installed extension that lets the page in adds its own
  // (extension-external-page.js), on this same object.
  if (!window.chrome || typeof window.chrome !== 'object') {
    var chrome = {
      app: {
        isInstalled: false,
        getDetails: function () { return null; },
        getIsInstalled: function () { return false; },
        InstallState: { DISABLED: 'disabled', INSTALLED: 'installed', NOT_INSTALLED: 'not_installed' },
        RunningState: { CANNOT_RUN: 'cannot_run', READY_TO_RUN: 'ready_to_run', RUNNING: 'running' },
      },
      csi: function () { return { startE: Date.now(), onloadT: Date.now(), pageT: performance.now(), tran: 15 }; },
      loadTimes: function () { return {}; },
    };
    try { Object.defineProperty(window, 'chrome', { value: chrome, writable: true, configurable: true, enumerable: true }); } catch (e) {}
  }
})();
