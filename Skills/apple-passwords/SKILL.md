---
name: apple-passwords
description: Help sign in with Apple or iCloud Passwords while keeping credentials and authentication with the user.
sites: []
keywords: [apple passwords, icloud passwords, passwords app, пароли apple, пароли icloud]
---

# Apple Passwords

Yab's `sign_in(tab)` fills credentials kept in Yab without showing the secret to the agent.
This is not an API for reading Apple Passwords. Yab can show an Open Apple Passwords choice for
accounts with verification codes, but it cannot inspect whether Passwords has an OTP.

When the user specifically wants Apple/iCloud Passwords, keep that choice. Use `handoff` on the
sign-in page for the user to choose the account, approve Touch ID or fill the code through their
Passwords UI. Say which site and account need them, without requesting the password or OTP seed.
For an explicit request to save/update a login in Apple Passwords, hand over the site's form and
explain that the user completes the save in Passwords. Do not claim an unverified save succeeded.

If the task only needs a login and the user has not selected a provider, `sign_in` can try Yab's
saved login first. For a mailed code, use mail_code when available; for a texted code,
messages_code when enabled. Passwords-app OTPs and passkey authentication stay with the user.
Never call `applePasswords.*`: those are another browser's APIs, not Yab tools. Apple Passwords can't be
connected in Yab until Apple approves Yab's helper, so `sign_in` never answers with its menu and
`unlock_manager` doesn't take it: hand it to the user.
