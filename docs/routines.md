# Routines

A task that comes back on its own while Yab is open: "every weekday at
9:00, check my mail and my Linear issues for anything that needs me".
Code: `Sources/Fast/Routines.swift` (the model, runs, words),
`RoutineSettings.swift` (Settings › AI › Routines, the editor, Run
Regularly…), `Places.swift` (the Routines place), `AgentTask.swift` (a task
typed with its when).

## Where one is made

- **Settings › AI › Routines.** A table in Commands' language: each
  routine's name and what its last run came to in words ("Ran at 9:02 · 2
  things for you"), how often in a cell with a menu, its model in another,
  the rest under `···` (Edit…, Run Now, Open Chat, Turn Off, Duplicate,
  Delete). New Routine… and a click on a name open the editor.
- **The editor** is Commands' sheet: the prompt down the left, with the
  tabs it works in over it (`+ Tab`: the tabs you have open and the sites
  you use most); down the right its name, when (see "The editor's
  Repeats" below), a command to run instead of a
  prompt, the model and effort, what it may do (Only Read, the default;
  Ask Before Acting; As Agents Settings Say) and Tell me (Quietly, in ⌘T,
  the default; When It Finds Something; Every Time). Try Now runs it once
  as it stands, saved or not. The prompt takes `{since}` (since its last
  run), `{date}`, `{tabs}` and `{memory}`.
- **Run Regularly…** under a command's `···` in Settings › AI › Commands,
  for the ones that mean something on a page with nothing selected
  (`SelectionCommand.runsOnPages`: not the rewrites of your own text):
  a card with the page it runs on and when.
- **Suggested from your history**: up to three routines for the sites
  opened five times or more this month, here and in the other browsers
  brought in from (`RoutineIdea`, `OtherHistory`); with none of those, one for anyone. Add sets one, ×
  puts it away for good. With no routines yet, the commands that can run
  on a page are offered too.
- **Repeat…** under an answer in a chat: the same words at this hour of the
  day from now on (every weekday, every day, this weekday, every hour), or
  Custom…, the editor filled in. The sites the chat's tabs were on come
  along.
- **Words that start with when**: a task typed in ⌘J, ⌘T or a new chat as
  "every weekday at 10 tell me which of these wait on my review" is a
  routine on the tab it was asked on, not a task now
  (`Routines.phrase`). It has to be meant: a time said, a comma after the
  when, or a verb first; "every day I read the news" stays a task.
- **A terminal**: `yab every "weekdays 9:00" "…"`, or any of the words
  under "When" (`yab every "first monday 9:00" "…"`, `yab every 3 days
  9:00 "…"`: the most words that read as a when, `every` allowed to lead).
  `yab every list` says each one's row ("Off", "Ran at 9:02 · nothing
  new"); `yab every run|pause|resume|remove ID`. Run while a run of it is
  going, the one going is the answer: never a second turn in its chat.
- **The new tab** still offers one once a week from the morning's look.

## A run

A routine's runs are one chat, each after the last. A run is a task in
that chat (`session.task`), so it looks like any task in tabs of its own:
its tabs a folder in the column while it works, its progress in words. Its
agent starts each run afresh (the CLI's thread is dropped) and is told
what it said the time before, so a routine run for months costs what one
run does and doesn't repeat itself.

It hands what the user should see to `suggest`; those rows say whose they
are ("Morning check · …") and are counted as the run's findings. It
leaves open only the pages of what it found, four at most, and ends with a
`# ` line saying what needs you, or only `Nothing new.`

When the run is over (`Routines.finished`):

- **Nothing new**: nothing stays. Its tabs close, its chat is read, no row.
- **Something**: its answer is in its chat; ⌘T's Now has what it found;
  its chat is unread, "new" after its name in the chats' list until
  opened, as the Routines place says it. A notice's Show opens the chat.
- **Couldn't finish**: its row says so, and why when its last line says
  ("couldn’t finish: plan out of room", "sign in again", "connection
  dropped"); its chat is unread. A notice only if it asks for one.
- **A notice** only if it asks for one (Tell me): the corner plate while
  Yab is in front, the Mac's notification when it isn't; Show opens the
  answer.

## A folder it keeps

A routine with **Keep what it finds in a folder** ticked (the editor's last
line, under Tell me) answers each run with a folder rather than in its
chat: "every hour, one-bedrooms in the Mission under $4,500, price at each
row". Code: `Routine.folder`, `Routines.folderWords`, the `folder_update`
tool, and the folder itself is a live folder whose source is `routine`
(`LiveFolders.keep`, docs/live-folders.md), so it keeps tabs the way they all
do: what comes in comes asleep at its top, it only ever takes away what it
brought, a tab of yours in it stays, one taken out by hand isn't brought
back.

- **Made** from the editor's tick; from Repeat… under an answer, whose
  menu ends with "Keep the 4 Tabs Up to Date" (on by default for an answer
  with tabs; the chat's pages are the folder's first); or from a folder of
  yours, its menu's Keep Up to Date…, the editor filled in with its pages
  and the tick on, the folder its once saved.
- **A run** is told what the folder holds, each page with its words, and
  hands back with `folder_update` all that belongs now, best first, twenty
  at most: a url, a title, and one to four words for the row's end (a price
  and its change, a date, "New"). `loud` marks what needs a look; a page
  that no longer belongs is listed once more with `gone` and its reason
  ("Rented"), drawn struck and faint until the next run lets it go. It
  calls no `suggest` and closes its tabs.
- **Nothing inside the folder but its tabs.** Its row alone says anything:
  Checking while a run looks (its face reads), "1 new" shut when something
  loud waits unopened, nothing otherwise. When it ran and what came of it
  is said where every routine's is: Settings › AI › Routines and the
  Routines place, its line starting "Folder ·".
- **Tell me**: Quietly is only the words; When It Finds Something adds the
  corner's "Mission 1BR: 2 new" with Show; Every Time, after each run.
- **Its menu**: Update Now runs it, Edit Routine… opens the editor, Stop
  Updating leaves a plain folder of yours and turns the routine off.
- Try Now in the editor fills the folder as a run would.

## Where you find them

- **⌘T, Now**: what the runs found, each row the thing itself.
- **The column**: a run's folder, while it works and after it found
  something, put away fifteen minutes after you last looked.
- **⌘J's chats**: one chat per routine, unread until opened.
- **The Routines place** in the field (type "routines", Tab): each routine
  with how often and what it came to last, running and new ones first;
  the preview has what it is told and its last answer. ↩ opens its chat;
  ⌘K: Run Now, Edit Routine… ⌘E, Turn Off, New Routine… ⌘N, Delete ⌃X.

## When

A routine's when is kept as words (`Routine.when`), the ones the CLI,
agents and sync read; `Routines.schedule` reads them, `Routines.words`
writes the editor's, `Routines.say` says them ("Monthly on the 1st at 9:00
AM"). All on this Mac's local time (the Gregorian calendar in its time
zone); there is no time zone of a routine's own.

| Words | Runs |
| --- | --- |
| `daily 9:00`, `weekdays 18:30`, `weekends 10:00`, `mon,thu 8:15` | those days at that time |
| `daily 9:00,18:00`, `mon,thu 8:15,17:00` | several times a day, any of the forms with a time |
| `monthly 1 9:00`, `on the 1st 9:00`, `15th 10:00` | a day of the month; 29 to 31 run on a shorter month's last day |
| `monthly last 18:00`, `last day of month 18:00` | the month's last day |
| `first monday 9:00`, `last friday 17:00` (`second`, `third`, `fourth`, `fifth`) | a weekday of the month; a month without a fifth has none |
| `every 3 days 9:00`, `every other day 9:00` | every so many days, counted from the day of its last run |
| `every 2 weeks mon 9:00`, `every 3 weeks mon,thu 9:00` | those days of every so many weeks, counted from the week (from Monday) of its last run |
| `yearly oct 6 9:00`, `every oct 6 9:00`, `oct 6 9:00` | a date each year; Feb 29 on Feb 28 in other years |
| `hourly`, `every 2h`, `every 30m` | a gap from its last run, a quarter of an hour at least |
| `on open`, `on mail <split>` | once each time Yab opens; each mail that comes to a split |

Everything that read before reads the same (`RoutineScheduleTests`).
Gaps of days and weeks count from `last`, so Run Now or a changed when
starts their count again, as `every 2h`'s does. A time the clocks skip
when they go forward runs the moment after; one they repeat runs once.

**The editor's Repeats**: Every Day, Weekdays, Weekends, Weekly… (a chip
for each day), Monthly… (On Day and the 1st to 31st or Last Day, or First
to Last and a weekday), Yearly… (a month and a day), Every Few Days… and
Every Few Weeks… (how many, and the weeks' days), Every Hour, Every 2 or 4
Hours, When Yab Opens. A kind with a time has a menu for each time of day,
`+` for another and Remove in a time's menu while there are others. Under
them, what a short month or year does with the day it was given, and the
next run in words ("Next: Nov 1, 9:00 AM"). The row's cell in the table
keeps the quick ones (Every Day, Weekdays, …) with the times it has; the
rest are the editor's.

Routines run while Yab is open, looked at every minute, never on a timer of
the Mac's. A Mac asleep or a Yab closed at nine runs the nine o'clock one
the first time it is back that day, once; one missed by more than twenty
hours waits for its next time. `on open` runs once each time Yab opens. A
routine made or given a new time is not due the moment it is saved.

## Testing

`swift test --filter Routine` covers the words (`phrase`, `say`, the
editor's menus, the rows' status, the suggestions) and the schedules
(`RoutineScheduleTests`: every old form, the new ones, next and due runs
across short months, Feb 29, a change of clocks and a missed run). Bench: `routinecard`
opens the editor (`new`, a routine's id), Run Regularly…'s card
(`command:summarize`) or puts both away (`close`); `routinevisits` hands
the suggestions a month's visits; `agent-routines` (each one's row, next
run, chat), `agent-routine-run`, `-turn`, `-duplicate`, `-remove` and
`-tick` (the minute's look, now) drive runs, `agent-routine-age` (--test)
moves its last run back as a Mac asleep through its time would, and
`routinecard` `save` saves the editor as it was opened.
`evals/routines/lifecycle.py` lives a routine through all of it with a
stand-in Claude (`routine_claude.py`): pause and resume, a missed run,
its time changed, the editor open across a run, a run that can't finish,
duplicate, delete and the terminal.
