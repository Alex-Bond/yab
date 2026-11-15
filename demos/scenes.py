"""The scenes: what each demo world opens on, and the take it is built for.

A scene is Mira's whole browser (persona.py) with a starting point: the
space on screen, the tab in front, a few settings, what to stage once Yab
is open, and the story: the beats of a 20 to 40 second take.
"""
import persona as P

W, H, L = P.WORK, P.PERSONAL, P.LISBON

SCENES = {}


def warm_music():
    """Drift's tracks are made on first need: made now, so the first Play plays."""
    import urllib.request
    try:
        urllib.request.urlopen(P.site("drift", "/audio/status.json?wait=1"), timeout=90).read()
    except OSError:
        pass


def scene(name, title, story, **kw):
    SCENES[name] = dict(name=name, title=title, story=story, **kw)


# ---------------------------------------------------------------- your ten

scene("pip", "Video in a floating window, with chapters, captions and the tuck",
      capture="app", audio=True,
      space=H, front={H: "aircAruvnKk"},
      story=[
          "The 3Blue1Brown video is in front. Press play, turn captions on (C) so the window has subtitles to draw.",
          "⇧⌘P: the video lifts out of the page into its own window, still playing.",
          "Point at it: ±15 s, the timecodes, and the scrubber cut into chapters; hover the bar for a chapter's name.",
          "Switch tabs or apps, it stays above everything.",
          "Drag it past the right edge: it tucks away to a lip. Point at the lip, it peeks; click, it comes back.",
          "Two-finger flick it to a corner. Return (or ↗) puts it back in its tab.",
          "Also: leave the tab with a YouTube video playing and it floats on its own.",
      ])

scene("island", "The player island at the foot of the sidebar",
      audio=True,
      space=H, front={H: "/station/morning-fog"},
      tabs={H: [(P.site("drift", "/station/morning-fog"), "Morning Fog · Drift"), (P.site("drift", "/station/night-swim"), "Night Swim · Drift")]},
      after=[lambda world: warm_music()],
      story=[
          "Drift is in front: play Morning Fog.",
          "Switch to another tab: a Liquid Glass island rises at the column's foot, tinted by the cover, bars dancing.",
          "Point at it: it opens into a card with the cover, progress, previous, play, next.",
          "Open the Night Swim tab, play it, switch away: a bud is born out of the island. Tap the bud to swap.",
          "Right-click the island: Pause All, Show Tab.",
          "No sound wanted? ./demo island --pretend gives two made-up players instead.",
      ])

scene("call", "A call in its own window: devices, sharing a tab, the tuck",
      capture="app", audio=True,
      space=W, front={W: "daybook.localtest.me"}, meeting_in=3,
      story=[
          "Daybook is pinned: its corner counts down to the design review (\"3m\"), then turns into Join.",
          "Click Join (or ⌃⌘J): Roundtable opens. Join now with your camera on (the first time macOS asks for it).",
          "Switch to another tab: the call floats into Yab's own window, people as tiles, a ring on whoever speaks "
          "(keep the camera on the first time: that's how Yab knows which tile is you).",
          "Back in the call, Anna can present too: her deck fills the floating window with the speaker in the corner "
          "(open the call with ?present=anna, or run remotePresent('anna') in its console).",
          "Point at it: mic and camera with their arrows, pick another microphone from the menu.",
          "Back in the call press Present: Yab's box offers Tabs, Windows, Screens. Pick Launch notes.",
          "The shown tab gets a purple frame and a \"Shown in Roundtable · Stop\" pill; the call tab says Presenting.",
          "Point at another tab: Share Instead. Then Stop. Drag the call window past the edge to tuck it, a red dot if muted.",
          "⌃⌘M mutes from anywhere. ⌘W twice leaves.",
      ])

scene("agent", "An agent doing a task in your tabs",
      space=L, front={L: "google.com/travel/flights"},
      prefs={"agents.asking": "auto"},
      story=[
          "⌘T and type: find the best direct flight Stockholm to Lisbon on my trip dates, I want a window seat",
          "Pick \"Task for Claude\": a folder appears at the end of the column with Claude's face, tabs come out as it works.",
          "Click a tab in the folder: the dark dock, Claude's cursor gliding to what it clicks. Take over ⌘. and hand back ⌘↩.",
          "The answer is a page of its own: the pick, why, a table with sources.",
          "Second take, money: \"buy the Fjord linen throw in Sand from Nordbutik and ship it home\". It fills the address and card, "
          "then stops at Pay: \"Place your order · 1 249 kr?\" and waits for your ⌘↩.",
          "On a page, ⌘J does what the page is for: on the GitHub PR (Work space) \"Review this pull request\".",
      ])

scene("cli", "Claude Code in a terminal, driving Yab",
      frame="square",
      space=W, front={W: "news.ycombinator.com"},
      story=[
          "Run the command ./demo printed (or ./demo cli --terminal opens Terminal with it).",
          "Ask: \"open the top 3 Hacker News stories about design or browsers and give me a one-line take on each\".",
          "In Yab: a folder named by Claude at the end of the column, tabs opening one by one, its face reading.",
          "Ask for something that needs you: \"sign me in to Orbit\" and Yab asks for your yes; or \"what's on my calendar\".",
          "Or one line: yab \"compare Alfama hotels under €220\" prints steps and the answer right in the terminal.",
      ])

scene("forms", "A whole form filled at once",
      space=W, front={W: "/register"},
      tabs={W: [(P.site("lumen", "/e/design-systems-night/register"), "Register · Design Systems Night · Lumen")]},
      story=[
          "The Lumen registration is in front. Click into Name.",
          "Under the box: \"Fill the form · 9 of 11 · 2 stay yours\". Press ⌥↩.",
          "Every box fills at once: green dots from the Wallet, violet from Mira's profile, and the two questions in words get drafts written for her.",
          "Hover a dot: where it came from. Tab walks only the boxes left to you (dietary, the demo slot).",
          "Consent is never ticked for you; the button gets a ring when everything required is there. ⌘Z takes the whole fill back.",
      ])

scene("checkout", "Saved cards and addresses at checkout",
      space=H, front={H: "nordbutik.localtest.me/p/"},
      story=[
          "The Fjord linen throw is in front: pick Sand, Add to bag, Checkout.",
          "Click Full name: Mira's addresses hang under it (Home, Work). Pick Home: the whole address fills.",
          "Click Card number: her cards, with what each is called. Pick Personal (Touch ID if it asks): number, expiry, code, name.",
          "Pay stays yours. A new card typed by hand gets \"Save card for next time?\" after paying.",
      ])

scene("files", "Attaching a file, and downloads that fly",
      space=W, front={W: "/expenses/new"},
      tabs={W: [(P.site("ledger", "/expenses/new"), "New expense · Ledger"), (P.site("ledger", "/invoices"), "Invoices · Ledger")]},
      story=[
          "Ledger's new expense is in front. Click Attach receipt.",
          "No Finder dialog: the field opens on Files. Now, Recent: Mira's Downloads and Desktop with previews.",
          "Type \"taxi\": the Arlanda taxi receipt from Documents. ↩ attaches it. ⌘P walks Downloads, Desktop, Documents.",
          "Switch to Invoices and click Download PDF: the file lifts off where you clicked and flies into the downloads button, a ring fills, a tick.",
          "⇧⌘J: Downloads, searchable, with Quick Look.",
      ])

scene("morning", "Morning: what needs you today, on a new tab",
      space=W, front={W: "linear.app/method"}, meeting_in=34,
      story=[
          "Press ⌘T: the rows come in out of a blur. The design review counting down, Kai who hasn't answered (from mail), "
          "a failed charge in Ledger, Anna's comments on the launch notes.",
          "Open \"Anna left 3 comments\": the page opens and the quote it found is lit for a moment.",
          "Right-click a row: Later Today, Tomorrow Morning, Done (it ticks and folds away).",
          "⌘T again later: the meeting row says Join from 10 minutes before.",
          "Settings › AI › Routines: the morning brief and the others that put rows here.",
      ])

scene("hello", "Getting to know you: \"Nice to meet you, Mira\"",
      space=W, front={W: "linear.app/method"},
      after=[{"do": "know", "action": "arrive"}],
      story=[
          "The tab at the end of the column is Yab's notebook about Mira, left by Get to Know.",
          "Click it: the pen writes \"Nice to meet you, Mira\", rings her name, the portrait fades in, sections write themselves out.",
          "Scroll: who she is, what forms get, home and work, one question to answer, how she writes, her people, what she's making, "
          "what was left alone (a post that asked agents to change her address).",
          "Answer the question, cross a line out (it zigzags), fix one by hand.",
          "To replay the writing: ./demo hello again.",
      ])

scene("measure", "Measure: rulers and guides on a page you're building",
      space=W, front={W: "localhost:5173"},
      story=[
          "Tern's site in the making, localhost:5173, the port on its tab. ⌥⌘U: rulers along the top and left.",
          "Point at the hero's button: its box and size. Click: the plate with padding, type, colors and the rules that won, "
          "each with its file; a beaten one struck through.",
          "Point at another element: the distance between them.",
          "Drag a guide out of the ruler, it snaps with a tick. ⇧↩ parent, ↩ child, ⇥ next.",
          "Click a value on the plate (border-radius 12 → 16): the page changes live. Copy for Agent takes it as Markdown.",
      ])

scene("devtools", "Developer Tools beside the page",
      frame="screen",
      space=W, front={W: "localhost:5173"}, prefs={"dev.side": "right"},
      story=[
          "Tern's dev site is in front: the band says \"2 errors\" in red.",
          "⌥⌘I: the card slides in beside the page. Errors in a console: a TypeError with its stack, a warning ×7.",
          "Network: the 401, the 500 from /api/testimonials, the 404s.",
          "Click \"Start free\" on the page: a new 500 lands live.",
          "Elements and Console are WebKit's inspector, docked in the card. ⌥⌘C picks an element.",
          "Ask in Chat sends the errors to Claude.",
      ])

scene("passwords", "Passwords, and the code from mail under the box",
      space=W, front={W: "orbit.localtest.me/login"},
      tabs={W: [(P.site("orbit", "/login"), "Sign in · Orbit")]},
      story=[
          "Orbit's sign-in is in front. Click the email box: Mira's saved account hangs under it. ↩ fills email and password.",
          "Sign in: Orbit mails a code. Click the first code box: a second later the code from mail appears under it. ↩ fills all six.",
          "⌥⌘L: Passwords in the field. Search \"git\": GitHub with a live 2FA code ticking. Tags say reused for two.",
          "Then Sign up on Orbit as someone new: once it works, \"Save password for orbit.localtest.me?\". Not now: "
          "the site's mark flies to the tab and becomes a key.",
      ])

scene("mail", "Mail: sorted by what it wants from you",
      space=W, front={W: "linear.app/method"},
      after=[{"do": "agent-mail-space", "act": "enter"}],
      story=[
          "Mail is open with both of Mira's mailboxes, work and personal: Needs you, Waiting, Other, News, each row with its status in words.",
          "J and K walk; ↩ opens a thread: the row's words fly into the letter. Esc plays it back.",
          "Jonas: three replies already written in her voice, 1 2 3. Press 1, then ⌘↩: the reply folds into Send and flies to the corner.",
          "⌘Z: it comes back. E archives, ⌘Z brings that back too.",
          "/ searches, ⌘J asks: \"what do I owe people this week?\".",
          "D hands Elliot's question to Claude, who drafts the answer and leaves it unsent.",
          "Personal: Inês asks when the flight lands; three replies are ready there too.",
      ])

scene("commands", "AI on a selection, and routines",
      capture="app",
      space=W, front={W: "paper.localtest.me/d/launch-notes"},
      story=[
          "Launch notes in Paper. Select the clumsy paragraph about focus-first scheduling.",
          "⌘J: commands at the selection, Improve Writing first. ↩: the better text streams in with its changes marked; ↩ replaces.",
          "Select Jonas's Swedish note: Translate leads. Select the rollout plan: Summarize.",
          "Right-click a selection: the top three commands right in the menu.",
          "⌘, then AI › Routines: the morning brief, Lisbon flight prices, the Friday recap, each with its last run in words.",
      ])

# ---------------------------------------------------------------- what Arc had, done our way

scene("tabs", "Arc's tabs, our way: clear to dust, folders, Peek, Split View",
      capture="app",
      space=W, front={W: "news.ycombinator.com"},
      story=[
          "Point at the line above today's tabs: Clear. Today's tabs dissolve into dust, row by row. Undo brings them back.",
          "Hold a tab over another for a moment: a folder is born. Hover a shut folder: its preview card.",
          "On Hacker News ⇧-click a story: Peek grows out of the link. ⌘O keeps it, ⇧⌘O puts it beside the page.",
          "Drag a tab over the page: Split View, the page making room. Double-click the divider to even it.",
          "⌃Tab: recent tabs as pictures. ⌥⌘N: a small window over any app.",
      ])

scene("spaces", "Spaces: color, grain and a swipe between them",
      space=H, front={H: "theverge.com"},
      story=[
          "Swipe two fingers across the column: Personal, Work, Lisbon, each with its own color, grain and tabs.",
          "⌃1, ⌃2, ⌃3 jump. Click the space capsule at the foot, then New Space.",
          "Type a name, the tray guesses the emoji and color. Color: the dot field swells under the handle; grain on its track.",
          "Create: the window wears it. Drag a tab onto the capsule to send it to another space.",
      ])

scene("capture", "Capture: a framed screenshot, secrets painted over",
      space=W, front={W: "ledger.localtest.me"},
      story=[
          "Ledger's overview is in front. ⇧⌘2: the page dims, a glass bar at its foot.",
          "Point: the outline snaps to the page's own boxes, labeled with size. ↑ takes the parent. Click the MRR chart.",
          "It lifts off to a card in the corner: framed on a backdrop, copied, its size said.",
          "Click it: the editor. Backdrop, shape, \"Hide emails, keys and card numbers\" paints the customers' emails over.",
          "Drag it into a chat, or ⌘S: it flies into downloads.",
      ])

scene("clean", "A quieter web: hide anything, reading mode, private",
      space=H, front={H: "theverge.com"},
      story=[
          "The Verge, ads already stopped before they loaded.",
          "⇧⌘H: a crosshair; click a rail you don't want. Gone, and still gone after a reload, from the first frame. ⇧⌘U lists them.",
          "Switch to Lisbon, the Wikipedia article: ⌥⌘R, the article flies into a clean sheet. ⌥⌘R again, back exactly as it was.",
          "⇧⌘N: a private tab, dark, \"Nothing here is kept\".",
      ])

scene("welcome", "The welcome: Yab in pieces, then yours",
      space=W, front={W: "linear.app/method"},
      after=[{"do": "welcome", "step": "welcome", "play": "1", "arrival": "replay", "browsers": "arc", "bring": "brought",
              "agents": "claude", "conn": "connected", "cal": "meeting", "default": "already"}],
      story=[
          "The welcome plays over the window: the smoked glass splits, \"yet another browser.\", the pen underlines another.",
          "↩ through it: Yab's parts pulled apart at real size, a sample agent run.",
          "Bring from Arc (made up for the demo, nothing of yours is read): Arc's icon flies to the pins, they pour in.",
          "Look and Color: the window re-poses, the backdrop paints. Start Browsing closes the gaps into the real window.",
          "Don't press anything that would read a real browser: this world pretends Arc.",
      ])

scene("update", "The hand-written update note",
      space=W, front={W: "linear.app/method"},
      after=[{"do": "ui", "update": "ready"}],
      story=[
          "At the column's foot a pen writes \"Yab 1.2 is here!\" with a heart, and loops the Update button.",
          "Point at it: the ink trembles. Click \"not now\": it zigzags through and takes the ink back.",
          "To see the after-update note: ./demo update --stage updated.",
      ])

scene("all", "Everything at once: Mira's browser to wander in",
      space=W, front={W: "news.ycombinator.com"},
      story=["Every scene's data is here: wander, record anything."])

ORDER = ["pip", "agent", "hello", "forms", "files", "cli", "morning", "measure", "devtools", "passwords", "mail",
         "island", "call", "checkout", "commands", "tabs", "spaces", "capture", "clean", "welcome", "update", "all"]
