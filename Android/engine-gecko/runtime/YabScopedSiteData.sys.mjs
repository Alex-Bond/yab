/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this file,
 * You can obtain one at http://mozilla.org/MPL/2.0/. */

import { SiteDataType, siteScope, sameSiteOwner } from "resource://gre/modules/YabScopedSitePolicy.sys.mjs";

const lazy = {};
ChromeUtils.defineESModuleGetters(lazy, {
  ServiceWorkerCleanUp: "resource://gre/modules/ServiceWorkerCleanUp.sys.mjs",
});

const MAX_ITEMS = 100000;
const DEADLINE_MS = 30000;

function bounded(operation) {
  return new Promise((resolve, reject) => {
    let finished = false;
    const timer = Cc["@mozilla.org/timer;1"].createInstance(Ci.nsITimer);
    const finish = (error, value) => {
      if (finished) { return; }
      finished = true;
      timer.cancel();
      if (error) { reject(new Error("SCOPED_CLEAR_FAILED")); }
      else { resolve(value); }
    };
    timer.initWithCallback(() => finish(true), DEADLINE_MS, Ci.nsITimer.TYPE_ONE_SHOT);
    try { operation(finish, () => finished); } catch (_) { finish(true); }
  });
}

async function quotaPrincipals(scope) {
  const origins = await bounded(finish => {
    const request = Services.qms.listOrigins();
    request.callback = result => {
      if (!Components.isSuccessCode(result.resultCode)) { finish(true); return; }
      finish(false, result.result);
    };
  });
  if (origins.length > MAX_ITEMS) { throw new Error("TOO_MANY_ORIGINS"); }
  const principals = [];
  for (const origin of origins) {
    const principal = Services.scriptSecurityManager.createContentPrincipalFromOrigin(origin);
    // No privileged/null/extension principal enters the HTTP(S) host scope.
    if ((principal.schemeIs("http") || principal.schemeIs("https")) &&
        sameSiteOwner(scope, principal.URI.asciiHost, principal.originAttributes)) {
      principals.push(principal);
    }
  }
  return principals;
}

async function cacheEntries(scope) {
  return bounded((finish, finished) => {
    let seen = 0;
    const entries = [];
    const visitor = {
      QueryInterface: ChromeUtils.generateQI(["nsICacheStorageVisitor"]),
      onCacheStorageInfo() {},
      onCacheEntryInfo(uri, id, _size, _alt, _fetches, _modified, _expires, pinned, info) {
        if (finished()) { return; }
        try {
          if (++seen > MAX_ITEMS) { finish(true); return; }
          if (!(uri.schemeIs("http") || uri.schemeIs("https")) || uri.asciiHost !== scope.host) { return; }
          if (!info || !info.originAttributes) { finish(true); return; }
          if (sameSiteOwner(scope, uri.asciiHost, info.originAttributes)) {
            // Keep the actual native storage descriptor, including its anonymity
            // and partition attributes. Never reconstruct a default cookie jar.
            entries.push({ uri, id, pinned, info });
          }
        } catch (_) { finish(true); }
      },
      onCacheEntryVisitCompleted() { finish(false, entries); },
    };
    Services.cache2.asyncVisitAllStorages(visitor, true);
  });
}

function doom(entry) {
  return bounded(finish => {
    const storage = entry.pinned
      ? Services.cache2.pinningCacheStorage(entry.info)
      : Services.cache2.diskCacheStorage(entry.info);
    storage.asyncDoomURI(entry.uri, entry.id, {
      QueryInterface: ChromeUtils.generateQI(["nsICacheEntryDoomCallback"]),
      onCacheEntryDoomed(status) { finish(!Components.isSuccessCode(status)); },
    });
  });
}

/**
 * Qualification API for explicitly requested supported types, not a full-site UI.
 * ALL is intentionally refused before enumeration or mutation until every
 * mandatory iOS data class has an implemented, scoped, acknowledged cleaner.
 */
export async function clearScopedSiteData(request) {
  const scope = siteScope(request);
  const deadline = Date.now() + DEADLINE_MS;
  const current = () => {
    if (Date.now() >= deadline) { throw new Error("SCOPED_CLEAR_DEADLINE"); }
  };
  // The legacy observer takes only a host and would cross contexts. Never send
  // it, and refuse legacy LocalStorage before clearing any selected data.
  if ((scope.types & SiteDataType.QUOTA) &&
      Services.prefs.getBoolPref("dom.storage.enable_unsupported_legacy_implementation", false)) {
    throw new Error("UNSUPPORTED_LEGACY_STORAGE");
  }
  const principals = scope.types & SiteDataType.QUOTA ? await quotaPrincipals(scope) : [];
  const cached = scope.types & SiteDataType.NETWORK_CACHE ? await cacheEntries(scope) : [];
  const cookies = scope.types & SiteDataType.COOKIES ? Array.from(Services.cookies.cookies) : [];
  if (cookies.length > MAX_ITEMS) { throw new Error("TOO_MANY_COOKIES"); }

  for (const principal of principals) {
    current();
    await bounded(finish => {
      lazy.ServiceWorkerCleanUp.removeFromPrincipal(principal).then(
        () => finish(false), () => finish(true)
      );
    });
    await bounded(finish => {
      current();
      const request = Services.qms.clearStoragesForPrincipal(principal);
      request.callback = result => finish(!Components.isSuccessCode(result.resultCode));
    });
  }
  for (const entry of cached) { current(); await doom(entry); }
  for (const cookie of cookies) {
    current();
    if (sameSiteOwner(scope, cookie.rawHost, cookie.originAttributes)) {
      // Fully captured attributes include the exact private bit and partition.
      // Do not call CookieCleaner: its compression-dictionary cleanup has no OA.
      Services.cookies.removeCookiesFromExactHost(cookie.rawHost, JSON.stringify(cookie.originAttributes));
    }
  }
  current();
  return Object.freeze({ version: 1, clearedTypes: scope.types });
}
