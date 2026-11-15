# Extensions per sign-in

Extensions follow sign-ins, as Arc's and Dia's follow the Chrome profile
(request #414). A space with sign-ins of its own has its own extensions;
spaces that share the first space's sign-ins share its extensions.

## What each sign-in has

Each sign-in is an `Extensions` of its own (`ExtensionSignIns.swift`):

- its list: `Extensions/installed.json` for the shared sign-in, as always,
  and `Extensions/Sign-Ins/<space id>.json` for a space's own;
- a `WKWebExtensionController` whose storage (storage.local, sync, session,
  declarativeNetRequest) is WebKit's folder for the space's id, beside the
  shared one's `Default`;
- the sign-in's website data store for its extensions' pages and workers,
  so their requests carry that sign-in's cookies and their IndexedDB is
  that sign-in's;
- only that sign-in's tabs told to WebKit (`Extensions.seen`): a page
  carries the controller of the store it is made in (`Extensions.attach`).

One copy of each extension's files serves every sign-in
(`Extensions/<id>`). Installed in two sign-ins, removed from one, the
other keeps it; updated once, every sign-in runs the new version.

A space's own sign-in's extensions start the first time a page of it is
made or its list is opened, after the shared ones' launch, one sign-in at
a time. Its pages wait for those of its extensions that act on pages
(content scripts, ad blockers; `Extensions.holdSignInPages`), five seconds
at most, and its tabs are told to WebKit only once those are in: a tab
WebKit was told of before an extension loaded stays unknown to it, and
every message from that extension's scripts in the page says "Tab not
found", reloaded or not (#356: a wallet's provider on the page that never
answered). A sign-in with pages waiting loads between two extensions of
the one loading then, rather than after all of them (`Extensions.promote`).
The shared sign-in's tabs wait the same way at launch (`holdingTabs`),
though its pages wait only for ad blockers.
A space's own store has its extensions' worker registrations swept as it
is made (`Extensions.storeMade`), not at its extensions' launch: by then
the space's restored pages had the store in use, and the worker WebKit
took up never ran.

## Wallets starting

Rabby and MetaMask load their background from an event, the worker's
install or the first message, and say "ready" to every tab once it is up;
a content script that connected earlier reconnects then. Yab registers
each worker afresh at a launch (`Extensions.forgetOrigins`), so WebKit
says install to it every time, and the first pages' ports reached a
background still starting, which refused their first questions for good.
While a worker starts its code from an event (until its "ready" to the
tabs, ten seconds at most), the shim turns content scripts' ports away
with a word, and their content scripts reconnect a quarter of a second
later with what they had sent (`turnAway` and `closable` in
`extension-shims.js`). `evals/extensions/rabby_wallet_trace.py`
marks Rabby's handshake on both ends.

## Bringing a browser in

Each profile's extensions go to the sign-in of the space that profile came
in as (`signedInAs`, "Arc:Profile 1"), as Arc and Chrome keep them per
profile (#358, `Extensions.bringIn(byProfile:)`); the first profile's, and
one with no space here, to the shared sign-in. One sign-in after another,
since two installing the same extension at once would share its folder.

## Where each is used

- Pages, popups, popouts, side panels, native messaging: the sign-in of
  the page, or of the extension's context.
- The buttons beside the address, Site Controls, ⌘E, extension keys,
  omnibox keywords, ⌘T's extension commands: the sign-in of the space on
  screen (`ExtensionsHere`).
- The store's Add button: the sign-in of the store's tab.
- Settings › Extensions: the window's space's sign-in, with a Sign-ins
  menu over the list once any space has its own.
- A page an extension opens goes to a window showing its sign-in, or the
  window in front is taken to a space of it.
- Web pages' messages (externally_connectable), the debugger and the
  omnibox are kept by sign-in and extension (`ExtensionExternal.key`).

The shared sign-in's alone: Yab's ad blocker choice (Blockers, the rules
bridge), an extension's proxy, tab groups (the shared row's folders), Sync
of extensions between Macs, and Move from Tampermonkey.

## The split

The first launch with extensions per sign-in gives each space that then
has sign-ins of its own a copy of the shared list and of each extension's
WebKit storage (`Extensions.splitOnce`, once, `extensions.signIns.split`),
so nothing that ran there stops. What an extension's own pages kept in the
shared website data store (IndexedDB, a password manager's session) can't
be copied: there it starts signed out, as in a new Chrome profile.

A space given sign-ins of its own later starts with none. Given shared
sign-ins again, or deleted, its list, storage and the folders of
extensions nobody else has are erased with its sign-ins.

## Checking it

- `Tests/FastTests/ExtensionSignInsTests.swift`: the split, keys.
- `evals/extensions/sign_ins.py`: two spaces with different sign-ins in a
  test world, a content script and storage count per sign-in, the split
  after a relaunch.
- `evals/extensions/wallet_sign_ins.py` (`wallet_sign_ins.sh main` for
  before/after): a wallet-shaped fixture and Rabby on a dapp page per
  sign-in, the first page after a relaunch, and a made-up Arc with two
  profiles brought in.
- `./bench ext-sign-ins`: every sign-in's list, what is loaded and the
  tabs told to it.
