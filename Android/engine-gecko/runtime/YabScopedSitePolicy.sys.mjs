/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this file,
 * You can obtain one at http://mozilla.org/MPL/2.0/. */

// Separate bits deliberately prevent a partial cleaner being advertised as
// WKWebsiteDataStore.allWebsiteDataTypes(). No caller may silently drop a bit.
export const SiteDataType = Object.freeze({
  COOKIES: 1,
  QUOTA: 2, // LSNG, IndexedDB, CacheStorage, service workers, file-system quota.
  NETWORK_CACHE: 4,
  SESSION_STORAGE: 8,
  RESOURCE_CACHE: 16,
  MEDIA_KEYS: 32,
  DEVICE_SALT: 64,
  RECENT_SEARCHES: 128,
  ALL: 255,
});

export const SUPPORTED_SITE_TYPES =
  SiteDataType.COOKIES | SiteDataType.QUOTA | SiteDataType.NETWORK_CACHE;

export function supportsSiteTypes(types) {
  return Number.isSafeInteger(types) && types > 0 && types <= SiteDataType.ALL &&
    (types & ~SUPPORTED_SITE_TYPES) === 0;
}

/** Literal canonical host, never a URI, eTLD expansion, pattern, or default jar. */
export function siteScope(request) {
  if (!request || typeof request !== "object" || Array.isArray(request)) {
    throw new Error("INVALID_SCOPE");
  }
  const { host, contextId, privateMode, types } = request;
  if (typeof host !== "string" || host.length > 253 ||
      !host.split(".").every(label => /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(label))) {
    // Unicode and IPv6 require an explicit future canonical-host contract;
    // fail before mutation rather than guessing an origin from an input URL.
    throw new Error("INVALID_HOST");
  }
  if (typeof contextId !== "string" || contextId.length > 4096 ||
      !/^gvctx[0-9a-f]+$/.test(contextId) || typeof privateMode !== "boolean") {
    throw new Error("INVALID_CONTEXT");
  }
  if (!supportsSiteTypes(types)) {
    throw new Error("UNSUPPORTED_DATA_TYPES");
  }
  return Object.freeze({ host, contextId, privateMode, types });
}

export function sameSiteOwner(scope, host, attributes) {
  return host === scope.host && attributes != null &&
    attributes.geckoViewSessionContextId === scope.contextId &&
    attributes.privateBrowsingId === (scope.privateMode ? 1 : 0) &&
    attributes.userContextId === 0;
}
