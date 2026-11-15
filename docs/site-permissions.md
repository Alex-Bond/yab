# Site permissions

What a page may ask for, who answers, and where the answer lives, on both
engines. Notifications have their own page (`docs/site-notifications.md`). The
check is `evals/site-permissions/`: one fixture row per permission kind, one
generated set of cases, run in Chromium, in WebKit and in real Chrome so each
difference is seen.

## Yab decides

Yab owns the decision on both engines: its card asks, `Store.settings` remembers,
Site Controls and Settings change it. Nothing Chromium would show of its own is
ever seen, since a Yab tab's Chrome window is hidden, so a kind Chromium can ask
has to reach Yab or it hangs.

- **Asking.** Everything that reaches Chromium's permission manager comes through
  CEF's `OnShowPermissionPrompt` and `AskPermission` (`YabCore/src/questions.inc`).
  Camera, microphone, location and notifications keep the kinds they always had.
  The rest is `question.open` with kind `permission` and Chromium's names
  (`permissions.inc`), answered by `SitePermission` in `SitePermissions.swift` on
  the same card (`PageAsk.Kind.site`), or by `LocalNetwork` for its two questions.
  A remembered kind is kept for the site whichever way it is answered, with no box,
  as a notification is.
- **Unsupported masks.** Accept answers the whole native permission mask. Yab
  asks only when every bit has a route; a partially mapped request is refused
  rather than accepting an unnamed permission along with a named one. Each
  unsupported mask is logged once per helper process.
- **Remembering in Chromium.** `ChromiumPermissions` is the only writer of what
  Chromium holds. `wanted()` reads every remembered answer, `permission.set` writes
  the difference from what that profile was last told, before the profile's first
  page and within a frame or two of any change, wherever the change came from. So
  `navigator.permissions.query` and `Notification.permission` tell the truth, its
  `change` event fires in a live page, and a site allowed under WebKit is allowed in
  every space's profile the first time it opens here.
- **Old native blocks.** Before the profile's services start, font and network
  exception tables are cleared, including the legacy combined network table.
  Yab then restores its remembered answers before opening pages. This removes
  blocks an older helper left by denying an unknown mask without ever asking
  Yab, while retaining decisions recorded by Yab, including font refusals.
- **An answer not kept.** A Yes with Remember unticked, or a card that went away,
  answers only the request that asked. CEF's Accept and Deny write to Chromium's
  settings regardless, so `keep: false` forgets that write 400 ms later.
- **Private windows.** `permission.set` writes nothing into a private profile, and
  a card there neither reads nor leaves a remembered answer.
- **Origins.** Camera, microphone, location and notifications are kept per origin,
  scheme, host and port. A bare-host location key from before reads as https's and
  moves there, as the camera's did.
- **Another site's frame.** A device request from a cross-origin frame reaches
  the card whatever the page's `allow=` says, where Chrome refuses one without it.

## Kind by kind on Chromium

| Kind | What happens |
|---|---|
| Notifications, camera, microphone, location | Yab's card, as on WebKit |
| Pan-tilt-zoom | With the camera's card and answer |
| Clipboard read, local fonts, window management, idle detection, MIDI | Yab's card, kept for the site, a row in Site Controls |
| Local network, loopback network | Chromium's check, `LocalNetwork`'s card and memory |
| Protocol handlers, file access, storage quota | Yab's card each time: what's granted lives with the handler or the file |
| Storage access | Chromium's rule; with third-party cookies allowed it grants without asking, as in Chromium |
| Automatic downloads | Yab's download question. YabCore lets Chromium's own prompt through on a tab Yab shows and forgets that Allow, and dismisses it on a tab nobody can be asked for (a Deny there was kept as a block for good); each profile opens with none of Chromium's own, and Yab's answer is written for the origins it was given on |
| Pop-ups | Chromium's blocker; a window it stops is told to the plate (`WindowRelay`), and a site allowed there is allowed in Chromium |
| WebAuthn | Yab's own ceremony (`Passkeys`), the Mac's sheet, as on WebKit |
| File System Access | Not finished: a save picker is refused, and Chrome's own permission dialogs would be unseen |
| WebUSB, WebHID, Web Serial, Web Bluetooth, FedCM | Off, as on WebKit |
| AR, VR, hand tracking | Refused: nothing on a Mac to serve them |
| Web install, ambient login | Refused until Chromium ships them on by default |

The ones turned off ask through a chooser or an account sheet of Chrome's own,
which belongs to a window nobody sees, so a page would wait for ever. Without
them a page finds the feature missing, says so or falls back; Google's sign-in
should fall back to its popup, as in a browser without FedCM. A device chooser in Yab is new UI and hasn't been
designed; until then these stay off.

## Not imported

No site permission comes over from a Chrome or Arc import: a site asks again.

## Testing

`evals/site-permissions/job.sh APP [suites] [browsers] [answers]` runs `kinds.js`,
one row per kind, through `run.py`'s suites: `sweep` (every kind, allow and deny),
`where` (top, same-site frame, cross-site frame with and without `allow=`,
sandboxed), `timing` (no gesture, hidden tab, close, navigate, reload, a queue),
`memory`, `live` (a row removed in a live page, a stream in use), `focus` (what
needs Yab in front: pointer lock, file panels, with `--exclusive --needs
foreground`). `table.py` prints one line per kind. `YAB_MAC_SAYS_YES=1` in a test
world takes macOS to have said yes; a farm Mac has nobody to answer macOS's window.
`real-job.sh` reads what Slack and X hold in a copy of a real, long-used profile, once
each; Google, WhatsApp and Telegram are never opened in a copy.

`evals/golden/chromium_local_permissions.py --app APP --out DIR` is the focused
Chromium check for fonts, loopback and local network requests from HTTPS, their
remembered answers, restart and Site Controls revocation. It temporarily installs
the repository's Caveat font and removes its own file on exit. Chromium's test
address-space overrides classify the HTTPS fixture as public and its network
endpoint as local, including on workers whose interface has a public address.
The navigation cases cover the field, HTTPS links and external URL opening,
using an isolated HTTP proxy for synthetic localhost and Tailscale endpoints;
they do not prove a real tailnet route. Network Allow survives restart; Deny
lasts until Yab quits, as WebKit's `LocalNetwork` decision does. Font decisions
are kept both ways.

An address typed without a scheme uses HTTP for localhost, bare server names
with ports, private IPs, Tailscale's `*.ts.net` names and shared `100.64.0.0/10`
addresses (`Address.isLocal`). An explicitly written scheme stays as written.
