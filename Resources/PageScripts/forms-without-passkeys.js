(function () {
  var real = window.PublicKeyCredential;
  if (!real) return;
  var claimed = false;
  // Word to yab that the page wanted one (PasskeyHint), through the
  // passkey bridge, once each way per page. Only a word: the page hears
  // what it would have heard anyway.
  var said = {};
  function tell(ask) {
    if (said[ask]) return;
    said[ask] = true;
    // Later, not now: a page that looks as it starts would otherwise
    // speak before the bridge, put in after this, is there to hear.
    setTimeout(function () {
      try {
        window.dispatchEvent(new CustomEvent('__YAB_ASKED__', { detail: JSON.stringify({ token: 'hint', kind: 'missing', ask: ask }) }));
      } catch (e) {}
    }, 0);
  }
  function answered() {
    if (claimed) return true;
    try {
      if (navigator.credentials && Object.getOwnPropertyDescriptor(navigator.credentials, 'get')) claimed = true;
      else if ((new Error().stack || '').indexOf('-extension://') >= 0) claimed = true;
    } catch (e) {}
    return claimed;
  }
  // An extension's script in the page's own world that patches the passkey
  // object as it starts, NordPass's passkeys.js, threw on undefined. It is
  // given one that says no passkey can be made or used here, which is true
  // until an extension answers itself, and takes what is set on it. The
  // page never sees it: it is known by the extension's frames on the stack,
  // which WebKit gives a masked address, never a page's own script.
  var stub = null, defaults = {};
  // Providers may collect all hook parents before installing their own
  // credentials.get (1Password does). Their capability hooks then land on
  // the stand-in. Once a provider claims credentials, carry only its
  // overrides to the object pages see; the stand-in's defaults stay private.
  function supplied() {
    if (stub) Object.keys(defaults).forEach(function (name) {
      var hook = Object.getOwnPropertyDescriptor(stub, name);
      if (!hook || (!hook.get && !hook.set && hook.value === defaults[name])) return;
      try { Object.defineProperty(real, name, hook); } catch (e) {}
    });
    return real;
  }
  function fromExtension() {
    try { var stack = new Error().stack || ''; return stack.indexOf('webkit-masked-url:') >= 0; }
    catch (e) { return false; }
  }
  function standIn() {
    if (stub) return stub;
    stub = function PublicKeyCredential() { throw new TypeError('Illegal constructor'); };
    try { stub.prototype = real.prototype; } catch (e) {}
    var no = function () { return Promise.resolve(false); };
    stub.isUserVerifyingPlatformAuthenticatorAvailable = no;
    stub.isConditionalMediationAvailable = no;
    stub.getClientCapabilities = function () {
      return Promise.resolve({ conditionalCreate: false, conditionalGet: false, hybridTransport: false, passkeyPlatformAuthenticator: false,
        userVerifyingPlatformAuthenticator: false, relatedOrigins: false, signalAllAcceptedCredentials: false,
        signalCurrentUserDetails: false, signalUnknownCredential: false });
    };
    ['isUserVerifyingPlatformAuthenticatorAvailable', 'isConditionalMediationAvailable', 'getClientCapabilities'].forEach(function (name) {
      defaults[name] = stub[name];
    });
    ['parseCreationOptionsFromJSON', 'parseRequestOptionsFromJSON'].forEach(function (name) {
      if (typeof real[name] === 'function') stub[name] = real[name].bind(real);
    });
    return stub;
  }
  try {
    Object.defineProperty(window, 'PublicKeyCredential', {
      configurable: true,
      get: function () {
        if (answered()) return supplied();
        if (fromExtension()) return standIn();
        tell('look');
        return undefined;
      },
      set: function (value) { real = value; }
    });
  } catch (e) {
    try { delete window.PublicKeyCredential; } catch (ignored) {}
    return;
  }
  var proto = CredentialsContainer.prototype;
  ['get', 'create'].forEach(function (name) {
    var native = proto[name];
    try {
      Object.defineProperty(proto, name, {
        configurable: true, writable: true,
        value: function (options) {
          if (!options || !options.publicKey) return native.apply(this, arguments);
          var signal = options.signal;
          // Under the name field: nothing to offer, so it waits, as it
          // would while nobody picks one, until the page lets it go.
          if (name === 'get' && options.mediation === 'conditional') {
            return new Promise(function (resolve, reject) {
              if (!signal) return;
              var aborted = function () { return signal.reason || new DOMException('The operation was aborted.', 'AbortError'); };
              if (signal.aborted) return reject(aborted());
              signal.addEventListener('abort', function () { reject(aborted()); }, { once: true });
            });
          }
          tell('request');
          return Promise.reject(new DOMException('The operation either timed out or was not allowed.', 'NotAllowedError'));
        }
      });
    } catch (e) {}
  });
})();
