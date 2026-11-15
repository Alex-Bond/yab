# A new tab's rows

What an agent found worth your while in the places you use, as a few quiet
rows under a new tab's field: an offer waiting on an answer, a meeting in
half an hour, a charge that failed, a trial that starts charging tomorrow.
Code: `Sources/Fast/AgentHints.swift` (rows, look, prompt), `Landing.swift`
(opening a page at its words), `NewsDot` and `PlusNews` (the dot on New Tab).

## When Yab looks

Once you take the new tab's row "Keep an eye on things for me", and with
Claude Code or Codex installed, Yab starts a quiet agent session, "Looking",
when you come back to it:

- the first time since five this morning (before five is still the night
  before), or
- after three hours away and three since the last look.

Nothing shows while it looks, and nothing when it finds nothing: a new tab
stays a new tab. One look at a time; a look silent for ten minutes is
stopped so the next can start. Routines and watches for a reply hand
their findings over the same way, a routine's rows saying its name
(docs/routines.md).

The look reads `history` and memory, visits the places that matter in tabs
of its own, reads without marking anything read or answering, and calls
`suggest` once. It is told the rows already up and says which are dealt
with (`resolved`) and which still wait (handed back by `id`). It may hand
back six things, most urgent first, and subscriptions besides them.

A quiet session is refused `sign_in`, `handoff` and `ask`: nobody is there
to answer, so a place that wants a sign-in is skipped.

With Yab's Mail connected there is also a short look, "Glancing", at new
mail alone: when the Mac's model finds a person's new mail waiting on you,
the agent reads only those threads (`mail_read`, which marks nothing read)
and hands back a row with what they want and a drafted reply, or puts the
thread `quiet`. Half an hour after the last look or glance at most, eight a
day, each thread once for each new mail in it, effort low. A glance never
counts as the morning look (`agents.watched` stays).

## Mail

A row about mail must hold when the whole thread is read. Three layers make
it, each above may rewrite or remove what the one below said:

- **Rules** (`MailCenter.noticed`) say only hard facts: a day named in the
  mail, a bill past due, your own promise with a date (`MailPromise`, "before
  Jan 4" being Jan 4), someone not answering you.
- **The Mac's model** (`MailSense`) reads each person's mail with your own
  last words in the thread before it, says whether something is still
  open, and its no stands: a bank's "Was this you?" asks for a button, not a
  reply. The line is grounded in the sender's own words, never the mail
  they quote. A "waiting on your reply" row needs the model's reading (the
  rules alone only on a Mac without it), the mail unread, and comes at once
  in a thread you wrote in, after four hours from someone new.
- **The agent** reads people's threads too: in the look through
  `mail_triage` and `mail_read`, or in your mail site in a tab when Yab's
  Mail is not connected (Gmail, Outlook, Superhuman or any other). It hands
  back what still waits on you, in words of what they want, with a draft,
  and names threads it read that wait on no one in `quiet`, which keeps
  their rows away until new mail comes in them.

In a mail site the look leaves every message as unread as it found it: it
reads lists and previews, opens a message only when its preview can't tell,
and marks an unread one unread again before leaving it, then checks the
list. The morning eval counts what is left read.

A mail row goes without a word once you reply in the thread or read the
mail; an agent's row about a thread of Yab's Mail too. Only what was dealt
with without you (a look saw it `resolved`) draws its tick.

## What a row carries

From `suggest`, each item: `title` and `detail` (one line each, in the
language of the thing itself, no long dash), `kind` (its picture), `url` and
`site`, and when they apply `quote` (words to land on), `due` (ISO 8601),
`join` (a call link), `draft` (a reply written as you), `subscription`
(`trial` or `renewal`) with `service` (the service's own site).

Kept in `hints.json` in the world's folder, with what you did to each row:
when it was opened (`seen`), put off (`snooze`), dealt with (`done`), last
confirmed by a look.

## What Yab decides

- **Which rows may exist.** A row's link must lead to a host you have
  visited in the past year, here or in the other browsers brought in from
  (`OtherHistory`; a message
  can't put "Verify your bank" on the new tab by asking the agent). A Join
  must be a call's link. Anything else is dropped.
- **One row per thing.** The same place written differently (www, a slash
  at the end, tracking parameters, Gmail's `#inbox/ID` and `#all/ID`) is
  one row; a thing handed back by its id keeps its row and what you did to
  it.
- **How long a row lives.** A day from the last look that confirmed it; a
  meeting until a quarter hour after it starts; a deadline gone by for as
  long as a look still says it is owed; a row dealt with only until it has
  been seen going.
- **When a row shows.** Put-off rows wait for their time. A trial shows the
  day before it charges; a renewal three days before and only if the
  service was not opened in a month, judged by its name on any host
  (notion.so and app.notion.com are notion.com). A subscription with no
  date waits.
- **In what order.** What is due within two hours or began a quarter hour
  ago first, nearest first; then a task done, a link just copied; then what
  an agent found due in the next day and a half (a dispute to answer
  tomorrow, a party tonight), nearest first; then mail that waits on you
  (an answer to you before someone new); then the rest of the look's
  order; habits; a routine offered last. One row a thread: the agent's
  over Yab's own. Four show; the rest wait their turn.

## What you see and do

- **Arrival.** Only new rows come in, out of a blur; rows already standing
  keep still. Found while you were on a page: a small dot on New Tab, in
  the column and by the row's plus, gone once a new tab has shown them.
- **Opening a row.** The page opens in the tab you are on, at the row's
  words: Yab looks for them itself in its own world, case, accents, white
  space and a closing stop set aside, falls back to the longest run of the
  quote's words on the page, scrolls there unless you have already scrolled
  or touched the page, and marks them for a second and a half with the
  system's highlight, painted with a constructed style sheet so a page that
  allows no inline styles still shows it. It stops if you leave the page.
  The row stays, its picture paler.
- **Time.** A row due soon counts down by the minute; ten minutes before a
  meeting it offers Join.
- **Drafts.** A row with a drafted reply writes it into the page's reply
  box the first time it opens, as ⌘J drafts; you send it.
- **Subscriptions.** A subscription's page offers Cancel subscription: the
  agent goes to the last step, turns down any offer to stay (a discount is
  a purchase), and leaves the final button to you.
- **The row's menu** (right click): Open, Later Today (five, or three hours
  on after four), Tomorrow Morning (nine; before five, this morning's
  nine), Done (a tick, and it folds away), Don't Show Things Like This (a
  line in `hints-rules.txt` the next look reads: the row's kind and site
  with its words, "mail from acme.com, like: Acme wants an answer by
  Friday"). The × puts it away for good, and the look is told what was
  put away in the last two weeks (twenty at most, `hints.removed`) so it
  doesn't bring the same thing back under another link.
- **Rows of Yab's own** (mail that waits on you, Archived Today, a meeting
  about to start, a copied link, a finished task) have the field's menu:
  Open, Not Today, Done, then Don't Show Things Like This, which turns off
  the row's kind (`Noticing.Kind`) for good. On a mail row it is a submenu:
  Mail from Anna (that address) or the kind for everyone ("Anyone Waiting
  on Your Reply", "Anyone Who Hasn’t Answered", "Mail Due Soon", "Bills
  Past Due"). The field over a page offers the same two. What is turned off
  lives in `hints.off`, is told to the look in words ("mail from
  anna@acme.com", "mail where someone is waiting on the user's reply") so
  it doesn't bring it in its own, and is listed in Settings › Tabs under
  Suggestions under the field, each with Show Again; Mail that needs you
  there turns off every mail row at once. A habit's Don't Suggest This
  keeps its place in `hints-habits-off.txt`, never in a prompt, listed
  there too.
- **A mail row's ×** puts away that thread until new mail comes in it
  (`hints.mail-aside`, the time of its last mail then); it is not kept
  among the found rows' two hundred, so it isn't pushed out.
- Clear History also clears what agents found (`hints.json` and the rows
  kept for new tabs); what you asked not to be shown stays.

## Why it is this way

- **A row lives until the thing is done, not until it is clicked.** A
  click that took the row away lost what was opened and then left.
  Opening only pales its picture; the detail stays, being more use than
  "Opened 9:14", and the time opened is in the row's tooltip.
- **No loading, no status.** The look takes minutes; showing it would be
  noise on the most frequent path. Only arrivals move.
- **No Text Fragments** for landing: a `#:~:text=` stays in the address, the
  history and a copied link, and does nothing on pages built by script
  (Gmail, Slack). `Landing.swift` finds the words itself, several times
  over about six seconds while the page fills, and marks them with the CSS
  Custom Highlight API without touching the page's nodes.
- **Six, not four.** Told to hand back exactly four, the agent in the eval
  dropped a meeting 35 minutes away for a trial. `due` is required when
  there is a date ("by Friday" is Friday at five), and a meeting's link
  comes from its event page.
- **Rules, not memory.** Don't Show Things Like This writes to
  `hints-rules.txt`, which the look's prompt reads; memory is untouched.
- **Subscriptions are rows** in `hints.json` with a `subscription` field
  waiting for their window, not a store of their own. Their `url` goes
  where the plan is canceled when the mail links there.
- **A draft** goes in through `Agents.write`, as ⌘J does, and the draft
  card's Send stays yours.

Measured with `evals/morning` on Opus after the fixes: 61/62, 62/62, 62/62,
a look in 75 to 100 s. On Codex 0.157: 62/62 twice, 118 to 135 s, once Yab
approved its own tools in Codex itself. The one known miss: the agent
quotes from a list of payments and links the payment itself; Yab still
marks the longest run of the quote found on the page. What the eval found
on the way: no `due` or meeting link given "where you can"; a second look
checking old rows and finding nothing new; a quote with glued words
("Northwind$240.00"); dates without seconds unread; a test world's
`history` reading the real browsers on the Mac (hence `YAB_HISTORY=own`).

## For tests

Bench verbs, test runs only:

- `agent-look` starts a look now.
- `agent-suggest` hands over items as a look would.
- `agent-hints` returns the rows drawn, everything kept, what would show
  but for the four (`eligible`), and a `journal` of arrivals, ticks and
  refusals. It can move the rows' clock (`clock`, `reset`), start the world
  over (`forget`), and remove rows (`drop`).
- `agent-hint` takes a row, or one of its menu items (`later`, `tomorrow`,
  `done`, `never`, `x`, `join`).
- `agent-landing` says where the last row's page landed.

How to test all of it end to end: [agent-evals.md](agent-evals.md).
