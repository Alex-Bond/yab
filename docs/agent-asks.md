# Asks the agent should do, not explain

A person asked Grok's bot and Dia the same thing: "save this page as pdf".
Grok answered with the file; Dia answered with the steps to make it. This is
the plan for the asks of that kind Yab's agent can't do yet, so that ⌘J,
the chat and ⌘T's task give the thing itself.

Concept pages: the list of asks (artifact QjLC9ayTzTgmLUKqvevB5B), the plan
with every scene drawn (AfjrdKwnMUFVN1PiqZ9epC), the file card
(FUTYbRZ6dHjMa3XRwTa52p).

## Already done

- `save_page` (`PageSave.swift`): a page as PDF in Letter pages (printed as
  ⌘P prints it, cut from one tall PDF when printing gives blank pages), HTML,
  a web archive, Markdown, text or one PNG, into `~/Downloads/yab/<task>/`.
  `pdf` is its PDF. Commit 8d99e8bd.
- The agent's brief says to make a page a file with `save_page` and never to
  answer with steps for what a tool does; a text-only answer (⌘T's Ask)
  says in one line that ⌘↩ hands it to an agent.
- ⌘T's field takes an address followed by words ("https://… save this page
  as pdf") as a task.
- The file card under an answer, as Grok's (`ChatFileCard.swift`): the
  file's first page with its format on a colored band, its name, what is in
  it ("3 pages · 570 KB"), Show in Finder; a click is Quick Look, a drag
  takes the file out. In the chat and in the answer card at the page's foot.
- `tabs.close` among Yab's actions, beside `tabs.move` (`NativeControl`):
  "close all my YouTube tabs / my duplicates / everything older than a
  week" closes those tabs in one batch, native_context's tabs saying
  `duplicateOf` and `lastUsed`. Pinned and kept tabs only when named
  (`includePinned`); up to 50 per call, never asked first, in any mode:
  closing is fully undoable. Undo is Yab's usual one only: the corner
  notice (4 s), ⌘Z outside text and `native_undo` bring every one back
  where it stood, pinned or in its folder. Nothing is added in the chat:
  the answer is plain words ("Closed 34 YouTube tabs."), no Undo button in
  the bubble, and the chat stays as it was after an undo. The agent's
  brief sends the person's tabs there and keeps `close` for its own. `evals/close-tabs/check.py`.
- `save_file(name, text)` (`SaveFile.swift`): words the agent made as a
  file in the task's folder, no Mac access, up to 5 MB, the name cleaned
  (no folders, nothing hidden, an ending that would run something saved as
  text, never over a file: "Team 2.csv"). The card says "48 rows", "4
  events", "12 items". Was wave 1, item 2.
- `copy(text | url with title and quote | file, what)` (`AgentClip.swift`,
  `ChatCopied.swift`): the clipboard, rich for a link with a title, a
  `#:~:text=` address for a paragraph, the file itself for one of the
  task's folder. Under the answer, in the chat and the answer card,
  "Copied · 14 addresses" and Copy Again ⌘C, nothing changing size. Was
  wave 1, item 3. `evals/agent-made/check.py` runs both through the real
  MCP server with a stand-in agent.

- `watch_page` (`PageWatches.swift`, docs/agents.md "Watching and
  routines"): "tell me when it drops under $200 / is back in stock / the
  order ships" from the chat at once, in one line. The agent writes the
  check once over the page's text (or its HTML or JSON); Yab reads the page
  on a schedule and runs it with no model, says the hit in a notification
  in words, ends the watch, and the tab's row says "Watching: under $200"
  until then and the value after. Stop Watching in the tab's menu or
  `watch_page` with `stop`; a check that stops reading the page wakes an
  agent once to rewrite it. `PageWatchTests`, `evals/watch-page/run.py`.

- Tables and books in `save_page` (`PageSaveSheets.swift`,
  `PageSaveBook.swift`): `format: csv | xlsx` reads the page's tables and
  ARIA grids; with more than one and no `table`, the answer lists them and
  the agent asks which, the names as choices; `table: all` makes a sheet
  each. The workbook is Yab's own (a stored zip of XML), plain numbers as
  numbers, "$4,800" and "02139" as the page wrote them, the header bold and
  frozen. `tabs: [...]` joins pages into one PDF with an outline entry each
  (or one md or txt); `reader: true` keeps only the article, laid out out
  of sight with no scripts and cut into Letter pages between its lines.
  `PageSaveSheetsTests`, `evals/save-page/check.py` (⌘J's chat, a stand-in
  agent through Yab's MCP, every file opened and read).

## Rules every ask follows

- **The result shows itself.** A file is a card, closed tabs leave the
  sidebar, a page is translated where it is. No success cards; the answer
  is one line.
- **What changes Yab can be undone.** Closing, clearing and the like go
  through `native_apply`, so the answer has Undo ⌘Z and the agent has
  `native_undo`.
- **No Mac access.** Everything is written into the task's folder only. A
  file of the person's is read only when they named it, with the same yes
  `upload` asks.
- **What can't be undone asks once.** Clearing a site's data, closing more
  than 20 tabs: a card with the number. Bypass skips it, as for everything.
- **Words, not marks.** "Copied · 14 addresses", "Watching: under $200".
- **English only.** Phrases in tests and evals are English; nothing in code
  exists for another language (Yab is an American product).

## Wave 0: measure first

`evals/asks/run.py`: every ask below given to ⌘J on a farm Mac with Claude
connected, and what came back recorded: a file, the clipboard, a change in
Yab, steps for the person (homework), or a request for Mac access. This is
"before"; each wave has to move its own rows to "done".

## Wave 1

All of it is done; see "Already done" above.

## Wave 2

Six asks. Three of them are mostly there already for a person (Site
Controls, page translation, Open on Mac): the work is giving them to the
agent through Yab's actions, so they get Ask/Auto/Bypass, `native_undo`
and Undo in the answer for free. The other three are new tools on the
machinery wave 1 built (`PageSave`, `OffscreenPage`, the task's folder,
the file card).

**Before any code:** run wave 0 (`evals/asks/run.py`) once over wave 2's
asks so each row has a measured "before", and once more at the end.

**Order:** 9 and 7 first (only actions over code that exists), then 12 and
11 (new tools, wave 1's pieces), then 10, then 8 (it needs the iPhone app
and a TestFlight-free way to test it).

### 7. "Translate this page" (and "show me the original")

- **Exists:** `PageTranslation.swift` translates a page in place with the
  system's on-device models (Apple's Translation framework), in Yab's own
  content world; Site Controls shows "Show Original" once translated, and
  the page menu has Translate To.
- **Build:** actions `page.translate` (tab, `to` a language, English by
  default) and `page.original` (tab) among Yab's actions, through
  `native_apply`; `page.original` is also what `native_undo` does. The
  answer is one line ("Translated from Japanese."); the page itself shows
  it, so no card. A language the Mac has no model for: the answer says so
  and offers Settings' download, never a web service.
- **Brief:** "translate this page" is the action, not a translation pasted
  into the chat; a question about a passage is still answered in words.
- **Done:** `PageTranslationActionTests` (the action's schema, undo goes
  back to the original); `evals/translate-page/check.py`: a French fixture
  page asked from ⌘J's chat with the stand-in agent, its words English
  after, Show Original in Site Controls, Undo back to French; shots light
  and dark. If the farm Mac lacks the French model, the eval says so and
  stops, it doesn't pass.

### 8. "Send this tab to my iPhone"

- **Exists:** Open on Mac (`SyncOpen.swift`, `OpenOnMac`): the iPhone
  writes a `send` record of kind `open` with a `url` and `space`, the
  addressed Mac takes it once and answers `taken`. The iPhone opens tabs
  from Sync (`Phone/Sources/Sync/SyncBridge.swift`). `devices` lists the
  user's devices.
- **Build:** the same record the other way. Action `tabs.send` (tab,
  `device` by id or name; with one other device, no choice). On the
  iPhone, `PhoneSync` takes `open` records addressed to it once, opens the
  tab in its space and shows a notification "From your Mac: Room for
  ambition"; on another Mac, `OpenOnMac` already does it. The answer says
  "Sent to iPhone." and turns to "Opened on iPhone." when `taken` comes
  back.
- **Not without the user:** no TestFlight upload or version bump for this;
  the iPhone side is tested in the simulator.
- **Done:** SyncKit tests for the record both ways (taken once, a second
  device ignores it); a Mac eval that writes the record and reads it back
  from a fixture journal; the iPhone side through `ios-sim` on the farm:
  the record arrives, the tab opens, the notification is posted.

### 9. "Clear this site's data" and "Turn off notifications from it"

- **Exists:** Site Controls clears a site's cookies, storage and cache with
  a card ("Clear data for notion.so?", `SiteControls.clearData`) and drops
  its push subscriptions; it also shows and changes what the site has been
  allowed (camera, microphone, location, notifications and the rest it
  lists).
- **Build:** move the clearing into one function both use; actions
  `site.clear_data` (site) and `site.set_permission` (site, which, allow |
  ask | block) beside `site.set_zoom`. Clearing can't be undone, so it asks
  with the same card in Ask and Auto (Bypass skips it, as for everything);
  a permission change needs no card and undoes. The answer: "Cleared
  notion.so's data; you're signed out there." / "notion.so can't send you
  notifications now."
- **Done:** unit tests for which records a site's clearing takes (its
  subdomains, not a lookalike); an eval with a fixture site that sets a
  cookie and asks for notifications: after the action, the cookie gone and
  the permission blocked, Site Controls showing both, Undo bringing the
  permission back.

### 10. Print, another browser, AirDrop

- **Build:**
  - `print` (tab): Yab's print sheet over the page (`Browser.printSheet`),
    the person presses Print. The agent never prints by itself.
  - `open_in` (tab, browser): the page's address in another installed
    browser (Safari, Chrome, Arc, Firefox, by bundle id), for a site that
    breaks in WebKit; only browsers that are installed are offered.
  - The file card's right-click gets Share… (the system's picker:
    AirDrop, Messages, Mail) and Print… for a PDF. An agent's "AirDrop
    this to my iPad" opens Share… for that file; the person picks.
- **Done:** unit tests for the browser list (installed only); an eval: the
  print sheet comes up over the page from the stand-in's call and cancels;
  `open_in` with a stub browser app receives the address; the card's menu
  holds Share… and Print….

### 11. "Save my thread with the bank as a PDF"

- **Build:** `mail_save(thread, format: pdf | md)`. The thread's mails in
  order, each with its head (from, to, date, subject once), its words as
  mail shows them, and its attachments listed by name at the end; laid out
  by `OffscreenPage` with the reading page's styles and cut into Letter
  pages between its lines, as `reader` does. The file goes to the task's
  folder and shows as a card. Optional `attachments: true` puts the
  thread's PDF attachments after it, an outline entry each.
- **Done:** `MailSaveTests` with a fixture thread (heads, order, quoted
  text kept as mail shows it, remote images not fetched); an eval in a
  mail fixture world: ⌘J in mail asks, the file has every mail's words and
  the outline lists the attachments.

### 12. Files without Mac access

- **Build:** `convert_file(path, to: jpg | png | heic | pdf, max_bytes,
  max_side)` and `merge_pdfs(paths, name)`. ImageIO and PDFKit; a copy in
  the task's folder, the original never touched. What may be read: files in
  the task's folder, this task's downloads, and a path the person named,
  with the same yes `upload` asks. Then `upload` gives the result to the
  page. "Smaller than 2 MB" tries quality, then size, and says what it
  came to ("1.6 MB, 2480 × 3508").
- **Done:** unit tests (HEIC to JPG keeps orientation, a size limit is
  met or the answer says it can't be, merged PDFs keep their pages and get
  an outline); an eval: a HEIC fixture converted and uploaded to a fixture
  form that checks the type and size.

### The same for every item

- English only, in code, tests and eval phrases.
- Each lands with its docs (docs/agents.md's tools, this file's "Already
  done") and on local main, not pushed.
- Checked on the farm in a built Yab through ⌘J's chat with the stand-in
  agent, every result opened and read, shots looked at, light and dark.

## Not doing

- Bringing a page back later ("remind me to read this tonight").
- Reading an article aloud.
- Pausing a site until a time.
- Downloading every image or file from a page.
- Downloading videos from YouTube, solving CAPTCHAs, buying without a yes,
  changing a site's password on its own.
