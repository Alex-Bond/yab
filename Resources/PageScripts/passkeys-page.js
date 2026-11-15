(function () {
  if (!window.PublicKeyCredential || !window.CredentialsContainer) return;
  // A frame from another site, an ad's, a payment's, a sign-in's: it
  // can't ask on the page's behalf, so the whole of this would be for
  // nothing. On WebKit it keeps WebKit's own, but for the one request that
  // jams macOS's passkey agent, the one waiting under a field, which waits
  // here instead. Chromium's own runs in the helper, whose window nobody
  // sees: its dialog stood there unseen with Touch ID armed behind it, the
  // page grayed under it and the helper in front of Yab (feedback #1843).
  // So on Chromium a web frame asks Yab like any other, which knows the
  // frame from the helper and turns another site's down at once.
  if (window !== window.top) {
    var up = location.ancestorOrigins, above = up && up.length ? up[up.length - 1] : null;
    var there = above ? new URL(above).hostname : location.hostname, here = location.hostname;
    var web = location.protocol === 'https:' || location.protocol === 'http:';
    if (there !== here && !there.endsWith('.' + here) && !here.endsWith('.' + there)
        && ('__YAB_OTHER_SITES__' === 'engine' || !web)) {
      var C = CredentialsContainer.prototype, own = C.get, held = Symbol.for('yab.passkeys');
      if (C[held]) return;
      try { Object.defineProperty(C, held, { value: navigator.credentials }); } catch (e) { return; }
      try {
        Object.defineProperty(C, 'get', { configurable: true, writable: true, value: function get(options) {
          if (!options || !options.publicKey || options.mediation !== 'conditional') return own.apply(this, arguments);
          var signal = options.signal;
          return new Promise(function (resolve, reject) {
            if (!signal) return;
            if (signal.aborted) return reject(signal.reason);
            signal.addEventListener('abort', function () { reject(signal.reason); }, { once: true });
          });
        } });
      } catch (e) {}
      return;
    }
  }
  var proto = CredentialsContainer.prototype;
  // In once, whichever copy comes first, an extension's (see
  // ExtensionShims.passkeys) or yab's own, and marked on the prototype
  // rather than on the window. The mark holds navigator.credentials too:
  // held, WebKit keeps it, and an extension's own get and create on it
  // with it.
  var mark = Symbol.for('yab.passkeys');
  if (proto[mark]) return;
  try { Object.defineProperty(proto, mark, { value: navigator.credentials }); } catch (e) { return; }
  var nativeGet = proto.get, nativeCreate = proto.create;
  var refused = 'The operation either timed out or was not allowed.';

  function bytes(source) {
    if (source instanceof ArrayBuffer) return new Uint8Array(source);
    if (ArrayBuffer.isView(source)) return new Uint8Array(source.buffer, source.byteOffset, source.byteLength);
    throw new TypeError('Expected an ArrayBuffer or a view of one.');
  }
  function encode(source) {
    var b = bytes(source), s = '';
    for (var i = 0; i < b.length; i++) s += String.fromCharCode(b[i]);
    return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  }
  function decode(text) {
    var s = (text || '').replace(/-/g, '+').replace(/_/g, '/');
    while (s.length % 4) s += '=';
    var raw = atob(s), out = new Uint8Array(raw.length);
    for (var i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
    return out.buffer;
  }
  function descriptors(list) {
    return Array.prototype.map.call(list || [], function (c) {
      return { id: encode(c.id), transports: Array.prototype.slice.call(c.transports || []) };
    });
  }
  // A PRF's salts as the page gave them; yab's side hands them to macOS,
  // which hashes them as WebAuthn says.
  function prfValues(values) {
    if (!values || values.first == null) return null;
    var out = { first: encode(values.first) };
    if (values.second != null) out.second = encode(values.second);
    return out;
  }
  function prfInput(extensions) {
    var prf = extensions && extensions.prf;
    if (!prf) return null;
    var out = { eval: prfValues(prf.eval) };
    if (prf.evalByCredential) {
      out.byCredential = {};
      Object.keys(prf.evalByCredential).forEach(function (id) { out.byCredential[id] = prfValues(prf.evalByCredential[id]); });
    }
    return out;
  }
  function aborted(signal) {
    return signal.reason !== undefined ? signal.reason : new DOMException('The operation was aborted.', 'AbortError');
  }
  // Methods stay writable, as WebKit's own on the prototype are: GitHub's
  // webauthn-json sets its own toJSON on the credential it gets back.
  function define(target, values, hidden) {
    Object.keys(values).forEach(function (k) {
      Object.defineProperty(target, k, { value: values[k], enumerable: !hidden, configurable: true, writable: !!hidden });
    });
    return target;
  }

  function credential(reply, extensions) {
    var response, made = reply.kind === 'create';
    if (made) {
      response = Object.create(AuthenticatorAttestationResponse.prototype);
      define(response, { clientDataJSON: decode(reply.clientDataJSON), attestationObject: decode(reply.attestationObject) });
      define(response, {
        getTransports: function () { return (reply.transports || []).slice(); },
        getAuthenticatorData: function () { return decode(reply.authenticatorData); },
        getPublicKey: function () { return reply.publicKey ? decode(reply.publicKey) : null; },
        getPublicKeyAlgorithm: function () { return reply.publicKeyAlgorithm != null ? reply.publicKeyAlgorithm : -7; }
      }, true);
    } else {
      response = Object.create(AuthenticatorAssertionResponse.prototype);
      define(response, {
        clientDataJSON: decode(reply.clientDataJSON),
        authenticatorData: decode(reply.authenticatorData),
        signature: decode(reply.signature),
        userHandle: reply.userHandle ? decode(reply.userHandle) : null
      });
    }
    // A passkey from the Mac is always one the site can find without
    // naming it; the site may have asked whether it is.
    var results = {};
    if (made && extensions && extensions.credProps && reply.attachment === 'platform') results.credProps = { rk: true };
    // PRF, the secret a passkey derives for a salt: what Bitwarden unlocks
    // its vault with. Bytes from getClientExtensionResults, as in Chromium,
    // and base64url in toJSON.
    if (extensions && extensions.prf && reply.prf) {
      results.prf = {};
      if (reply.prf.enabled != null) results.prf.enabled = !!reply.prf.enabled;
      if (reply.prf.first) results.prf.results = reply.prf.second ? { first: reply.prf.first, second: reply.prf.second } : { first: reply.prf.first };
    }
    function extensionResults() {
      var out = JSON.parse(JSON.stringify(results));
      if (out.prf && out.prf.results) {
        out.prf.results.first = decode(out.prf.results.first);
        if (out.prf.results.second) out.prf.results.second = decode(out.prf.results.second);
      }
      return out;
    }
    var attachment = reply.attachment || null;
    var json = { id: reply.id, rawId: reply.id, type: 'public-key', authenticatorAttachment: attachment, clientExtensionResults: results };
    json.response = made
      ? { clientDataJSON: reply.clientDataJSON, attestationObject: reply.attestationObject, authenticatorData: reply.authenticatorData,
          transports: (reply.transports || []).slice(), publicKeyAlgorithm: reply.publicKeyAlgorithm != null ? reply.publicKeyAlgorithm : -7 }
      : { clientDataJSON: reply.clientDataJSON, authenticatorData: reply.authenticatorData, signature: reply.signature };
    if (made && reply.publicKey) json.response.publicKey = reply.publicKey;
    if (!made && reply.userHandle) json.response.userHandle = reply.userHandle;
    var result = Object.create(PublicKeyCredential.prototype);
    define(result, { id: reply.id, rawId: decode(reply.id), type: 'public-key', authenticatorAttachment: attachment, response: response });
    return define(result, {
      getClientExtensionResults: extensionResults,
      toJSON: function () { return JSON.parse(JSON.stringify(json)); }
    }, true);
  }

  var waiting = {};
  window.addEventListener('__YAB_ANSWERED__', function (event) {
    var data;
    try { data = JSON.parse(event.detail); } catch (e) { return; }
    var done = data && waiting[data.token];
    if (!done) return;
    delete waiting[data.token];
    done(data.reply);
  });
  function ask(message) {
    return new Promise(function (resolve) {
      if (message.kind === 'cancel') resolve(true); else waiting[message.token] = resolve;
      window.dispatchEvent(new CustomEvent('__YAB_ASKED__', { detail: JSON.stringify(message) }));
    });
  }

  function send(request, signal, extensions) {
    if (signal && signal.aborted) return Promise.reject(aborted(signal));
    request.token = Math.random().toString(36).slice(2);
    return new Promise(function (resolve, reject) {
      // Only while it is still out: a cancel for one already answered
      // would be kept by Yab for nothing.
      if (signal) signal.addEventListener('abort', function () {
        if (waiting[request.token]) ask({ kind: 'cancel', token: request.token });
        reject(aborted(signal));
      }, { once: true });
      ask(request).then(function (reply) {
        if (!reply || reply.error) {
          var name = (reply && reply.error) || 'NotAllowedError';
          var message = (reply && reply.message) || refused;
          return reject(name === 'TypeError' ? new TypeError(message) : new DOMException(message, name));
        }
        resolve(credential(reply, extensions));
      }, function () { reject(new DOMException(refused, 'NotAllowedError')); });
    });
  }

  function replace(target, name, value) {
    try { Object.defineProperty(target, name, { value: value, configurable: true, writable: true }); } catch (e) {}
  }

  replace(proto, 'get', function get(options) {
    if (!options || !options.publicKey) return nativeGet.apply(this, arguments);
    var signal = options.signal, pk = options.publicKey, request;
    // Chrome's immediate UI mode (uiMode: 'immediate' since Chrome 149,
    // mediation: 'immediate' in its trial): a credential only if one is at
    // hand without asking, else NotAllowedError at once, with no sheet, no
    // phone and no security key. Nothing of the Mac's can be looked at
    // without its sheet, so nothing is at hand: the page goes on to its own
    // sign-in, as in a browser with none saved. Taken as an ordinary
    // request, it brought up the Mac's whole sheet, Touch ID and all, where
    // the page meant to ask quietly, and Chromium tabs before 0.46.11 even
    // told pages they had it (immediateGet, feedback #1843).
    if (options.uiMode === 'immediate' || options.mediation === 'immediate') {
      return Promise.reject(new DOMException(refused, 'NotAllowedError'));
    }
    if (options.mediation === 'conditional') {
      // Nothing of the Mac's is offered under the field yet: the request
      // waits, as it does while nobody picks a passkey, until the page
      // lets it go.
      return new Promise(function (resolve, reject) {
        if (!signal) return;
        if (signal.aborted) return reject(aborted(signal));
        signal.addEventListener('abort', function () { reject(aborted(signal)); }, { once: true });
      });
    }
    try {
      request = {
        kind: 'get', challenge: encode(pk.challenge), rpId: pk.rpId || null,
        allowCredentials: descriptors(pk.allowCredentials),
        userVerification: pk.userVerification || 'preferred',
        prf: prfInput(pk.extensions)
      };
    } catch (e) { return Promise.reject(e); }
    return send(request, signal, pk.extensions);
  });

  replace(proto, 'create', function create(options) {
    if (!options || !options.publicKey) return nativeCreate.apply(this, arguments);
    var pk = options.publicKey, selection = pk.authenticatorSelection || {}, request;
    // A passkey made quietly after a password sign-in: not something
    // this browser does yet, so the site hears no, as it would if you had.
    if (options.mediation === 'conditional') return Promise.reject(new DOMException(refused, 'NotAllowedError'));
    try {
      request = {
        kind: 'create', challenge: encode(pk.challenge),
        rp: { id: (pk.rp && pk.rp.id) || null },
        user: { id: encode(pk.user.id), name: String(pk.user.name), displayName: pk.user.displayName ? String(pk.user.displayName) : '' },
        algorithms: Array.prototype.map.call(pk.pubKeyCredParams || [], function (p) { return p.alg; }),
        excludeCredentials: descriptors(pk.excludeCredentials),
        authenticatorAttachment: selection.authenticatorAttachment || null,
        residentKey: selection.residentKey || (selection.requireResidentKey ? 'required' : 'discouraged'),
        userVerification: selection.userVerification || 'preferred',
        attestation: pk.attestation || 'none',
        prf: prfInput(pk.extensions)
      };
    } catch (e) { return Promise.reject(e); }
    return send(request, options.signal, pk.extensions);
  });

  // A password manager that keeps passkeys, 1Password, Bitwarden, puts
  // its own get and create on navigator.credentials, or asks from its own
  // script, and offers its passkeys under the name field to the sites that
  // ask for them that way. Once one is there, pages hear the field can.
  var claimed = false;
  function extensionAnswers() {
    if (claimed) return true;
    try {
      if (navigator.credentials && Object.getOwnPropertyDescriptor(navigator.credentials, 'get')) claimed = true;
      else if ((new Error().stack || '').indexOf('-extension://') >= 0) claimed = true;
    } catch (e) {}
    return claimed;
  }

  // What this browser can and can't do, for the pages that ask first:
  // passkeys from the Mac, a phone or a key, not yet under the field,
  // and none of what WebKit would have answered for itself.
  var P = PublicKeyCredential;
  replace(P, 'isUserVerifyingPlatformAuthenticatorAvailable', function () { return Promise.resolve(true); });
  replace(P, 'isConditionalMediationAvailable', function () { return Promise.resolve(extensionAnswers()); });
  replace(P, 'getClientCapabilities', function () {
    var field = extensionAnswers();
    // Only the relay's capabilities: neither engine's native authenticator
    // handles these requests. Inheriting its answers advertised Chromium's
    // immediate mediation, which would instead open the Mac's normal sheet.
    // Unlisted extensions are unsupported. Older WebKit has no native
    // capability method at all; it must give the same answer here too.
    return Promise.resolve({
      conditionalCreate: false, conditionalGet: field, conditionalMediation: field, immediateGet: false, relatedOrigins: true,
      signalAllAcceptedCredentials: false, signalCurrentUserDetails: false, signalUnknownCredential: false,
      hybridTransport: true, passkeyPlatformAuthenticator: true, userVerifyingPlatformAuthenticator: true,
      'extension:credProps': true, 'extension:prf': true
    });
  });
})();
