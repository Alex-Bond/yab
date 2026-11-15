---
name: dashlane
description: Sign in with Dashlane's own menu on the page when the user connected Dashlane to Yab, and get past it when it is locked.
sites: []
keywords: [dashlane, дашлейн]
---

# Dashlane

## Signing in

Call `sign_in(tab)` first: Yab fills its own saved login when it has one. Without one, Yab clicks
the sign-in field and looks for Dashlane's menu, and answers in one line:

- **menu**: Dashlane's menu is open under the field. Take a snapshot and pick the account for this
  task in it (its rows show the account and the site). If the account is ambiguous, ask the user. Then submit the form as usual.
- **locked**: Dashlane asks to unlock before it shows logins. The user unlocks Dashlane in Yab: call `handoff`
  to ask them, then call `sign_in` again.
- **none**: Dashlane has no menu here. Call `handoff` so the user signs in.

Never search Dashlane's vault, open its pages yourself, ask for its master password, or use another
manager's login. Verify from a fresh snapshot that the site signed in.
