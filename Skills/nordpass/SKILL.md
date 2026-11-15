---
name: nordpass
description: Sign in with NordPass's own menu on the page when the user connected NordPass to Yab, and get past it when it is locked.
sites: []
keywords: [nordpass, нордпасс]
---

# NordPass

## Signing in

Call `sign_in(tab)` first: Yab fills its own saved login when it has one. Without one, Yab clicks
the sign-in field and looks for NordPass's menu, and answers in one line:

- **menu**: NordPass's menu is open under the field. Take a snapshot and pick the account for this
  task in it (its rows show the account and the site). If the account is ambiguous, ask the user. Then submit the form as usual.
- **locked**: NordPass asks you to log in or unlock before it shows logins. When sign_in says Yab has its unlock password, call
  `unlock_manager("nordpass")`; when it says the user unlocks it, call `handoff` to ask them.
- **none**: NordPass has no menu here. Call `handoff` so the user signs in.

## Unlocking

`unlock_manager("nordpass")` types the unlock password the user saved in Settings › Passwords into
NordPass's own unlock page in a background tab. You never see it. It answers **unlocked** (call
`sign_in` again and pick from the menu) or **not unlocked** (don't try again: call `handoff`).

Never search NordPass's vault, open its pages yourself, ask for its master password, or use another
manager's login. Verify from a fresh snapshot that the site signed in.
