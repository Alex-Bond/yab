# Yab Wrapped

What Yab did for you over the last 100 days (or since you started, if
sooner) and how much time it gave back, played as an old arcade machine. In
December and the first week of January it is the calendar year's instead:
the period reads "2026" and everything counts from January 1.
It plays over the browser window, never in a window of its own: the window
goes dark behind, the arcade rises into its middle, Esc or a click on the
dark closes it. ⌘T asks for it only while a moment is due and not yet
played: "Yab Wrapped" by name, and a row at the top of the empty field's
Now ("Yab Wrapped · Your first 100 days", "Your 2026", ↩ Play). The moments:
the 100th day since the diary's first visit and the three after it, and the year,
from December 1 to January 7. The 100th day is let go when its four days
touch November 17 to January 7: then there is one Wrapped, the year's.

The year's is dressed for the new year: snow falls instead of stars, a
garland blinks across the top, the first screen has the year big with a
tree and a gift ("INSERT GIFT"), and CONTINUE? becomes the countdown to the
next year, "2027 IN 9", ending in pixel fireworks and "HAPPY 2027!". The
card to post has the snow and the garland too. A moment needs three levels; with fewer it is
not offered. Yab never opens it on its own.

Code: `WrappedStory.swift` (the rules), `WrappedTally.swift` (the numbers),
`WrappedLedger.swift` (what nothing else keeps), `WrappedArcade.swift` (the
screens), `WrappedPixels.swift` (the 5 by 7 font, sprites, grid),
`WrappedTube.swift` (the CRT pass in Metal), `Wrapped.swift` (the layer
over the window, the moments, keys, the card). Tests: `Tests/FastTests/WrappedTests.swift`.

## The story

Screens, in order: INSERT COIN, the levels from the smallest to the biggest
with bonus stages between (one after every second level), the biggest as the
BOSS level, HIGH SCORE, NEW ICON UNLOCKED, CONTINUE?.

Keys: → or Space next, ← back, a held click pauses, S opens the card to post,
W wears the Arcade icon, R plays again, Esc closes. Clicks on the left third
go back. Under the tube a strip says the same with buttons. Reduce Motion
stops the flicker and the roll and lands every count at once.

The picture is a 180 by 320 grid of square pixels drawn on the CPU with our
own font (no font file), put through one Metal pass: the glass bulges, each
grid row is a scanline, red and blue sit a hair apart, light bleeds, the
edges fall dark, a roll runs down at each screen change. It draws only while
it is up.

## Only what you did

A level exists only above its floor: 20 minutes saved. At most 7 levels and
3 bonus stages. Fewer than 3 levels and there is no Wrapped yet: the arcade
says how many there are and that it counts on this Mac only. Nothing you
never touched shows as a 0.

## Time saved

Careful constants, rounded down to the minute; every level shows its HOW?.

| Level | Counted from | Saved |
|---|---|---|
| AGENT | tasks finished (ledger, plus chats still on disk from before it) | the tasks' working time, at most 90 min a task |
| ASK (⌘J) | answers on a page, the page's words when it finished, the answer's words (ledger) | (page words − answer words) ÷ 250 a minute |
| MAIL | threads archived by hand (mail's `acts`, kept 60 days), senders unsubscribed (`unsubscribed`) | 2 s a thread, 30 s an unsubscribe |
| FORMS | fields Yab filled (ledger) | 3 s a field |
| VIDEO | video and audio played on pages faster than 1× (`WrappedWatch`), unmuted, never in a private window | the minutes the speed took off: played time minus real time |
| TABS | ⌘T jumps to a tab already open (ledger) | 3 s a jump |

Bonus stages, never counted as time: CODE AGENTS (calls from the `yab`
command and MCP, the most used verb), INVADERS (ads and trackers blocked),
NIGHT SHIFT (tasks finished before 7 in the morning), SLEEPY TABS (memory
freed; not yet measured, so not yet shown), BINGE (hours of video and audio
played, and how much of it faster), TAB HOARD (the most tabs open at once,
a day's peak), SEARCHES (searches from the field), CALLS (calls joined in Yab),
HANDOFF (not yet recorded), STREAK (days in a row with a visit, the busiest
hour, from the diary), BOOSTS (boosts kept or turned on), CO-OP (friends who
joined with your link).

## Who you are

Wrapped tells who the player is and what they handed off; the time back
is the arcade's score at the end, not the headline. A level counts what
was done (tasks handed off, answers, mails cleared, fields filled, minutes
watched faster, jumps to an open tab) and says the time back under it,
smaller: "~ 18 HOURS BACK". HIGH SCORE is "ABOUT 37 HOURS BACK".

After the coin, YOUR RHYTHM: a bar an hour from the diary's visits, the
peak hour gold, the longest run of days. Skipped when the diary has none.

Before the score, CHARACTER SELECT (`WrappedCharacter.swift`): the cursor
runs a 4 by 3 grid of types, slows and stops on the player's; then the
type's line, four bars and "WITH A DASH OF" the next type. Each type has a
floor; its strength is the player's number over it. The strongest past its
floor wins, the next past its own is the dash; no one past a floor is THE
REGULAR. Bars are strengths as 1 to 10 (the floor 6, twice it 9). Nothing
is compared with other people.

| Type | Floor |
|---|---|
| THE DELEGATOR | 50 tasks handed off, and the agent 40% of the time back |
| NIGHT OWL | the peak hour 22:00 to 03:00, or 10 tasks done overnight |
| THE CLOSER | never more than 12 tabs open, 500 tidied |
| THE HOARDER | 60 tabs open at once |
| THE SWEEPER | inbox zero 10 times |
| THE ASKER | 300 ⌘J answers |
| SPEEDRUNNER | half of 10 hours of video faster than 1× |
| THE BINGER | 100 hours of video |
| THE BUILDER | 1,000 calls from coding agents |
| AUTOPILOT | 2,000 fields filled |
| THE STREAKER | 60 days in a row |
| THE REGULAR | no one else past a floor |

The card to post is the character's: the type big in its color, its line,
the dash, "~37H BACK" in gold, the four bars, the invite link. The sheet's
switches leave out the hours or the second type. The post reads "I'm The
Delegator in Yab Wrapped: 212 tasks handed off. About 37 hours back."

## Sounds

`WrappedSound.swift`: the arcade's sounds, synthesized when first played
(square and triangle waves and noise, no files): a coin on INSERT COIN, the
tube's roll at each screen, ticks while a number counts, an arpeggio on LEVEL
CLEAR, the boss's siren, zaps and pops for the invaders, CHARACTER SELECT's
steps on the cursor's own clock (`WrappedArcade.select`), a chord on landing,
a blip a bar and a sparkle for the second type, a fanfare on HIGH SCORE, a
power-up for the icon, a tick a second on CONTINUE? and GAME OVER, fireworks
in the year's. Quiet (`WrappedSound.volume`), only while the arcade is up,
the first after the person's own Return. M or the speaker in the strip turns
them off and they stay off (`wrapped.muted`). The sheet of them, as WAVs, is
in `work/visualizations/yab-wrapped-sounds/`.

## The ledger

`WrappedLedger` keeps a few numbers a day in `wrapped.json` in Yab's folder,
400 days, written a few seconds after the last add. It is fed where things
happen: `Agents.finish` (tasks, night, ⌘J), `Tab.formFill` (fields),
`MailEmpty` (inbox zero), `Shield.blocked` (ads), `Calls.captureChanged`
(calls), `Bench.handleBound` (agents' calls, not in a development build),
`Browser.tidy` and `Browser.sleep` (tabs), the field's switch to an open tab
(jumps), `Floater.lift/drop` (picture in picture minutes), `WatchRelay` (media
played on pages: a script in Yab's world in every frame counts seconds
played and, above 1×, the real seconds they took, and posts the numbers once
a minute of play is in or as the page goes), `Browser.tabs` (the day's
peak), the field's search offers (searches). Counting started
with this build: until it has a while behind it, a Wrapped is mostly the
diary, mail and the week of chats.

## Privacy

Everything is counted and drawn on the Mac; nothing is sent. No site names,
mail subjects, people or page titles appear anywhere in Wrapped, on screen or
on the card.

## The card to post

16:10, drawn on a 400 by 250 grid and exported at 3200 by 2000 through the
same tube with less bulge: the character card (see "Who you are"), the
initials (three letters, editable, kept) and the period over it, the invite
link from Invites at its foot, so friends who join count toward friend
icons, and the Arcade icon in the corner once unlocked. Copy
Image, Save…, Post on X: X's post page can't take a picture from a link, so
the picture is copied first and the sheet says to paste it.

## The Arcade icon

`AppIconStyle.arcade` (`Icon/Alternates/15-arcade.png`, compiled by
build.sh like the other alternates). Locked until Wrapped reaches NEW ICON
UNLOCKED (`wrapped.finished`), and until then App Icon doesn't list it at
all: the prize is a surprise, never a locked tile that points to a game you
can't start.

## Checking it

`bench wrapped` with `world` ("rich", "light", "new") draws every screen and
the card into `dir` as PNGs through the tube; `open: true` puts the arcade
over the browser window on that world; `due` with a title pretends a moment
is due, for ⌘T's row. `evals/wrapped/shots.py` takes them all.
