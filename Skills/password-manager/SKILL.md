---
name: password-manager
description: Sign in or fill a checkout using Yab's saved credentials and Wallet, without exposing secrets to the agent.
sites: []
keywords: [saved password, password manager, autofill login, менеджер паролей, сохраненный пароль, автозаполнение]
---

# Saved credentials

Check the site's signed-in space with `spaces(site)` before asking the user to sign in again.
Use a working Continue with Google/GitHub option when the snapshot names an available provider.
For a Yab-saved login, call `sign_in(tab)`; Yab fills it under the user's current approval mode.
Use visible account context to verify the result and hand over if the saved account is wrong.
Never extract passwords through eval, cookies, files or screenshots.

Use `autofill(tab, what: form)` for forms, or `card`/`address` for checkouts. It fills without
submitting; card details stay hidden and may require Touch ID. Once card details are entered,
screenshot is unavailable, so inspect ordinary form state through snapshot instead.
A fill is not permission to submit, purchase or agree to consent.

Order, always: Yab's own login, then the password managers the user connected in Settings ›
Passwords (the brief lists them and who unlocks each), then `handoff`. `sign_in` walks it for you
and answers menu (pick the account in that manager's menu on the page), locked (call
`unlock_manager(provider)` when Yab has its unlock password, else `handoff`) or none (`handoff`).
Each manager's skill says what its menu looks like: 1password, bitwarden, nordpass, proton-pass,
dashlane, lastpass, apple-passwords. Unlock once per lock; after not unlocked, never again. Never
take a login from one manager to sign in through another, and don't claim an API the tool list
doesn't have. Saving or generating a
new secret is separate from signing in; only use capabilities actually present in the tool list.
If a capability is unavailable, hand over the appropriate form to the user.
