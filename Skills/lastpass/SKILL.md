---
name: lastpass
description: Sign in with LastPass's own menu on the page when the user connected LastPass to Yab, and get past it when it is locked.
sites: []
keywords: [lastpass, ластпасс]
---

# LastPass

## Signing in

Call `sign_in(tab)` first: Yab fills its own saved login when it has one. Without one, Yab clicks
the sign-in field and looks for LastPass's menu, and answers in one line:

- **menu**: LastPass's menu is open under the field. Take a snapshot and pick the account for this
  task in it (its rows show the account and the site). If the account is ambiguous, ask the user. Then submit the form as usual.
- **locked**: LastPass asks to unlock before it shows logins. The user unlocks LastPass in Yab: call `handoff`
  to ask them, then call `sign_in` again.
- **none**: LastPass has no menu here. Call `handoff` so the user signs in.

Never search LastPass's vault, open its pages yourself, ask for its master password, or use another
manager's login. Verify from a fresh snapshot that the site signed in.
