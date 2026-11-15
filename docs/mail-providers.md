# Mail beyond Gmail

Yab's Mail ([mail.md](mail.md)) began on the Gmail API alone. This is how it takes Outlook.com and Microsoft 365, any IMAP mailbox, and Fastmail, and how an agent sets up the hard cases that used to need server names, ports and app passwords typed by hand.

Written 2026-10-12, checked against the code and partly built 2026-10-17: M1 is in, M3 is built behind Settings › Experimental › Other Mail Accounts (off by default) and held to a fake IMAP server, M2 and M4 are not started. 2026-10-21: iCloud and Zoho (feedback #146) added through the sheet end to end against fakes shaped as each, below; real accounts still to be tried by the person.

## Order

| Step | Gives | Over | State |
|---|---|---|---|
| M1 Provider layer | nothing new to see; Gmail behind a seam | `MailProvider`, `MailSyncing` in `Sources/MailCore` | built |
| M3 IMAP and agent setup | iCloud, Zoho, Yahoo, AOL, Fastmail, GMX, Yandex, hosting providers, company servers | IMAP + SMTP, autoconfig, `mail_probe` | built behind Experimental; real accounts not tried |
| M2 Microsoft | Outlook.com, Hotmail, Live, Microsoft 365 work and school mail | Microsoft Graph, OAuth | waits on Yab's Entra app |
| M4 Fastmail | Fastmail and other JMAP hosts | JMAP, API token | not started (Fastmail works over M3's IMAP meanwhile) |

The spec first put M2 before M3. It changed on 2026-10-17: feedback #146 asked for iCloud Mail and Zoho Mail, both IMAP with app passwords, and M2 cannot ship before Yab has its Microsoft app (`OutlookClient.shippedID` is still empty; the Outlook calendar waits on the same registration). So M1, then M3, then M2 once the app exists, reusing `OutlookClient` and `MailSignIn` with mail scopes added. Each step ships behind Experimental first, with its eval passing on the farm.

## Where Gmail is written in

Before M1 Gmail was behind no seam. After it, what still is Gmail's, and why:

| Place | What is Gmail's |
|---|---|
| `MailCore/MailGmail.swift` | the REST client, its quota units (`MailGmail.cost`), `MailPace`, base64url bodies, the message JSON read into `MailMessage` (`MailGmail.message`, which IMAP's reader reuses, below) |
| `MailCore/MailGmailProvider.swift` | Gmail as a `MailProvider`: `apply` is its thread modify, trash and untrash, and the batch rules (`batchFrom`, `batchMessagesFrom`) that used to sit in `MailOps` |
| `MailCore/MailSync.swift` | Gmail's own `MailSyncing`: `profile()` and `historyId` as the cursor, `history(since:)`, list queries in Gmail's search words, `markFiles` |
| `MailCore/MailAccount.swift` | `MailClient`: Google's consent and token URLs, `gmail.modify` and calendar scopes, revoke; keychain service `Fast Mail` (shared by every kind) |
| `MailCore/MailQuery.swift` | the user's search language is Gmail's; `query.gmail` writes it back for Gmail's server search |
| `MailCore/MailStore.swift` | `messages.labels` holds Yab's labels, which are Gmail's ids for Gmail and mapped ids for IMAP (below); unchanged |
| `MailCore/MailSendAs.swift`, `MailAttach.swift` | send-as list and signatures from Gmail's settings; the 25 MB limit |
| `Sources/Fast` | about a dozen files name system labels (`INBOX`, `TRASH`, `SPAM`, `UNREAD`, `STARRED`, `CATEGORY_*`), which every provider maps into; `MeetingsGoogle`, `Meetings` and `MailRecall` (the mail memory's years of mail) reach Gmail through `engine.gmail`, nil for other kinds |
| `evals/mail/fake_gmail.py` | the Gmail evals; IMAP has `evals/mail/fake_imap.py` |

Already provider-neutral and kept as is: `MailCompose.raw` builds a whole RFC 5322 message, which SMTP, Graph and JMAP all accept; `MailInvite`/`MailICS`; `MailSense`, `MailMemory`, `MailEmbed`, `MailRich`, `MailCodes`, drafts written ahead, snoozes, reminders, splits and the journal are local.

## M1: the provider layer

### The model stays Gmail-shaped

Labels stay Yab's model of a mailbox. Gmail is the richest of the four, and the store, the splits, the column and the agent tools all speak it. Other providers map into it:

| Yab's label | Gmail | Graph | IMAP (built) | JMAP |
|---|---|---|---|---|
| `INBOX` | label | `inbox` folder | `INBOX` | mailbox role `inbox` |
| `SENT`, `TRASH`, `SPAM` | labels | `sentitems`, `deleteditems`, `junkemail` | SPECIAL-USE `\Sent` `\Trash` `\Junk` (RFC 6154), else their usual names at the top or under INBOX (Sent Messages, Deleted Messages, Junk, Spam, and German, French and Russian ones) | roles `sent`, `trash`, `junk` |
| `DRAFT` | label | `drafts` | not kept: Yab's drafts are its own | role `drafts` |
| archived (no `INBOX`) | no label | `archive` folder | `\Archive`, else a folder named Archive, made once when first needed | role `archive` |
| `UNREAD` | label | `isRead` false | no `\Seen` | no `$seen` |
| `STARRED` | label | `flag.flagStatus` | `\Flagged` | `$flagged` |
| user label | `Label_…` | category or folder | folder, as `Label_f:<path>` | mailbox |
| a label Yab makes itself (yab/Snoozed, yab/Muted) | label | category | this Mac's alone, `Label_local:<name>` | mailbox |
| `CATEGORY_*` | Gmail tabs | Focused/Other | none; Sense sorts | none; Sense sorts |

`\All`, `\Flagged` and `\Important` folders (Gmail-like virtual ones) are never synced: their mail is the same mail.

### The seam, as built

```swift
public protocol MailProvider: Sendable {
    var kind: MailProviderKind { get }          // .gmail, .graph, .imap, .jmap
    var can: MailAbilities { get }               // labels vs folders, threads, search, sendAs, push, savesSent, editLabels
    func who() async throws -> MailIdentity
    func labels() async throws -> [MailLabel]    // labels or folders in Yab's shape
    func label(id: String) async throws -> MailLabel          // with its counts
    func label(named: String) async throws -> String          // found or made: yab/Snoozed
    func makeLabel(named:) / renameLabel(id:to:) / showLabel(id:_:) / deleteLabel(id:)
    func unread(in label: String, page: String?) async throws -> (ids: [String], next: String?)
    func thread(_ id: String, full: Bool) async throws -> [MailMessage]
    func message(_ id: String, full: Bool) async throws -> MailMessage?
    func attachment(message: String, id: String) async throws -> Data
    func apply(_ edit: MailEdit, in store: MailStore) async throws   // labels on and off a thread, a pack, messages
    func send(raw: String, thread: String) async throws -> (message: String?, thread: String)
    func sentThread(messageID: String) async throws -> String?
    func sendAs() async throws -> [MailSendAs]
}

public protocol MailSyncing: AnyObject, Sendable {   // how a store is kept in step: Gmail's is MailSync
    var store: MailStore { get }
    func sync() async throws -> Bool
    func open(thread:) / prefetch(threads:) / search(_:take:pages:)
    func keepLabels(now:force:) / countLabels(now:) / set(shownLabels:) / keepSendAs(now:)
}
```

`MailCenter.Engine` holds `provider` and `sync` (for IMAP one object, `MailIMAPAccount`, is both), and `gmail` as `provider as? MailGmail` for what only Gmail has. The journal (`MailOps.flush(store, provider:)`), files (`MailFiles`, `MailAttach`), the label menus and `mail_labels`, Mark All Read and `yab mail flush` (`MailLater.provider(for:store:)`) go through the provider.

### Decisions (the open questions of 2026-10-12)

- **Seam at two levels, not one.** The spec drew one call-level protocol with `MailWhere` replacing Gmail's query strings in sync. Built instead: calls (`MailProvider`) shared by everything that acts, and sync (`MailSyncing`) per kind, because Gmail's history id and IMAP's UIDs and MODSEQ per folder share no useful shape. Gmail's `MailSync` stays exactly as it was and keeps its query strings, so its calls cannot change; `MailWhere` is dropped.
- **Gmail's calls unchanged by construction.** The only code that moved is the batch logic, now in `MailGmailProvider.apply`, word for word. The Mail and Meetings suites (572 tests) are green after it as before it.
- **Names kept from Gmail's client** (`labels()`, `attachment(message:id:)`, `sendAs()`) rather than the spec's `folders()`, `file()`, `senders()`, so the Gmail client conforms without an adapter.
- **Kind per account in the settings**, `mail.provider.<account>` (absent is Gmail: every account before M3), server facts in `mail.imap.<account>` as JSON (`MailServerSetup`), never a secret. No `provider` meta key in the store: an address changes kind only by Disconnect and Add Account, and Disconnect deletes its store.
- **Keychain:** one item per account under `Fast Mail` as before. Gmail's stays a bare refresh token (no migration of existing items); IMAP's is JSON `{"kind":"imap","password":…}` (`MailSecret`). A test world's fake account keeps its fake password in that world's settings, never in the keychain.
- **What only Gmail has stays Gmail's for now:** the calendar (`MeetingsGoogle.accounts` lists Gmail accounts alone), the mail memory's five years (an account on another server remembers the mail kept on this Mac, `MailMemoryBuild.gmail` nil). Search asks a server only when it can say Yab's words (`MailAbilities.search`): Gmail, and IMAP for what SEARCH has words for (below).

### Done for M1

- [x] `MailProvider`, `MailSyncing`, `MailEdit`, `MailAbilities` in `Sources/MailCore/MailProvider.swift`; Gmail conforms in `MailGmailProvider.swift`.
- [x] Every app call site goes through the engine's provider; tests' `gmail:` forms kept as thin overloads.
- [x] Mail and Meetings suites green on the farm (job `3f6c8e8caf854f71`, 572 tests, the same count and result as the baseline `1da20d713c9446e3` before the change).
- [x] `evals/mail/check.py` against `fake_gmail.py`, A/B with the commit before M1 on one Mac (`scripts/runs/mail_check_ab.sh 556133a4`, job `a939526f1bb74927` on m4): 547 passed and the same 24 failed on both sides, no check new either way. The 24 (rows, space, pin, labels, mail_labels and a few more) fail on m4 before M1 too; they are this Mac's or the check's, not the seam's, and want a look of their own.
- [ ] `bench mail-time` within noise of before on adhd, same build mode.

## M3: IMAP and SMTP, and the agent doing setup

### What finds the server without anyone (built: `MailFinding`)

In this order, stopping at the first answer, as Thunderbird does:

1. Known providers in the app (`MailKnownProviders`): Gmail and Microsoft routed to their APIs; iCloud (icloud.com, me.com, mac.com), Yahoo, AOL, Fastmail, GMX, Yandex, Zoho in every data center (zoho.com, .eu, .in, .com.au, .jp, zohocloud.ca, .sa, .com.cn, personal at `imap.zoho.*`), Proton Bridge on this Mac; with their hosts, whether they want an app password, the page that makes one, and whether their SMTP saves sent mail itself.
2. `https://autoconfig.<domain>/mail/config-v1.1.xml` and `https://<domain>/.well-known/autoconfig/mail/config-v1.1.xml`.
3. Mozilla ISPDB, `https://autoconfig.thunderbird.net/v1.1/<domain>`.
4. MX lookup (dnssd): an MX of a known provider is that provider (a company domain on Zoho signs in at `imappro.zoho.*`, on Google or Microsoft 365 goes to their API); else the MX's own domain through ISPDB.
5. DNS SRV `_imaps._tcp`, `_submission._tcp` (RFC 6186, RFC 8314).
6. Guess `imap.<domain>:993` and `smtp.<domain>:587`, shown with the servers open to edit and tried before kept.

Autodiscover (POX, for hosted Exchange) is not built: Exchange Online goes by Graph (M2), and on-premises Exchange with IMAP left on is found by 4 to 6.

### The engine (built)

- **Transport:** `MailSocket`, a `URLSessionStreamTask`: TLS from the first byte (993, 465), or STARTTLS begun on the line (`startSecureConnection`), which iCloud's SMTP on 587 needs and Network.framework cannot do (it sets TLS once, at the start). Plain TCP only to this Mac (test worlds, Proton Bridge's STARTTLS aside). No third-party library.
- **IMAP** (`MailIMAP.swift`): a response reader with literals, quoted strings, lists and bracketed sections; `CAPABILITY`, `AUTHENTICATE PLAIN` (with SASL-IR) else `LOGIN`, `ID`, `ENABLE CONDSTORE`, `LIST` with `RETURN (SPECIAL-USE)`, `SELECT (CONDSTORE)`, `STATUS`, `UID SEARCH`, `UID FETCH` (with `CHANGEDSINCE`), `UID STORE`, `UID MOVE` or `COPY` + `\Deleted` + `UID EXPUNGE` (UIDPLUS) or `EXPUNGE`, `APPEND` (with `LITERAL+`), `CREATE`, `RENAME`, `DELETE`, `IDLE`. Folder names in modified UTF-7. Not built: `QRESYNC`, `COMPRESS=DEFLATE`, `THREAD`, `XOAUTH2`.
- **A message's identity:** its id is a hash of its Message-ID (`i…`), so a move (archive is a move) keeps its row, body and files here; where it sits, folder and UID and flags, is a table beside the store (`<store>.imap`, `MailIMAPPlaces`). One message in two folders (mail to yourself) is one message with both labels.
- **Threads:** the thread of a message it answers, known here, else a hash of the first Message-ID its References or In-Reply-To names, else its own (`t…`).
- **Reading a message:** the raw RFC 5322 message is read into Gmail's resource shape (`MailRFC822`: multiparts, base64, quoted-printable, charsets, RFC 2047 headers) and through `MailGmail.message`, so words, files and invitations are read by one reader for every kind. A file's id is its part (`p:0.1`), its bytes read from the message whole.
- **Cursor:** per folder `UIDVALIDITY`, `UIDNEXT`, `HIGHESTMODSEQ` and the count it had. New mail by `UID n:*`, flags by `CHANGEDSINCE` where CONDSTORE is, else the newest 500's flags each sync and the whole folder's every ten minutes; expunges found when a folder holds fewer than it should (`UID SEARCH ALL` against the table). A new `UIDVALIDITY` starts that folder again, the ids staying the same.
- **First sync:** the inbox whole by its headers, its newest 50 whole at once for the first screen, the newest 200 and the last 30 days whole; every other kept folder's last 60 days.
- **IDLE** on the inbox on a line of its own; news is a sync at once (`MailCenter.pushed`), and the beat still asks as for Gmail.
- **Search** (`IMAPSearch`): Yab's words as `UID SEARCH` says them, words as TEXT or SUBJECT, people as FROM, TO, CC, BCC (`me` the account), is:unread and is:starred, after:, before:, newer_than:, older_than:, NOT and OR, `CHARSET UTF-8` with literals for words that aren't 7-bit; in: and label: pick the folder searched, else every kept folder but Trash and Junk (in:anywhere takes them too). What it finds that isn't here comes by its headers, the newest 25, kept as a search brought them. has:attachment, categories and size: have no SEARCH words: the store answers those alone, never the server something wider.
- **Ops** (`MailIMAPAccount.apply`): read, unread, star as `\Seen`/`\Flagged` on every place the message sits; archive a move to Archive; trash and spam moves to Trash and Junk; back to the inbox from Archive, Trash or Junk (untrash goes to the inbox: IMAP keeps no record of where it came from); a folder's label put on is a move there. Undo is the journal's, as for Gmail.
- **SMTP** (`MailSMTP`): implicit TLS 465 or STARTTLS 587, `AUTH PLAIN` or `LOGIN`, `SIZE` from `EHLO`, the envelope from To, Cc and Bcc, DATA without the Bcc header, dot-stuffed. After sending, `APPEND` to Sent with `\Seen` unless the provider's SMTP saves sent mail itself (iCloud, Yahoo, AOL in the table; Zoho marked not, to be checked on a real account). The sent message shows in its thread at once, read back from what went.
- **Failures** are one set the probe, the sheet and the sync share (`MailServerTrouble`): `dnsNotFound`, `tcpRefused`, `tlsFailed`, `authRejected`, `appPasswordRequired`, `imapDisabled`, `capabilityMissing`, `quotaExceeded`, `timedOut`, `offline`, read from what the server said where it says it. A refused password stops the account as Gmail's revoked token does ("iCloud stopped accepting the password", Fix in Settings › Mail).

### mail_probe (built)

An agent tool (`mail_probe`) and the Add Account sheet's own check (`MailProbe`):

```
mail_probe {address, step?: "find" | "imap" | "smtp" | "all"}
→ {address, provider: "icloud", found_by: "known", route: "imap",
   imap: {host: "imap.mail.me.com", port: 993, security: "tls", dns: "ok", tcp: "ok", tls: "ok", auth: "rejected",
          server_said: "Authentication failed.", hint: "appPasswordRequired"},
   smtp: {host: "smtp.mail.me.com", port: 587, security: "starttls", …, auth: "not tried (no password in the keychain)"},
   app_password_page: "https://account.apple.com/…"}
```

It never returns a password and never takes one: it tries what the keychain holds for the address. Gmail and Microsoft addresses answer with their route and a note.

### How a secret gets in without passing through the model

1. **The person types it** in the Add Account sheet's own secure field (SwiftUI `SecureField`, an `NSSecureTextField`), straight into the keychain. Built.
2. **Taken from the page.** Built for iCloud, Yahoo, Zoho and Yandex (`MailSetup`, below): the agent makes the password on the provider's page in a tab of its own, and `mail_setup` with `keep_password` has Yab read that tab in its own script world for one element whose whole text has the provider's password shape (`MailSetupWay.shape`: iCloud `xxxx-xxxx-xxxx-xxxx`, Yahoo 16 letters, Zoho 12 letters and digits, Yandex 16 letters), and put it in the keychain. The agent hears only that it was kept. Pressing Set It Up is the person's yes.
3. **OAuth** where the provider has it (Yahoo, AOL): not built; app passwords cover them meanwhile.

Decision: way 1 always, way 2 only when the provider's page is already signed in in Yab. The shapes were read from the providers' help, not yet from a real page: each wants a check on a real account (Risks). The agent never signs in and never types a password.

### Settings (built, behind Experimental)

Settings › Experimental › Mail enables Gmail and IMAP accounts together. The retired `experimental.mail.imap` preference is ignored. With Mail on, Settings › Mail › Add Account's menu has iCloud… (the sheet opens on `@icloud.com`, the caret before the @) and Zoho, Yahoo and Other Mail…, each item wearing its site's icon, as Google Account… and Outlook Calendar… do.

The sheet (`MailOtherSettings.swift`) is the way in's own look (MailArrival), as drawn in the concept artifact `QypcF7LpyiCpZjfo38DjdU`: Mail's mark, its corner wearing where the mail comes from once found (the provider's or the domain's icon, Google's G, Outlook's); a title that becomes "iCloud Mail"; one address field, with iCloud, Zoho, Yahoo, Fastmail and Gmail under it, a press each, until something is typed. Continue (or Return) finds the servers. Then one surface holds what it takes, a row each: IMAP to turn on (only after IMAP was refused), the page that makes an app password with its icon, its path in the page's words and Open, then the password field showing the password's shape (`xxxx-xxxx-xxxx-xxxx`), then IN and OUT servers when they are open (at once when guessed). Under it "Sends as" with the name from macOS, editable in place, and the two servers as a line that opens them. Connect puts the password in the keychain, probes both servers (iCloud's IMAP user is the name before @, the whole address tried when that is refused), and keeps the account only when both said yes; the mark's edge runs meanwhile and closes with a tick. A refusal is said in a line under the surface, the field it is about outlined. A Google address goes to Google's sign-in; an Outlook one offers Add Outlook Calendar. The first account lands on Settings › Mail's "Mail has a space of its own", as Gmail's does; another just joins the list. The account's row says "iCloud · app password"; a stopped one has Fix…, which opens the sheet on its address.

### The agent sets it up (built, behind Experimental)

When the provider's app-password page is signed in in one of Yab's spaces (`MailSignedIn`: a live sign-in cookie in a space's store, `myacinfo` for apple.com, `T` for yahoo.com, `_iamadt`/`_iambdt` for zoho.*, `Session_id` for Yandex; cookies only, no page is read) and an agent can run, the surface is one row (the page, "Signed in in Yab as …") and the button is Set It Up with the agent's face. Paste an App Password Myself goes back to the rows.

Set It Up starts a task (`MailSetup.start`, a `MailChat` task with the column left as it is) whose words are the yes and the rules: open the page in its own tab, make a password named Yab, `handoff` when the site asks for the person's password again (Apple usually does), never type a password or sign in, `mail_setup keep_password` while the new one shows, turn IMAP on where the provider has a switch (Zoho), then `mail_setup finish`. The sheet shows each step in words as `mail_setup step` says it, ticked once past; a tab handed over shows as a row with Show the Tab. `finish` tries both servers with the kept password and adds the account; the sheet ticks and goes. Cancel stops the task; the password kept stays in the keychain, and the rows' field then says "Kept in the keychain", so Connect works with it.

From a chat, `mail_accounts add` with the address does the same when the person asks for it there (`MailSetup.adopt`): the run is that chat's own, no second task and no sheet, and its answer is Set It Up's words with the person's ask as the yes; a page not signed in in Yab asks for its sign-in, handed over. Gmail and Google Workspace addresses go to Google's own sign-in in the person's other browser instead, an address with no way of its own to Settings › Mail for an app password typed there, and Outlook is said to be not yet.

What the agent reads is guarded while its setup lasts (`MailSetup.guarded`, on every bench answer of that session): the kept password and anything of the provider's shape read as `•••• (kept by Yab)`, and `screenshot` is refused, as a picture can't be masked. A refusal after Connect offers Set It Up too: the whole way when the page is signed in, else the earlier chat that runs `mail_probe` and says where to look.

### What the agent does (first part built)

When Connect fails, the sheet offers Let an Agent Help: the password typed stays in the keychain for `mail_probe`, the servers as found are kept for it, and a chat task starts (`MailChat.start`) with the address, what failed, the provider's app-password and IMAP-setting pages, and the rules (never ask for or type a password; ask before changing a setting; tell the person to press Connect again once both servers say yes). With Other Mail Accounts on, tasks have the mail tools before any account is in, so `mail_probe` is there for a first account too. The cases it is for:

| Case | The agent |
|---|---|
| iCloud, Yahoo and others that need an app password | opens the page, waits for the person's sign-in, gets to Generate; the person pastes (way 1) until way 2 exists; probes until `auth ok` |
| IMAP turned off in the mailbox (Zoho, GMX, some hosts) | finds the setting in the provider's web settings (`imap_setting_page`), asks before turning it on, probes again |
| Company domain with no autoconfig | reads the domain's MX and the company's help pages, tries candidate hosts with `mail_probe`, shows what worked |
| Self-signed or wrong certificate | stops and explains; trusting a certificate is the person's, on a Yab card, never the agent's (not built: such a server is refused) |
| Connected once, now failing | reads the account's trouble, runs `mail_probe`, says what to do in a line |

The agent adds the account itself with `mail_setup finish` when Set It Up started it (above); the chat started after a refusal still leaves Connect to the person. Not built: an eval of the task against the fake with a stand-in agent and a fake app-password page.

### iCloud and Zoho, as a person adds them (built 2026-10-21)

Feedback #146's two, held end to end to fakes shaped as each provider is said to be, with nothing real asked:

- **Stand-ins** (`MailStandIn`, `MailSocket.swift`): in a test world, `mail.fake.hosts` maps a host Yab found by its own means (`imap.mail.me.com`, `smtp.zoho.com`) to a fake's port on this Mac, plain, STARTTLS and TLS left out on that line. So the sheet finds iCloud and Zoho through the known providers, shows their real servers, and the probe and the sync reach the fake. Nothing outside a `--test` run reads it.
- **Shaped fakes** (`fake_imap.py --provider icloud|zoho --user ADDRESS`): iCloud's folder names with SPECIAL-USE and a Notes folder, IMAP taking the name before @ or the address, SMTP the address, Sent kept by the server; Zoho's folders (Sent, Spam, Trash, Drafts, Templates, Snoozed, Outbox, no Archive), no SPECIAL-USE, CONDSTORE or MOVE, the whole address alone, SMTP refused from any other address, no Sent copy. These are the doc's beliefs about the real servers, not readings of them.
- **Folders not kept** (`MailKnownProvider.unkept`): iCloud's Notes (old notes kept over IMAP); Zoho's Outbox, Templates and Snoozed (Zoho brings snoozed mail back to the inbox itself; Yab's own snooze stays Yab's). Zoho's Archive is made on the first archive (`CREATE`), then a copy and an expunge.
- **The sheet driven as typed** (`agent-mail-add`, `MailSheetDrive`): Settings › Mail opened, the sheet with it (the way in's Other Account… for the first, Add Account › iCloud… after), the address, Continue, a password and Connect set through the sheet's own state and buttons, never a pointer. The password goes where a person's goes: the keychain under the world's `Fast Mail (<world>)` service, not the world's settings (no `mail.fake.imap.` mark on these accounts).
- **The eval** (`evals/mail/providers.py`, `scripts/runs/mail_providers_check.sh icloud-zoho`): Zoho then iCloud added through the sheet, found as Zoho Mail and iCloud Mail with their own servers and password shapes; a sign-in password refused in a line and nothing kept of it; the app password kept in the keychain; iCloud signed in as the name before @; both inboxes in All Accounts, Templates, Snoozed and Notes left out; new mail on both servers; the store's search and the server's for older Zoho mail; a reply on iCloud taken back with ⌘Z inside the undo window (nothing at SMTP), then sent after it, Sent kept by iCloud and nothing appended; a reply on Zoho from its own address, appended to Sent; archive making Zoho's Archive; no password in the world's settings, the app's output or the world's files; Disconnect taking the keychain item. Pictures, light and dark: the sheet empty, found and refused, Settings › Mail's landing and list, both inboxes, the search, the reply written and sent.
- **Fixed on the way:** Add Account › iCloud… opened its sheet on an empty field (a `.sheet(isPresented:)` read the start address as it was a moment before; the sheet is an item now, `MailSheetStart`); a search row found on an IMAP account's server said "Gmail" (it says the account's server, `MailCenter.serverName`: iCloud, Zoho Mail).
- **Unit tests** (`MailProviderShapeTests` in `MailIMAPSyncTests.swift`): the stand-in's rule; iCloud's probe and sync through its known setup (Notes left out, no APPEND after a send); Zoho's folders by name, Archive made, a copy appended to Sent, the server's search in a folder of the person's; a Zoho sign-in password said as an app password wanted, never in the probe's words.

- **iCloud read on the wire** (#441, 2026-10-23): `evals/mail/icloud_wire.py` and `ICloudWireTests` (`YAB_MAIL_WIRE=1`) reach Apple's real servers with a made-up name and password. IMAP greets with `SASL-IR AUTH=PLAIN`, refuses AUTHENTICATE PLAIN and LOGIN alike with `NO [AUTHENTICATIONFAILED] Authentication Failed` and keeps the line open; SMTP on 587 begins STARTTLS and offers `AUTH LOGIN PLAIN` after it. Yab's own socket does both the same way. An app password typed into the sheet is now sent as `MailSecret.cleaned` leaves it: no spaces (Google shows its groups with them) and no line end a copy off the page brought, as the agent's way already read it; a line closed before it said anything is said as that, never a bare "iCloud refused."
- **iCloud's line closed at the sign-in** (#441 again, 0.38.8, 2026-10-24): a fresh app password and "iCloud closed the connection before it took the password". The line closed with nothing said, so there was no refusal to read and the whole address was never tried (only a NO did that). Apple's real servers read with no sign-in (job `74fe710f96fd46e4`): IMAP greets `* OK [CAPABILITY XAPPLEPUSHSERVICE IMAP4 IMAP4rev1 SASL-IR AUTH=ATOKEN AUTH=PLAIN AUTH=ATOKEN2 AUTH=XOAUTH2]`, SMTP on 587 offers `AUTH LOGIN PLAIN ATOKEN ATOKEN2 WSTOKEN WETOKEN XOAUTH2` after STARTTLS. iCloud's PLAIN has refused real accounts' right passwords and dropped the line after, where LOGIN took them (MailKit #295, Thunderbird bug 694753), and Apple's help says to use the full address when the name alone can't connect. So iCloud signs in by LOGIN on both servers (`MailKnownProvider.auth`, `MailServerSetup.imapAuth`/`smtpAuth`, the way that worked kept for the sync); a line closed at the sign-in is tried once more after 0.8 s the other way, on a new line; Add Account (`MailProbe.connect`) tries the whole address after a closed line too; a refusal said as `* BYE` keeps its words. `fake_imap.py` acts each suspect (`plain_drops`, `name_drops`, `bye_refusals` in `/fake/options`), and `MailProviderShapeTests` shows each failing the old way and passing now. Not verified on a real iCloud account.

Not covered by it: real servers (TLS, Apple's and Zoho's own answers, iCloud's user name, Zoho's IMAP switch and Sent copies), and an agent's `mail_send` card on an IMAP account (the card and its yes are the provider-neutral path Gmail's eval covers; the send itself is the journal's, as here).

### Done for M3

- [x] Known providers, autoconfig, ISPDB, MX, SRV and guess (`MailServers.swift`), unit-tested with fixed answers (`MailIMAPTests`).
- [x] IMAP client, SMTP client, RFC 5322 reader, `MailIMAPAccount` as provider and sync, `mail_probe`, the Experimental switch, Add Account › Other Account…, Fix…, Disconnect, `yab mail flush` for IMAP accounts.
- [x] `evals/mail/fake_imap.py`: IMAP4rev1 with LITERAL+, ID, ENABLE, SPECIAL-USE, CONDSTORE, MOVE, UIDPLUS and IDLE, each switchable, SMTP submission, an HTTP door to change the mailbox; `--selftest` holds it to Python's imaplib and smtplib.
- [x] `MailIMAPSyncTests` against the fake: first sync, archive/trash/star/read out with ⌘Z before they go, back to the inbox, server-side new mail, flags and expunges, a new UIDVALIDITY, a reply by SMTP into Sent and its thread, the probe's every step; with CONDSTORE, MOVE, UIDPLUS and SPECIAL-USE on and off.
- [x] `evals/mail/imap.py` (the app end to end: Add Account by bench, the list, E with ⌘Z, S, opening a thread, #, IDLE's news, R and ⌘↩, Disconnect) green on adhd, and with `--no-condstore --no-move --no-idle` (no UIDPLUS either): job `3c459dca21e24370`, 25 of 25 each.
- [x] The sheet pictured in its states (`evals/mail/other_sheet.py`: empty, iCloud by hand, iCloud with Apple Account signed in, the agent under way for Zoho and waiting on the person for iCloud, a Google address, an Outlook one, servers guessed), job `cc3fdc7ae3714044` on m4, matching the concept artifact `QypcF7LpyiCpZjfo38DjdU`; `imap.py` 25 of 25 after it (job `ffb2333a9d8d4d71`).
- [x] iCloud and Zoho as a person adds them, against fakes shaped as each provider (2026-10-21, above): `evals/mail/providers.py` all checks and `imap.py` 25 of 25 (job `ac46b9897eb44fb0`), `MailProviderShapeTests` with the IMAP suites, 34 tests (job `6ada0db7e70c43e8`).
- [ ] Real iCloud and Zoho accounts set up from an empty Settings on adhd, the person doing only the sign-in and the app password, recorded per [recording-live-yab.md](recording-live-yab.md); whether Zoho's SMTP saves sent mail; iCloud's IMAP user name. Agents never sign in to real accounts.
- [x] Server search over IMAP for what SEARCH can say (`IMAPSearch`, `theServerFindsOlderMail`); L's list says Move To for a folder account (a label put on there is a move).
- [x] The sheet in the way in's look, the menu's icons, Set It Up with `mail_setup` and the password taken from the page (way 2), `MailSetupTests` (shapes, masking, cookies, the task's words).
- [ ] Each provider's password shape and sign-in cookie checked on a real account by the person; a fake app-password page eval for `keep_password`.
- [ ] Not built yet: the mail memory's older years for IMAP accounts (it holds what the sync keeps), OAuth for Yahoo and AOL, a trust card for self-signed certificates, QRESYNC and COMPRESS.

## M2: Microsoft Graph

### Sign-in

- Yab's own Entra app registration, the one the Outlook calendar already waits for (`OutlookClient`, `docs/meetings-on-tabs.md`): "Accounts in any organizational directory and personal Microsoft accounts" (`/common` authority), public client, PKCE, redirect `http://localhost`. Same `MailSignIn` loopback listener, consent page in a Yab tab, `login_hint` from the typed address (Add Account's address field routes Microsoft domains and MX here).
- Delegated scopes added to the calendar's: `Mail.ReadWrite`, `Mail.Send`, `MailboxSettings.Read`. No `Mail.ReadWrite.Shared` until shared mailboxes are asked for.
- Refresh tokens rotate on every refresh; keep the newest. No per-app revoke, so Disconnect deletes the token here and says where to remove the app.
- Publisher verification before release. No CASA-style assessment for Graph mail scopes ([casa.md](casa.md)).
- Work tenants may block user consent (`consent_required`, `AADSTS65001`, `AADSTS90094`): one line, and the agent's message to IT with the admin consent URL.

### Sync

- A `MailSyncing` of its own: one `deltaLink` per synced folder; `410 Gone` restarts that folder's delta, keeping the store.
- `$select` only the fields the store keeps; bodies by `/$value` (MIME) read through `MailRFC822`, the reader IMAP uses.
- Threads by `conversationId`.
- Ops through `MailProvider.apply`: read/flag/category by `PATCH`, move by `/move`, batches through `/$batch`. Trash is a move to `deleteditems`.
- Send: `POST /me/sendMail` with the MIME as base64; over 4 MB a draft plus an upload session. The sent copy found by `internetMessageId`.
- Pace: about 4 concurrent requests and 10,000 per 10 minutes per mailbox, `429` with `Retry-After`; a Graph price list in `MailPace`. Recheck the live limits page first.
- Push: polling deltas on `MailCadence`; change notifications need a public endpoint, later.

### Not EWS, not IMAP for Microsoft

- EWS is blocked by default in Exchange Online from 2026-10-01 and off for good on 2027-04-01.
- Outlook.com and Exchange Online turned off basic auth, so IMAP to Microsoft needs XOAUTH2 with the same Entra app; Graph does more, so Microsoft goes through Graph. `MailFinding` routes Microsoft domains and MX away from IMAP.

### Done for M2

`fake_graph.py` serving the delta, batch, move and sendMail shapes; the M1 evals green against it; one real Outlook.com account and one real Microsoft 365 tenant account end to end on adhd. The person signs in; agents never do.

## M4: JMAP for Fastmail

- Session at `https://api.fastmail.com/jmap/session`, an API token the person creates (way 1 or 2).
- `Mailbox/get`, `Email/query`, `Email/get`, `Email/changes`, `Mailbox/changes` with their `state` as the cursor, `Thread/get`, `Email/set`, `EmailSubmission/set`, `Identity/get`. Closest to Gmail's model.
- Push: EventSource while Yab runs.

Fastmail works over M3's IMAP meanwhile (in the known-provider table, with an app password). Done: `fake_jmap.py` and the M1 evals; one real Fastmail account end to end.

## What changes elsewhere

- **Settings › Mail.** Add Account takes an address for other accounts (built, Experimental); the Google button stays. Each account row says its kind where it matters ("iCloud · app password").
- **Codes before Connect.** Gmail's Atom feed path stays Gmail's. Other providers' codes come once the account is in, from the same store.
- **Cleanup.** ⌘U, Block Sender and Get Me To Zero work on every kind through the journal.
- **Read statuses, snippets, reminders, send later, drafts ahead, Sense.** Unchanged; all local.
- **Agents' mail tools.** Same names and shapes; new `mail_probe`. `mail_labels` on a folder account makes, renames and deletes folders.
- **Manual.** /manual/mail gets "Other accounts" when M3 leaves Experimental (fast-web repo).
- **requests.md.** #146 (iCloud and Zoho) is answered when M3 ships, not before.

## Risks

- **Real servers differ from the fake.** iCloud's user name, Zoho's IMAP switch and its SMTP's sent copies, Yahoo's app passwords: each to be checked on a real account by the person before M3 leaves Experimental.
- **A big IMAP inbox's first sync** reads every header of the inbox; a mailbox of 100,000 needs measuring (headers in pages of 100, the first screen first).
- **Folder accounts and labels.** A label put on with L moves the message; Yab's own labels (snooze, mute) stay on this Mac; a second Mac with the same account doesn't see them.
- **Admin consent** will block some Microsoft 365 users (M2).
- **Page-scraped app passwords** depend on each provider's page (way 2): a redesign that splits the password into several elements, or shows it in a frame, makes `keep_password` find nothing, and the agent says it is stuck; the person then pastes it.
- **Privacy statement.** Mail never leaves the Mac except to the chosen model, for every provider; IMAP and SMTP go straight to the provider's servers.
- **Exchange on-premises** without Graph and with IMAP off is out of scope.

## Sources

- EWS retirement in Exchange Online: [Petri](https://petri.com/microsoft-counts-down-to-end-of-exchange-web-services/), [Microsoft message center MC1227454 mirror](https://www.itelio.com/en/microsoft-message-center/MC1227454), [University of Waterloo notice](https://uwaterloo.ca/science-computing/news/retirement-exchange-web-services-ews-october-1-2026).
- Outlook.com basic auth off: [Microsoft support](https://support.microsoft.com/en-us/office/f4202ebf-89c6-4a8a-bec3-3d60cf7deaef), [heise](https://heise.de/-9767989).
- Graph Outlook throttling: [Microsoft 365 Dev blog, 2020](https://devblogs.microsoft.com/microsoft365dev/beta-outlook-api-throttling-limits-deploying-to-v1-0-on-microsoft-graph-may-2020); recheck learn.microsoft.com's Graph throttling limits page before M2.
- iCloud Mail server settings: Apple support HT202304 (imap.mail.me.com 993 SSL, smtp.mail.me.com 587 STARTTLS, app-specific passwords). Zoho Mail IMAP and SMTP: Zoho's help (imap.zoho.*, imappro.zoho.* for organization domains, 993 SSL; smtp 465 SSL or 587 TLS; app passwords with two-factor sign-in; IMAP access switched on in Settings › Mail Accounts).
- Autoconfig: Thunderbird's ISPDB and config-v1.1 format; RFC 6186 (SRV), RFC 6154 (SPECIAL-USE), RFC 7162 (CONDSTORE/QRESYNC), RFC 6851 (MOVE), RFC 4315 (UIDPLUS), RFC 2177 (IDLE), RFC 7888 (LITERAL+), RFC 3501 5.1.3 (modified UTF-7), RFC 8314 (implicit TLS), RFC 6409 (submission), RFC 8620/8621 (JMAP).
