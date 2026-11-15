# Chromium test matrix

What has to hold before Yab on Chromium is called ready. Each row needs a
repeatable check or a stated reason why none can exist. A row passes only on a
signed build, with the real scenario, not a stand-in. WebKit is the reference for
what Yab already promises; Chrome is the reference for what a page may expect.

Risks marked **read from code** come from reading the source, not from a run.

## Site permissions

**Read from code, check first:**

- `ChromiumPage+Questions` answers only `capture`, `location`, `notifications`,
  `certificate` and `auth`; every other kind ends in `allow: false`. Any permission
  a page asks for beyond those may be a silent deny, where Chrome asks.
- `permissions.inc` forgets each camera, microphone and location decision in
  Chromium 400 ms after applying it, so `navigator.permissions.query` may read
  `prompt` on a site Yab remembers as allowed. Google Meet and others branch on it.
- Notifications are copied into Chromium's profile: check every profile and space,
  and a site allowed under WebKit before it ever opens in Chromium.

**Every kind:** notifications, camera, microphone, pan-tilt-zoom, location, clipboard
read, clipboard write, storage access (`requestStorageAccess`, top-level too),
persistent storage, local fonts, window management, idle detection, screen wake lock,
File System Access (read, write, directory), MIDI and sysex, USB, HID, Serial,
Bluetooth, sensors, payment handler, protocol handlers, pop-ups, automatic downloads,
autoplay, local network access, pointer lock, keyboard lock, fullscreen, captured
surface control, WebAuthn, speech recognition, third-party cookies.

**For each kind:**

| Dimension | Cases |
|---|---|
| Answer | allow, deny, dismiss, ignore, allow once where it exists |
| Memory | holds after reload, new tab, restart, app update; per origin, not per host; port and scheme apart |
| `permissions.query` | state agrees with the truth before, after, on change; `onchange` fires |
| Where asked | top frame, same-site frame, cross-site frame with and without `allow=`, pop-up, worker, sandboxed frame, `file:`, `localhost`, plain `http` |
| Timing | no gesture, with gesture, in a hidden tab, tab closes or navigates while asked, two at once, a queue of three, reload during |
| Change later | Site Controls and Settings revoke at once in a live page; a stream in use stops; removing a row asks again |
| OS layer | macOS allowed, denied, not determined: the ask names Yab, the message is true, no helper name, no blank icon |
| Worlds | spaces with their own stores, private windows (nothing kept), profiles |
| Engines | a decision made under WebKit holds under Chromium and back; Auto moving a tab asks nothing again |
| Import | what a Chrome or Arc import brings |
| Agents | Yab's agents and read browsers never get or trigger a prompt |
| UI | Yab's card only, never Chrome's bubble in a hidden window; anchored to its tab, over the page, keyboard works; denied state visible in Site Controls |

## Site notifications

**Read from code, check first:** web push on WebKit is Yab's own client (`WebPush`,
`push-page.js`, `_processPushMessage:`). Nothing shown yet carries that to Chromium,
which has no working Google push service here, and `NativeNotifications` is off. So
closed-tab push, and even how a page's notification reaches macOS, are open questions.

| Area | Cases |
|---|---|
| Show | `new Notification`, `registration.showNotification`, from a hidden tab, a sleeping tab, a discarded tab, a closed tab through a worker |
| Fields | title, body, icon, image, badge, tag replaces, renotify, silent, requireInteraction, actions, data, timestamp, vibrate ignored |
| Click | opens or focuses the right tab in the right window and space; `notificationclick`, `notificationclose`, actions; app was closed |
| Push | subscribe, unsubscribe, `getSubscription`, encrypted payload, tab closed, Yab running, Yab asleep and back, offline and back, endpoint expiry; which service carries it |
| Engines | a WebKit subscription after Auto moves the site to Chromium and back; no silent loss, no double delivery; site stays subscribed |
| Yab's rules | Allow and Deny in Websites, removing, clearing data drops the subscription here and on the box, never in private windows, per space |
| macOS | banner shows Yab's name and icon, sender grouping, Focus and Do Not Disturb, Notification Center history, sound, app permission off, permission never asked on launch |
| Badges | `navigator.setAppBadge`, Dock, Yab's own Mail badge unaffected |
| Real sites | where the profile already allows them: Gmail, Calendar, Slack, X, WhatsApp, Telegram read their state as allowed and their settings pages agree; no site is newly allowed in a real account |

## Yab on Chromium tabs

Overlays and z-order over the helper's layer: ⌘T field, ⌘J, sidebar peek, menus,
toasts, cards, corner masks, Liquid Glass sampling, drag of tabs across windows.
Split view with two Chromium pages and one of each engine, mini player, live resize,
sidebar and window animation, moving a window between displays of different scale,
full screen, tinted theme color, favicons, titles, audio marks. History, diary, sync
to the iPhone, bookmarks, session restore, pins, folders, spaces, tab sleep, wake.
Shields and content blocking parity, HTTPS-only, Boosts, page scripts, autofill and
password capture, Wallet forms, reader, translate, find, zoom per site, fonts, dark
pages, Do It and Ask reading a page, agents and the `yab` CLI and MCP on Chromium tabs,
DevTools, view source.

## The web platform

Pop-ups and OAuth: Google, Apple, GitHub, Microsoft sign-in windows, `window.opener`,
popup to the other engine. Dialogs: alert, confirm, prompt, beforeunload, HTTP
authentication, client certificates. TLS interstitials, HSTS, mixed content, captive
portals, proxy and VPN, IPv6, QUIC. WebGL, WebGPU, WASM threads, cross-origin
isolation, service workers offline, PWA install, Web Speech, WebCodecs, HEVC,
AV1, MSE, EME routing to WebKit, fonts, RTL, high contrast, reduced motion.

## Privacy, disk and lifetime

Everything Chromium itself calls on the network with a fresh profile, idle, for an
hour: nothing unexplained leaves. Clear Browsing Data
covers both engines. Private windows leave nothing on disk. Chromium cache and profile
size under use, limits, and what happens with a full disk. Moving back to 0.45.1 after
using the new build: no lost tabs, no lost data. macOS 15 and 26 behavior, 8 GB Macs,
Intel stays WebKit with nothing shown. Update size, delta updates, app size.
