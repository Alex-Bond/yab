---
name: 1password
description: Sign in with 1Password's own menu on the page when the user connected 1Password to Yab, and get past it when it is locked.
sites: []
keywords: [1password, one password, 1пароль]
---

# 1Password

## Signing in

Call `sign_in(tab)` first: Yab fills its own saved login when it has one. Without one, Yab clicks
the sign-in field and looks for 1Password's menu, and answers in one line:

- **menu**: 1Password's menu is open under the field. Take a snapshot and pick the account for this
  task in it (a frame from 1Password over the page). If the account is ambiguous, ask the user. Then submit the form as usual.
- **locked**: 1Password's menu says it is available but shows no logins. When sign_in says Yab has its unlock password, call
  `unlock_manager("1password")`; when it says the user unlocks it, call `handoff` to ask them.
- **none**: 1Password has no menu here. Call `handoff` so the user signs in.

## Unlocking

`unlock_manager("1password")` types the unlock password the user saved in Settings › Passwords into
1Password's own unlock page in a background tab. You never see it. It answers **unlocked** (call
`sign_in` again and pick from the menu) or **not unlocked** (don't try again: call `handoff`).
After an unlock Yab reloads the sign-in page: 1Password's menu comes back only on a page loaded since.
If 1Password says its app hasn't allowed Yab, call `handoff`: the user adds Yab in 1Password › Settings › Browser.

Never search 1Password's vault, open its pages yourself, ask for its master password, or use another
manager's login. Verify from a fresh snapshot that the site signed in.
