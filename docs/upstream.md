# Upstream: driceroland/Search

Yab forked from Search at b04b752 (23 September 2026), before its 1.0.1.
It was compared, item by item against the code rather than the changelog,
with Search up to 491f321 (1.0.1, 1.0.2, 1.0.3 and Unreleased) on
24 September 2026. The next sync starts from 491f321. Upstream's name is
kept out of commit messages.

## Ported (55c6956, 5066f1b, b998dd7, 941a401)

- **Holes.** macOS 14 launch (`NSApp.appearance` before the app exists);
  private tabs kept out of Recently Closed, and a tab opened from a private
  one private in the same store; each opened tab with its own
  `userContentController`, so an opener's scripts survive its child
  sleeping; `Content-Disposition: attachment` downloads, and a 3xx with a
  binary type follows its redirect; `Vault.registrable` on the system's
  public suffix list; a picked account fills only the host it was offered
  for; a copied password is transient and current-host only; updates
  require the checksum and a Developer ID signature with nested code,
  `YAB_FEED` in test runs only; an extension's Reload asks when a new
  version wants more; ⌘← and ⌘→ in a text box move the caret; ⌘1 to ⌘9 by
  key code, so AZERTY works; video full screen no longer black; a popup
  window named by its site.
- **Web Inspector**: Inspect Element, ⌥⌘I, ⌥⌘J, ⌥⌘C, and it stays docked
  through a resize. A middle click closes a tab.
- **Small features**: extensions in private tabs (off by default), ⇧⌘V
  pastes plain text in a text box, Search with… in the text menu, a column
  that scrolls when it overflows, and ⌘ keys go to the page first (see
  [shortcuts.md](shortcuts.md)). Faster launch: extensions load after the
  window shows, the bookmarks menu fills when opened.
- **Passkeys** through ASAuthorization by Yab itself (5066f1b): WebKit's
  path fails outside the app's associated domains and can wedge
  AuthenticationServicesAgent until a restart. The patch goes first among
  extensions' MAIN-world scripts, so password managers keep their order.
- **Peek** on ⇧-click (b998dd7), on by default; ⌥⌘-click into the small
  window was removed.
- **Spaces** (941a401), off by default: their own pins and tabs, shared
  sign-ins or their own cookies chosen at creation. Agent tabs are never
  parked; an agent picks the space to sign in from (`spaces`, `open` with
  `space`).

## Declined, 24 September 2026

- 120 Hz for pages: a private flag, about 1.5x the energy, Safari keeps 60.
- Middle-button scrolling, as on Windows.
- ⌘T reusing an empty tab (⌘T is always a new tab here).
- A site card on clicking the tab (certificate, zoom, print).
- Share… in the File menu; Copy as Markdown Link (⌘A is for agents);
  Reopen Closed Tab in the tab's menu.
- A link's address at the bottom of the window on hover.
- A switch for the reading progress bar.
- ⌘S collapsing the tab strip on top.
- A switch for installing updates only from the button.
- A shorter two-finger back swipe and flick.
- Mouse wheel handling for pages with their own wheel listener.
- Tab through the page's links rather than the tabs.
- A tab's rename saved on a click elsewhere (a click elsewhere cancels).
- A fresh install following the Mac's theme (light by default).
- A floating video without a shadow; no white flash of a new tab in dark.
- The bench acting only in its own tabs, and consent to it in the keychain
  (the bench is off until turned on, and the socket is the user's only).
- An arrow cursor over panels on a page that hid the cursor.
- Their interface tweaks we don't share (back and forward padding, the
  Settings sidebar, the new space card, a bookmarks button with a list).
