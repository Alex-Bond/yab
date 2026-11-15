---
name: bitwarden
description: Sign in with Bitwarden's own menu on the page when the user connected Bitwarden to Yab, and get past it when it is locked.
sites: []
keywords: [bitwarden, битварден]
---

# Bitwarden

## Signing in

Call `sign_in(tab)` first: Yab fills its own saved login when it has one. Without one, Yab clicks
the sign-in field and looks for Bitwarden's menu, and answers in one line:

- **menu**: Bitwarden's menu is open under the field. Take a snapshot and pick the account for this
  task in it (its rows show the account and the site). If the account is ambiguous, ask the user. Then submit the form as usual.
- **locked**: Bitwarden asks to unlock before it shows logins. When sign_in says Yab has its unlock password, call
  `unlock_manager("bitwarden")`; when it says the user unlocks it, call `handoff` to ask them.
- **none**: Bitwarden has no menu here. Call `handoff` so the user signs in. Bitwarden shows its
  menu on fields only with Settings › Autofill › "Show autofill suggestions on form fields" set
  to on field focus (with "on icon click", click its icon in the field first);
  say so in the handoff when the user connected Bitwarden but no menu ever shows.

## Unlocking

`unlock_manager("bitwarden")` types the unlock password the user saved in Settings › Passwords into
Bitwarden's own unlock page in a background tab. You never see it. It answers **unlocked** (call
`sign_in` again and pick from the menu) or **not unlocked** (don't try again: call `handoff`).

If its menu closes before you can pick (a tab out of sight), call `handoff` so the user picks the
login in it.

Never search Bitwarden's vault, open its pages yourself, ask for its master password, or use another
manager's login. Verify from a fresh snapshot that the site signed in.
