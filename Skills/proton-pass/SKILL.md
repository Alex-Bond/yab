---
name: proton-pass
description: Sign in with Proton Pass's own menu on the page when the user connected Proton Pass to Yab, and get past it when it is locked.
sites: []
keywords: [proton pass, protonpass, протон пасс]
---

# Proton Pass

## Signing in

Call `sign_in(tab)` first: Yab fills its own saved login when it has one. Without one, Yab clicks
the sign-in field and looks for Proton Pass's menu, and answers in one line:

- **menu**: Proton Pass's menu is open under the field. Take a snapshot and pick the account for this
  task in it (its rows show the account and the site). If the account is ambiguous, ask the user. Then submit the form as usual.
- **locked**: Proton Pass asks to unlock before it shows logins. The user unlocks Proton Pass in Yab: call `handoff`
  to ask them, then call `sign_in` again.
- **none**: Proton Pass has no menu here. Call `handoff` so the user signs in.

Never search Proton Pass's vault, open its pages yourself, ask for its master password, or use another
manager's login. Verify from a fresh snapshot that the site signed in.
