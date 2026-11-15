# Approvals on other devices

When an agent needs the person's yes (pay, send a mail or a message, upload a
file, sign in, fill an address), Yab puts a card on the tab. The same
question also goes to the person's other devices in Sync: Yab for iPhone and
any other Mac. Whichever answers first settles it. This covers cloud
assistants ([assistants.md](assistants.md)) and local agents: Claude Code or
Codex through `yab mcp`, `yab "task"`, and Yab's own tasks.

## Who asks, and what goes

`Agents.ask` ([AgentPermit.swift](../Sources/Fast/AgentPermit.swift)) calls
`Agents.asker(permit)`:

- An assistant's session (or a task it started): for a traveling kind, while
  **Ask on my other devices** is on.
- A local agent's: when Settings › AI › Agents › **Ask on my other devices**
  is on (`agents.ask-elsewhere`, on by default; agents can't change it), the
  session is followed by someone (not `unattended`), isn't a page question from a subagent or a
  task from the iPhone, and the question is one of
  `AssistantApprovals.travels`: press (payments included), upload, use,
  Messages, send message, send mail, address, save skill, sign-in, mail read,
  mail change and mail site. A chat question from a subagent uses the root chat.
- Never: Mac access, folders, native effects, a password manager's unlock.
  Those need this Mac itself.

The record names the asker as `local.<cli>` with the plan's name ("Claude",
"ChatGPT"), so its title reads "Claude: Pay · $12.00?".

## Publishing

`AssistantApprovals.publish` writes the sealed `assistantapproval` record
(`SyncCenter.publishAssistantApproval`):

- A local question asked while the person is at the Mac (`AskPresence`,
  [chat-asks.md](chat-asks.md), "Finding you") goes up quiet
  (`AssistantApprovalRecords.Saying.quiet`): already `seen`, pushed as an
  ordinary change with no alert and no withdrawal, so the iPhone has it in
  its tray when Yab is opened there but doesn't ring (another Mac shows
  its card while Yab is in front there, with no notification). Once the person is
  away, `AssistantApprovalRecords.ring` takes `seen` off and alerts; one
  opened on the Mac meanwhile stays quiet. `seen` isn't in the digest, so
  an answer given to the quiet one holds. Until 2026-10-22 a question at
  the Mac didn't go up at all, and the iPhone showed nothing.
- A local question waits (`unpublished`) until Sync is live and some other
  device answers (`assistantAnswerers`). A Yab woken hidden for agents starts
  without Sync; the first question starts it (`launchIfNeeded`), and
  `takeAssistantAnswers` publishes what waited.
- A sign-in goes with its accounts as `choices`, only to a device that
  picks (`assistantChoosers`, commandcap version 2). An assistant's sign-in
  with one account still goes to an older device as a plain yes.
- A request's `tab` is a UUID for a tab, or `chat:<root id>` for the whole
  chat. Older readers reject the latter at their UUID validation, so the
  record schema stays 1. Answers check the current root permit's key and
  session and go through `Agents.answer(chat:)`.
- One open question a tab or chat: a new one, the tab closing (`Browser.close`) or
  the session leaving (`Agents.leave`) closes the old record.
- A local question past its lifetime (15 minutes for an attached session,
  a day for a task) leaves Sync but stays on the Mac's card. An assistant's
  lapses as before.

## Answering

The answer is the sealed `assistantanswer` record, checked by the Mac
(`answerFromSync`): known writer, digest, expiry, the live permit, and for a
local question that the setting is still on. Then the ordinary
`Agents.answer` runs, as a press on the Mac's card would.

Records version 2 ([AssistantApprovalRecords.swift](../Sources/SyncKit/AssistantApprovalRecords.swift)):

- `Request.choices`: a sign-in's accounts, at most three. Absent on every
  other question, so those encode, and digest, exactly as version 1.
- `Answer.choice`: the account a yes picked, required for a request with
  choices and refused otherwise.
- `Answer.proved`: the device passed Face ID, Touch ID or its passcode just
  before. For a sign-in, the Mac then fills once without its own Touch ID
  (`Vault.provenElsewhere`: that site, one fill, two minutes).
- `commandcap.assistantApprovals`: 1 answers yes or no, 2 also picks and
  proves (`AssistantApprovalRecords.answers`, `chooses`).

Every yes is proven where it is given: Face ID or the passcode on the
iPhone (`SyncBridge.answerAssistantApproval`), Touch ID or the password on
another Mac (`ForeignAssistantApprovalCard.prove`). A no needs nothing.

## Details

A question's lines are short; the person reads the real thing before a yes.
Beside the request go three records of the Mac's own
([AssistantApprovalDetails.swift](../Sources/SyncKit/AssistantApprovalDetails.swift)),
written and removed by [ApprovalDetails.swift](../Sources/Fast/ApprovalDetails.swift):

- `assistantdetail`, the request's id, written just before the request
  (`SyncCenter.publishAssistantApproval` → `ApprovalDetails.publish`):
  - a payment (a press that pays, `AgentPermit.isPayment`): `pay` from the
    tab's pay sheet (`PayFlow.model`): site, item, amount, delivery, its
    cards (`PayWallet.cards()`: id, brand, last four, name; never a number),
    its addresses (`PayWallet.addresses()`: id, line, who), the ones picked,
    and whether the page has boxes for a card and an address. Verb "Pay
    $42.10". Written once the sheet has read the page (`PayFlow.looked`), and
    again whenever the sheet changes: the total read again, a card or an
    address added on the Mac.
  - `sendMail` / `sendMails`: `mails` from the outgoing mails behind the
    permit (`Agents.sendMail` keeps them in `ApprovalDetails.outgoing`):
    from (the sending address), to, cc and bcc, subject, every word of the
    body (not the card's 600), and the files with their first three pages.
    `person` when it is one mail to one person. Verb "Send" or "Send All 3".
  - `upload`: `files`, a PDF's first six pages and an image pictured. Verb
    "Upload passport.pdf" or "Upload 2 Files".
  - `sendMessage`: `text` and `person`. A press whose permit carries words
    (a post): `text`, verb its label.
  - `mailChange`: verb from `Bench.changeWords(act).yes`, and `mails` (who,
    when, the subject, its first lines) when mail_act named its threads.
  - anything else: the verb alone.
  Mail bodies and words are cut, longest first, to keep the record within
  58,000 bytes.
- `assistantpreview`, `<request>.<file>.<page>`: a JPEG of 50 KB at most
  (its sealed record stays under the server's 96 KB), made off the main
  thread after the detail: PDFKit for a PDF, ImageIO for an image, Quick
  Look for any other file.
- `assistantresult`, the request's id, for a yes given on another device:
  `paying` at once for a payment, then `paid` (with the site's order) or
  `declined` ("Payment not completed") from the pay sheet's phases; `done`
  or `failed` ("Not sent") once the agent's send ran (`Agents.sent`); `done`
  at once for anything that isn't a send. A payment's sheet that goes with
  no word from the site says `done`.

The request, its detail, pages and result go together when the question is
over (`closeAssistantApproval`, which a lapse reaches too). One answered on
another device stays until its result is settled and 30 seconds more, so
that device reads what came of its yes; four minutes at most.

### An answer that read the detail

`takeAssistantAnswers` reads the detail and checks the answer against it
(`validatePicks`): its `detailDigest` must be the detail's now, and a
payment's `card` and `place` one of the detail's or one the device just kept
(`added`). Refused, the Mac writes a `failed` result ("This changed on your
Mac. Look again.") and the question stays open; the same answer isn't tried
again.

A payment's picks are made in the pay sheet as a click in Pay With and Ship
To makes them (`PaySheetModel.choose`, `PayFlow.takePicks`): the address
put into the page, then the card (`put(card:)`), the total read again, and
only then the yes that lets the agent's press go. A card or an address the
iPhone just kept is a `card` or `address` record in SyncWallet's shape
(`AssistantWallet`); SyncWallet takes it into the keychain as it takes
another Mac's (no rule there about which device wrote it), and the Mac waits
up to 10 seconds for `PayWallet` to list it. It never comes: nothing is
paid, the result says "That card isn’t on your Mac yet. Try again.", and the
question stays.

`Mail.bcc` was added to the contract (absent when nobody), so every address
a yes sends to is read before it.

## Reaching the iPhone

The Mac's `SyncClient.kick(alerting:)` marks the push that carries a
question: `"alert": <record name>, "alertID": <question id>`. The server
(`sync-server/src/account.ts`, `push.ts`) then sends an APNs alert instead of
the silent wake, at once (at most every 5 seconds a device), to devices
that registered with `alerts: true` and have no socket open:

- `apns-push-type: alert`, priority 10, `thread-id: approval`,
  `mutable-content`, `content-available`, `apns-id` and `apns-collapse-id`
  the question's id;
- generic words ("Yab", "Needs your answer"), and the question's sealed
  record in `yab: {n, b}` when it fits APNs's 4 KB;
- `interruption-level: time-sensitive` and `sound: ask.caf`: through Focus
  and Scheduled Summary, with the Mac's two notes (`AskSound`), generated by
  `Phone/scripts/ask-sound` into the app bundle's root. Both App IDs
  (`dev.serafim.fast.iphone`, `.notify`) have Time Sensitive Notifications.
  `ApprovalNotice.content` sets the same level and sound on what it writes.

The server can't read the record. On the iPhone, `YabNotify` (a
Notification Service Extension, [Phone/Notify](../Phone/Notify)) opens it
with the Sync key from the app's keychain group and writes the title and the
summary (site, what for, amount; never a draft's words) through
`ApprovalNotice`. The app posts the same notification under the same id
when its line brings a question (in front, woken in the back, or launched
in the back by a silent push), skipping one already delivered, and removes
it once answered or gone. Reconciliation reads every delivered `approval`
notification, including ones from an earlier launch, on launch, foreground,
question changes and both background wake paths. A persisted notice ledger
prevents a dismissed question from ringing again on relaunch.

The owning Mac marks a question `seen: {device, at}` when the person clicks
its notification or has its card in the active browser window, and
publishes it already seen while the person is at the Mac (quiet, above);
taking `seen` off again (`ring`) is the one change back, and it alerts. This changes
no fact in the approval digest: an answer sent just before that still works.
The iPhone keeps the seen card and removes its notification. A notification
of an already answered question opens to “Answered on your Mac”.

Closing or marking seen uses `kick(alerting:withdraw: true)`. Its accepted
change carries `withdraw: true` alongside `alert` and `alertID`. The Worker
sends a silent push with the question id as `apns-collapse-id`, independently
of the ordinary minute limit, once per question and recipient (durable dedup
for two days). It uses the same APNs key. iOS may delay this background wake;
opening Yab always catches up. The Worker source is in this repository's
`sync-server/`, rather than `fast-web`.

The iPhone sends `alerts: true` in `PUT /devices/{id}/push` only while its
notifications are allowed; it asks for that only from its own buttons.

## Testing

- `swift test --filter "LocalApprovalTests|ApprovalChoiceTests|SyncClientTests|ApprovalDetail"`
  through `./farm test` (`ApprovalDetailTests` the records,
  `ApprovalDetailMacTests` what each kind publishes, picks, results, a
  phone's card read as Wallet reads its own).
- `cd sync-server && npm test`: `test/push.test.ts`, "alert push for a
  question".
- `Phone/scripts/remote test ApprovalNoticeTests`.
- `evals/approvals/local.sh` (needs node): two Yabs in one Sync account on a
  local server; a `yab mcp` client pays on a checkout page and signs in with
  two saved accounts on A, B answers as its card does; also a no, a closed
  tab, the setting off, and A woken hidden. Details: B reads a payment's
  detail and pays with the other card and address, then with a card it just
  kept (`keepcard`), and reads two mails sent at once with a PDF's pages.
- On a real iPhone: Claude Code pays and signs in through `yab mcp` while
  the phone is locked; the Lock Screen shows the question, Face ID, the
  agent goes on.

## On the iPhone

Yab for iPhone shows a question as a tray under the thumb
([Phone/Sources/Tasks/AssistantApprovalLayer.swift](../Phone/Sources/Tasks/AssistantApprovalLayer.swift),
[Phone/Sources/Approvals](../Phone/Sources/Approvals)), the design picked in
claude.ai/artifact/MZjAeESmzDF1vxDr36b3cx:

- The head is what the question is about: the site's icon and name, the
  person, Mail, with the agent's face on the corner of the mark. The
  question loses its "Claude:".
- The body is the thing itself, from the request's detail when the Mac sent
  one (`ApprovalContent`): a payment's card, address and total as the Mac's
  pay sheet has them; one mail as paper with Show All; several as rows;
  files as their pages; a message as its bubble; a sign-in's accounts as
  rows, each a yes. A Mac from before sends only lines, and those show.
- The button says the action ("Pay $42.10", "Send All 3", "Archive 14")
  with the mark of how this iPhone proves it's you (`ApprovalProof`: Face
  ID, Touch ID on an iPhone SE, a lock where only the passcode is set). ×
  or the tray pulled down past a third is the no. A tap on the page behind
  answers nothing.
- Reading: a row or the paper grows where it lies into a window under the
  status bar; sideways goes to the next item; down from the top of its
  words folds it into the row of the item open now. A file's page grows
  full screen out of its thumbnail. "N more" opens the rest as a step.
- A payment: the card row opens Pay With, the address row Ship To, each
  ending in Add Card… or Add Address… (forms with iOS AutoFill, riding on
  the keyboard). A card or address typed here goes up as an account `card`
  or `address` record before the answer names it (`AssistantWallet`).
  After the yes the button says Paying on the site, then Paid with the
  order or the red row and Payment not completed, from the Mac's
  `assistantresult`; when the Mac asks again, Try Again.
- Done, the tray shrinks into its head: its top comes down, the body fades,
  and the line under the name becomes what happened ("Paid · $42.10", "Sent ·
  October update") with a green tick where × was. A second later it goes down,
  the way it came. Never into the Dynamic Island: a Live Activity of ours
  doesn't show while Yab is in front, and a drawn one lands on the music's. A
  question answered on the Mac while open says "Answered on Mac" there.

### Motion

Every moving number is a `SpringValue` stepped each frame (shares through
`UnitSpring`, in thousandths, so they rest on their targets), so a tap or a
finger in the middle of a movement carries on from where it is. The springs
are named in `ApprovalMotion.swift`: Yab's trays' for the tray (8 from the
screen, r38), Amber's (meta-agent `DeckMotion.window`, `PictureViewer.open`)
for the window (0.5 / 0.86) and a page (0.42 / bounce 0.12). The window is
laid out, hidden, a moment after the tray has risen and builds only the
pages next to the one in view, so a tap moves it without building it. A
drag picks up from where the piece is when the gesture is recognized. Under
Reduce Motion the tray, the window and a page cross-fade in 0.2 s.

### Proof

- `ApprovalTrace` (debug, `YAB_APPROVAL_TRACE=<path>`) writes each piece's
  rect and opacity every display frame.
- `Phone/UITests/ApprovalMotionTests.swift` makes every path with a finger
  (rise, pull short, swipe away, a row into its window and paging, folding
  into another row, interrupting both ways, scrolling then pulling, a
  page from the window and from the tray, the payment's steps, Add Address
  on the keyboard, paid into its head, Touch ID) and fails on a piece
  whose speed spikes between two frames, one that pops in or out anywhere
  but over its counterpart, and a frame over 100 ms inside a movement.
- `Phone/Tests/ApprovalTrayTests.swift`: shaping, a drag's pick-up, shares
  at rest, the forms.
- Named states `approval.*` (`Testing/States+Approvals.swift`): each kind,
  each payment step and outcome, reading, and frames held mid-movement.
