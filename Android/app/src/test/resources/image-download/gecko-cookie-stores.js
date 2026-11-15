/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this file,
 * You can obtain one at http://mozilla.org/MPL/2.0/. */

// Unmodified declarations from the pinned GeckoView 158 omni.ja ext-toolkit.js,
// lines 30-56 and 70-72. Source SHA-256:
// a25f9994cf227551b7c4635e0fccb37a2c58bf8b01b34e3b97ede4990f7de9f7
global.DEFAULT_STORE = "firefox-default";
global.PRIVATE_STORE = "firefox-private";
global.CONTAINER_STORE = "firefox-container-";

global.getCookieStoreIdForTab = function (data, tab) {
  if (data.incognito) {
    return PRIVATE_STORE;
  }

  if (tab.userContextId) {
    return getCookieStoreIdForContainer(tab.userContextId);
  }

  return DEFAULT_STORE;
};

global.getCookieStoreIdForOriginAttributes = function (originAttributes) {
  if (originAttributes.privateBrowsingId) {
    return PRIVATE_STORE;
  }

  if (originAttributes.userContextId) {
    return getCookieStoreIdForContainer(originAttributes.userContextId);
  }

  return DEFAULT_STORE;
};

global.getCookieStoreIdForContainer = function (containerId) {
  return CONTAINER_STORE + containerId;
};
