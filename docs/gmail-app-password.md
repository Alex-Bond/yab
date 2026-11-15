# Gmail with an app password

New Gmail accounts in Settings > Mail use IMAP and SMTP. `gmail.com` and
`googlemail.com` are recognized by the address; Google Account in Add Account
also accepts a Google Workspace address. The sheet is the approved variant B
(the 2-Step Verification note inside the card). Existing Gmail OAuth accounts
keep their token, provider, sync, send and explicit reauthentication path.
An already connected OAuth account cannot be overwritten by the password sheet.
Gmail IMAP does not require the separate Other Mail Accounts experiment.

The sheet opens [Google Account app passwords](https://myaccount.google.com/apppasswords).
[Google requires 2-Step Verification](https://support.google.com/accounts/answer/185833?hl=en);
organization policy or Advanced Protection can make app passwords unavailable.
The person makes and pastes the password. Google setup is never automated.
Whitespace is removed by `MailSecret.cleaned`, including pasted line endings.
The password goes through the existing secure field and keychain path, with the
existing provider probe trying IMAP and SMTP before retaining the account.

## Protocol behavior

- [Google's endpoints](https://developers.google.com/workspace/gmail/imap/imap-smtp):
  imap.gmail.com:993 with TLS, smtp.gmail.com:465 with TLS. The existing server
  editor can use 587 with STARTTLS. Both logins use the full address.
- [Gmail IMAP extensions](https://developers.google.com/workspace/gmail/imap/imap-extensions)
  are used only when CAPABILITY advertises X-GM-EXT-1. X-GM-MSGID deduplicates
  folder views; X-GM-THRID joins messages into Gmail's threads. Both are read as
  unsigned decimal IDs and stored as hex, matching Google's link/API IDs.
- SPECIAL-USE identifies localized system folders. Gmail's English folder names
  are also recognized if attributes are absent. All Mail is synced so archived
  messages are kept. Sent, Spam, Trash, Starred and Important map to existing
  system labels. Drafts stay out of the folder sync, as for other IMAP accounts.
- X-GM-LABELS supplies authoritative memberships, including custom labels absent
  from the locally fetched folder window. Adding/removing a custom label does
  not move mail out of other labels. Archive removes Inbox membership. Without
  the extension, the existing folder operations and RFC threading are used;
  archive moves to the server's All Mail folder and never creates Archive.
- [Gmail retains SMTP's Sent copy](https://support.google.com/mail/answer/78892?hl=en).
  Yab does not APPEND a second copy. A locally sent message keeps its RFC-based ID; a copy already seen by IMAP
  reuses that ID and Gmail thread. SMTP acknowledgment and IMAP sync can arrive
  in either order without creating a second local message. A new SMTP thread's
  local ID is bound to its Gmail thread ID so reminders and read receipts keep
  their existing identity when the server copy arrives.

## Features and limits

| Feature | Gmail app password |
| --- | --- |
| Splits, local sorting, inbox badges, Mail pin | Existing store/provider path; no Gmail API required |
| Labels menu, new/rename/delete label, read/star/archive | IMAP folders, flags and Gmail label extension |
| Unread counts | IMAP STATUS and local store; counts describe messages in the server folder, without Gmail API thread totals |
| Later, muted and Yab's own sorting labels | Existing IMAP behavior: local labels on this Mac |
| Search | Existing IMAP translation; unsupported Gmail operators use local results only, not X-GM-RAW |
| Category tabs | No API category labels; existing local Sense sorting remains |
| Send-as aliases and Gmail signatures | Account's address/name only; API settings are unavailable |
| Calendar list, event creation and Gmail invitation response | Not authorized by an app password; existing calendar capability guards apply |
| Years-old mail memory backfill | Gmail API backfill is unavailable; local synced mail can still feed memory |
| Gmail web drafts | Not synchronized; Yab's existing local drafts remain |
| Complete server thread outside the sync/search window | Not fetched automatically through the Gmail API |
| Label visibility in Gmail | IMAP's existing behavior, local visibility settings only |

## Repeatable proof

`evals/golden/gmail_app_password.sh BASE` runs a provider-shaped local fake:
core tests on BASE with the identical tests/fake, core and existing IMAP tests
on the candidate, and actual Add Account sheet shots on both apps. The probe
uses only made-up accounts/passwords and redirects the Gmail hosts to loopback.
It never opens the real app-password page or starts Google OAuth.
The candidate exercises Gmail, Googlemail, explicit Workspace selection,
wrong-password handling, whitespace normalization and the success tick. A real
Return key submits the address; run with `--needs capture,pointer --display`.
Every output is under `$YAB_FARM_OUT/gmail-app-password`.

Run the candidate golden check without BASE after landing. A passing fixture
check does not establish acceptance against the reporter's real account.
