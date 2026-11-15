# Purchases

What you pay for and have coming, read from the mail kept on this Mac:
subscriptions with their monthly total, orders on the way, and receipts.
The one thing only a browser adds is whether you use what you pay for:
"Not opened in 41 days" beside the price comes from History. Concept and
every state: [prototype](prototypes/files-purchases-2026-10-21/prototype.html),
published at https://claude.ai/artifact/PSpTWg3EnDCwjxrDtenRMP.

Code: `MailCore/MailPurchases.swift` (one mail read as a purchase,
subscriptions and orders from many), `MailStore.purchaseCandidates`,
`Purchases.swift` (reading every account, the Now row, the agent's words),
`Places.swift` (`purchaseItems`, `purchaseActions`), `PlaceViews.swift`
(`purchaseFacts`), `AgentBenchShelf.swift` and `McpToolsShelf.swift`.

## Where it is

- **Cmd+T, type purchases** (or subscriptions, orders, receipts): the
  Purchases place, offered once a mail account is connected. Its filter
  steps Subscriptions, On the Way, Receipts.
  - Subscriptions: the monthly total in the heading ("Subscriptions · $216
    a month", a yearly plan counted as its twelfth, in the currency most of
    them are charged in), then each with its price, card and next charge;
    one not opened in a month says so first and wears Unused. Canceled
    ones come last under Ending, with the day they end.
  - On the Way: Today, Coming Up, Delivered (two days), with the carrier
    and when it arrives. ↩ opens the carrier's tracking page.
  - Receipts: by day, with what was paid and the card. ⌘O shows the mail.
- **Now**: one row the day before a subscription you haven't opened in a
  month renews: "Figma renews tomorrow", "Professional, $180 a year · not
  opened in 41 days". Never more than one a day; Ask Again Next Year keeps
  that merchant quiet for 330 days; Don't Show Things Like This turns all
  of them off (Noticing.Kind.renewal).
- **Ask in Cmd+T**: a question about spending, subscriptions, orders or
  deliveries gets what Purchases knows as context, while agents may read
  the person's mail (Mail you hand to Claude).

## Do It: Don't Renew

Do It on a renewal row, or on a subscription in the place, hands it to the
agent: open the merchant's billing page in its own tab, signed in as you,
find where the plan is canceled or auto-renew turned off, and stop at the
last button. That button asks: "Cancel subscription", "Cancel plan",
"Turn off auto-renew", "Don't renew" and the like are among the presses
that wait for your yes (AgentPermit's `commits`), as Pay and Delete do.
The agent never pays, never changes the plan, never types a card.

## Reading mail

`MailStore.purchaseCandidates` gives robots' mail of the last 400 days
whose subject or snippet names a receipt, an order, a renewal or a
shipment; `MailPurchases.read` makes each a purchase or nothing (a
person's mail and promotions never are). Mail older than 30 days is kept
by its headers, so an old receipt is read from its subject and snippet.
Read every ten minutes at most, counted from when the last reading ended,
off the main thread; each subscription's site is looked up once in the
diary (`AgentHistory.lastVisits`). Each mail is read once: what it read as
is kept by its id, account and size in `purchases-read.json` (per build),
so a refresh or a launch reads only mail that is new or changed. Reading
all 400 days every time kept a core busy without rest on a Mac with two
big accounts (2026-10-25).

## For agents

`purchases` (kind: subscriptions | orders | receipts, query): the same
lists in words, each with its mail as `account|thread` for mail_read. It
asks as mail reads do (`mailAsks`).

## Testing

`Tests/FastTests/MailPurchasesTests.swift` (reading mail),
`Tests/FastTests/PurchasesTests.swift` (the row, the place, the words).
