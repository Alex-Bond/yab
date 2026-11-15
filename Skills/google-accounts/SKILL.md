---
name: google-accounts
description: Working out which signed-in Google account is /u/0, /u/1 and so on, switching between them, and picking the right one before touching any Google app.
sites: [accounts.google.com, myaccount.google.com, mail.google.com, docs.google.com, drive.google.com, calendar.google.com]
signed-in: [SID, __Secure-1PSID]
keywords: [google, google account, gmail account, work account, personal account, authuser, switch account, /u/1]
---

# Google accounts

Many people are signed in to more than one Google account in the same browser: a personal one, a work
one, a client's. Every Google app addresses them by a number in the URL (`/u/0/`, `/u/1/`, ...) or by an
`authuser=` parameter. Read this before doing anything in Gmail, Docs, Sheets, Drive, Calendar, Forms or
Slides, because acting in the wrong account is the most common and most embarrassing mistake.

## How the numbers work

- The number is the order the accounts were signed in on this browser. `/u/0/` is the first (the default
  one), not necessarily the one the user thinks of as primary.
- The order can shift when the user signs out of one account and back in. Do not rely on a number you
  remembered from weeks ago without checking it again.
- The same document, thread or event has different ids or no access at all under another account.
  A 404, "You need access" or an empty search often just means the wrong account.
- Most apps also accept the email in place of the number: `https://mail.google.com/mail/u/${email}/`,
  or `?authuser=${email}` on Docs, Drive and Calendar links. This is the safest form when you know the
  address, because it cannot drift.

## Finding out who is who

1. Check memory first: `memory_search("google account")` or the person's name. The user may already have
   said which address is work and which is personal.
2. Open `https://accounts.google.com/AccountChooser` (or `https://accounts.google.com/SignOutOptions`)
   and `snapshot`: it lists every signed-in account with its name and email, in `/u/N` order.
3. Or open the app itself at a given index, for example `https://mail.google.com/mail/u/1/`. The tab
   title reads like `Inbox (4) - name@company.com - Gmail`, and the avatar button at the top right has an
   accessible name such as `Google Account: Name (name@company.com)`.
4. Once you know the mapping, `remember` it (which address is which role), not the bare numbers.

## Choosing the right account

- The task names an address or a company: use the account with that domain.
- The task mentions a colleague, a client or a work document: prefer the work account. A family member,
  a personal purchase or a subscription: prefer the personal one.
- A link the user gave you usually carries its own `/u/N/` or `authuser`. If it fails, try the other
  accounts before reporting that the item does not exist.
- When searching for something whose account is unclear (an email, a file), search each account in turn,
  in its own tab, and say which account the result came from.
- If it is genuinely ambiguous and the action is not read only (sending, sharing, creating), ask the user
  with `handoff` or in your reply rather than guessing.

## Switching

- Change the number or email in the URL and navigate. This is quicker than the avatar menu.
- The avatar menu (top right) also lists accounts; clicking one opens that app under that account,
  often in a new tab.
- "Add another account" and any password or 2FA screen is for the user: `handoff(tab, "sign in to ...")`.
  Never type credentials.

## Pitfalls

- A Google Workspace admin may block personal accounts from opening work files, which looks the same as
  a missing file.
- `accounts.google.com` pages can show "Choose an account" when a link has no account hint. Pick the
  right row by email, not by position.
- Do not sign the user out of anything to "fix" the ordering.
