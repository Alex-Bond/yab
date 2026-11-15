# Live folders, and pins that say what's new

What Arc calls its smart tabs, and how Yab gets each of them: a folder that
fills itself with your pull requests and lets them go when they're merged
(and the same for Notion, Google Drive, Figma, Linear, Jira and YouTube), a
count on a pin's corner when mail or a chat waits, a pin's card that lists
what is there (today's meetings, your pull requests, the pages you last read
on that site), players you can reach all at once, and short names for kept
tabs. This is the plan before any code. The concept, every state drawn, is
the artifact at https://claude.ai/artifact/8irAk2bNH4AjVnLLwFhChv.

## What Arc has, and what Yab has already

| Arc | Yab today | To do |
|---|---|---|
| Live Folders: GitHub pull requests (2024) | nothing | the live folder, below |
| Live Folders promised for Figma, Google Drive, Notion, Linear, RSS (never shipped) | nothing | the same folder, a source each, below |
| Live Calendar: next meeting, Join, ⌃⌘J | the same, from the Mac's calendars (`Meetings.swift`, [meetings-on-tabs.md](meetings-on-tabs.md)) | today's meetings in the pin's card |
| Previews of a favorite's recent items (Notion, Figma, Linear, Calendar, Confluence) | a pin's card is a snapshot of the page (`Glance.swift`) | a pin's card lists what is there |
| Unread counts on favorites (Gmail, Slack, X, GCal) | none; `Diary.clean` strips "(3)" from titles | a count on the mark's corner, cut out as the call's dot is |
| Mini player, Meet in picture in picture | the float, for any video site and any call (`Float.swift`, `FloatCall.swift`, [float.md](float.md)) | nothing |
| Media tray, several players | the band shows one player and "+N" (`PlayerBand.swift`, `Tune.swift`) | the list behind "+N", sound in the band, the band on top |
| Tidy Tab Titles (Arc Max) | only a search's folder drops the words searched (`Research.label`) | short names for kept tabs |
| Tidy Tabs, grouping by a model | none, by choice: "grouped by where the tabs came from, never by what a model makes of them" (`Research.swift`) | not planned |
| 5-second previews of a link | Peek on ⇧ click (`LinkPeek.swift`) | a summary on ⇧ hover, last |
| Air Traffic Control, Little Arc, Split View | `LinkRoutes.swift`, `LinkWindow.swift`, `Split.swift` | nothing |

Arc promised Figma, Google Drive, Notion and Linear folders and shipped none
of them; its release notes through September 2026 have GitHub pull requests
and the calendar only. Yab takes them all, below, as sources of one folder.

## Live folders

A live folder is a folder of yours with a source. It keeps its tabs up to
date: what comes in is added, what is done goes. The first source is GitHub
pull requests; the same folder takes more sources later.

Built: `Live.swift` (what a folder is set to, GitHub's answers, the diff),
`LiveFolders.swift` (the clock, reading, the answer in the row, making one),
`LiveViews.swift` (the words, the folder's row, its menu), `LiveTests`,
`bench live`.

### Settings and choosing to turn it on

Settings › Live Folders sits beside Spaces, its tile drawn with the pen as
the other pages' are (the folder on History's orange). A new profile starts
with it off: the introduction is Spaces' and Sync's, the tile, one line,
the sites it reads as chips, and Turn On Live Folders. Nothing is read
before that, history neither. Existing live folders opt in once on upgrade,
including empty folders and folders in unopened spaces.

On, the page is one list. Your folders first, as the spaces' list has its
spaces: the site's mark on its plate, the name, how many tabs, and on the
right only what needs doing (Sign In…, Couldn't update), grouped by space
only when more than one space has folders. Then "From your history": the
sources whose sites this Mac's own history opened ten times or more in the
last 30 days, most first, with the visits and the repositories or
workspaces seen (`LiveSuggest`), the first one's Add in black as Bring In's
browser used most is. Then More sources: the rest, A GitHub Repository…,
and Ask an Agent…, which opens the routine editor with a folder. Add makes
the folder in the current space at once; there is no sheet and no name to
type, the folder renames as any does.

A folder further in is laid like a space's page: its site on the pen
tiles' paper, its name, and one line of facts (tabs, site, when it was
updated). A sign-in or a failed read comes first, with its button. Then
Name, Show (the source's lists, the last one on stays on), Repositories or
Workspaces with, for GitHub's folders, Add Repository… under them, Update
Now with how often it reads on its own, and Stop Updating… in red on the
wash, as a space's Delete…, which asks first and keeps the tabs in a plain
folder.

Following a repository (`LiveFolders.followRepo`) makes a search folder of
its own, `is:pr is:open repo:owner/name`, named for the repository: the
pull requests you're part of stay in Pull Requests, every open one of the
repository in its folder. The popover takes owner/name or any github.com
address in it, and lists the repositories this Mac opened most.

The toolbar switch pauses source reads and routine-to-folder updates across
windows. It keeps every folder and tab, and each live folder in the column
says Paused; the page says how many wait. An answer already in flight
cannot change the tabs after pausing. In a live folder's menu, Update Now,
Open the site, Show ▸, Repositories ▸ and Live Folder Settings… follow
Move to Folder; Stop Updating sits with what is done to the folder and its
tabs at the foot. While off, the menu has only Turn On Live Folders….

`LiveFolderFeatureTests` covers the one-time opt-in and preservation of
saved data, `LiveSuggestTests` the history ranking and the repositories
typed. `scripts/runs/live_folder_settings_check.sh` builds the named app,
runs focused regressions and checks a local source through the real
native settings in an isolated profile, including pause, stale responses,
resume, parked spaces and stopping. The concept these pages were built
from is the artifact at https://claude.ai/artifact/NMXBGkeccdM93qzoWZmvpo.

### What you see

```
Pull Requests
  Fix wake crash in Float          Review
  Live folders: the model          Failing
  Counts on a pin's corner         Ready
  Bump WebKit shims                New
  Strip folders doc
```

- It is kept, above the line, and otherwise a folder of yours
  ([kept-tabs.md](kept-tabs.md)): it opens and shuts, is renamed, moves among
  the kept, has its preview when shut, and is a capsule on top
  ([strip-folders.md](strip-folders.md)).
- Its tabs are kept tabs asleep until you open one: a row, no page, no
  process. A folder of thirty costs thirty rows.
- Opened and left, a tab the folder put there sleeps as today's tabs do
  ("Rows, pages and sleep", below).
- A pull request's row is its title with the repository's words taken out;
  the repository and number are in its card.
- **Words at the row's end**, one at a time, the first that applies, and
  nothing when nothing needs you (the quiet row is the all clear; words,
  not a dot or a ring):

| Words | When |
|---|---|
| Review | your review is asked, of you or a team of yours |
| Changes | changes are asked on one of yours |
| Failing | checks failed on one of yours |
| Ready | one of yours is approved and its checks pass |
| New | GitHub says you haven't read it (`isReadByCurrentUser`), and none of the above |

  Review, Changes and Failing are drawn in ink; Ready and New in the faint
  ink, as `FolderNeeds` draws "Needs you". They change at once, as states
  do, with no layout pass of their own.
- A pull request's row is its own title: once its page has loaded, the
  page's "Fix it by anna · Pull Request #12 · acme/yab · GitHub" is cut back
  to "Fix it" (`LiveGitHub.shortTitle`).
- **Shut, it says what needs you the way Arc peeks.** A tab whose words turn
  to Review, Changes or Failing comes out under the shut folder, as the tab
  on screen in a shut folder already does (`Folders.lay`), and stays out
  until you open it (`LiveMark.callsOut`: it needs you and its words aren't
  the ones you last saw). Up to three come out; past three the folder's row
  says "5 need you" instead. New alone doesn't come out.
- **New ones come in at the folder's top.** The rest keep the order you gave
  them; the folder never sorts its rows under your hand.
- At thirty tabs it stops taking more (`LiveFolder.most`); Open on GitHub
  in its menu has the rest.

### Where one comes from

- **With Live Folders on, the first time you open a pull request in Yab.** A tab going
  from `/{owner}/{repo}/compare/…` or `/pull/new/…` to `/pull/{n}` is one.
  If the space has no GitHub live folder, and you never removed one there,
  "Pull Requests" is made at the kept's end, open, with that tab moved into
  it. A corner notice says it once: "Your pull requests, kept up to date
  here" ([floating-notices.md](floating-notices.md)). Remove Folder in its
  menu is the way out, and then it isn't made by itself in that space again
  (`live.github.removed.<space>` in the settings).
- **By hand:** New Pull Requests Folder on the line's menu, and Pull Requests
  Folder in ⌘T. Either reads at once; with one there already, it reads that
  one.
- **Later (M3):** "Keep This Search as a Folder" on a GitHub search, for
  anything the lists can't say.

### Its menu

```
Close Folder
Rename…
────────────
✓ Review Requests
✓ Team Reviews
✓ Needs Your Action
✓ Waiting for Review
✓ Ready to Merge
  Drafts
Repositories ›        ✓ acme/yab  ✓ acme/site …
────────────
Update Now
Open on GitHub
Stop Updating
────────────
Put 5 Tabs to Sleep
Remove Folder, Keep Tabs
Remove Folder and 5 Tabs
```

- The ticks are the lists GitHub's own pull requests page keeps, by its
  names: `review-requested`, `team-review-requested`, `needs-action`,
  `waiting-for-review`, `ready-to-merge`, `your-drafts`; one request each.
  The last tick can't be taken off.
- Repositories lists those its tabs are in and those left out; an unticked
  one is left out by `repoNameWithOwner`.
- Stop Updating leaves the tabs as a plain folder of yours.

### What comes and what goes

The folder only ever takes away what it brought.

- **Comes in:** a pull request matching the search that the folder doesn't
  have and you haven't hidden. When one of today's tabs already shows it
  (any page of it: `/files`, `/commits`), that tab moves in instead of a
  second row. A kept tab or a tab in another folder is left where it is,
  and the folder adds no copy.
- **Goes:** merged, closed, or no longer listed (you reviewed it, a tick
  changed) at the next reading. Not while it is on screen, makes sound or is
  on a call; an awake one is asked first whether something is typed in it
  (a review comment half written) and stays if so. It goes at the first
  reading after.
- **The pull request you just made** moves in as yours (`LiveMark.yours`):
  its words are kept up to date, and the folder never takes it away, since
  a draft isn't in the lists it shows.
- **⌘W** puts it to sleep, as on any kept tab.
- **Hide from Folder** in a live tab's menu: it goes, and stays out until
  what it says changes (a new review asked of you). Kept in
  `live-folders.json`.
- **Taken out by hand** (dragged out, Don't Keep): yours for good, and the
  folder leaves that pull request out the same way (`LiveFolders.takenOut`).
- **Dragged in**, any tab stays: the folder didn't bring it.

### Rows, pages and sleep

Keeping a folder up to date and keeping a tab loaded are different things
(the owner, 2026-11-05). Until you open a row by hand, the folder only
updates what it says, and the row stays unloaded.

1. **A row the folder brings is a link with its status**: title, words
   (review asked, checks failing, ready to merge), refreshed from the
   folder's source by `LiveReader`, never from a loaded page. No page is
   built for it until you open it; a reading that adds rows, changes words
   or takes rows away builds and wakes none (`LiveFolders.apply`,
   `Browser.asleepTab`).
2. **Opened, it is an ordinary tab.** It sleeps as today's tabs do: on
   the timer when Sleep Tabs is on, when its page grows heavy, when memory
   runs out (`Browser.awake(because:)`). Nothing the folder does makes it
   kept: not bringing it, not moving today's tab of the same pull request
   in, not the pull request you just made moving in (`LiveMark.moved`), not
   a later reading. Its place among the kept is where the folder stands,
   not the kept rules.
3. **Sync is separate.** A folder's rows travel to your other Macs with
   their status and who put them there (`LiveMark`), never a loaded page
   and never the kept rules: a row that comes by sync is unloaded there
   too, and follows the same rules once opened.
4. **Only your hand keeps.** A tab you moved into the folder yourself, or
   took out of it, keeps the kept rules as any kept tab does
   (`Tab.placedByFolder` is false for it).

Before this, every row was a kept tab in full: opened once, it stayed
loaded for the rest of the session whatever it grew to, since a kept tab
is never put down by the timer, for its size or when memory runs out
(memory reports, 2026-11-05). Tests: `LiveFolderSleepTests`; in the built
app, `evals/memory-growth/live_opened_ab.sh`.

### Where it reads from

The same way the page would, with your cookies and no tab: `LiveReader.get`,
AgentRead's way (the space's cookies copied into an ephemeral session, the
cookies the site answers with put back in the space's store as a tab would
take them, Safari's user agent), with `Accept: application/json`. It is what Arc does ("it pulls information from github.com"), with
no token and nothing to set up. Checked on 2026-09-28 on the author's own
account.

- **GitHub's pull requests page reads its lists as JSON, and so does the
  folder:** `GET /pulls/inbox/queries?filter={list}&max_pr_age=1m` for each
  tick (0.2 to 3 KB), then one `GET /pulls/inbox/deferred?page=1&ids[]=…`
  for what came back (under 1 KB). A pull request comes with its number,
  title, link, `repoNameWithOwner`, author, `isDraft`, `category`
  (`CI_FAILING`, `WAITING_FOR_REVIEW`, …), `isReadByCurrentUser` and
  `updatedAt`; the deferred call adds `statusCheckRollup` and
  `reviewDecisionState`. At most six requests, a few kilobytes, a refresh.
- **The words from them** (`LiveGitHub.words`): Review when it is in
  `review-requested` or `team-review-requested`; Changes when
  `reviewDecisionState` is `CHANGES_REQUESTED`; Failing when the category
  is `CI_FAILING` or the rollup `FAILURE` or `ERROR`; Ready when it is in
  `ready-to-merge`; New when GitHub says you haven't read it.
- **Both need `Accept: application/json`**, or GitHub answers with a 145 KB
  page.
- The cookies come from the space's store, which answers only once its
  network process is up: a read waits five seconds for them at most, then
  counts as failed and tries at its next turn.
- The diff is applied on the main thread in one pass (`Browser.quietly`),
  so a reading is one redraw.
- **Any GitHub host**, Enterprise too: the folder keeps the host its first
  pull request was on (`LiveGitHub.host(of:)`), whole with its scheme and
  port when it isn't plain https, which is also how `bench live make` points
  one at a stand-in on this Mac. Arc can't do Enterprise on its own domain;
  a GET with cookies doesn't care.
- **Later:** a search of your own (`/search?q=…&type=pullrequests`, JSON with
  the same header, no checks in it), the pull request's own tab saying
  merged or closed as it loads, and a reading 3 s after you act on GitHub.
- These are GitHub's own addresses, not an API it promises. The saved
  answers in `LiveGitHubTests` are the contract; when one stops parsing,
  the folder keeps its list (below, for every source).

**Signed out** (GitHub answers with its sign-in page): the folder's row says
"Sign in"; a click opens the sign-in page in that space. The tabs stay as
they were. **Offline, a 5xx, an answer that doesn't parse:** the last list
stays, it reads again at its next turn, and nothing is said. The card says
"Updated 12m ago" at its foot, the only place that time is shown.

| When | Read every |
|---|---|
| the folder open, or its site in the tab in front, yab active | 60 s |
| yab active | 5 min |
| yab in the background | 15 min |
| launch, wake, yab coming back | once, a few seconds after |
| no window open (Yab used from the terminal), Low Power Mode | not at all |

A look at which are due every half minute (`LiveFolders.tick`); folders
only in rows that are up, a parked space's read when it comes back.

At 5 minutes that is under two requests a minute, well inside what a person
clicking through GitHub sends.

### The model

- `Nest.live: Live?`, beside `Nest.search`:

```swift
struct Live: Codable, Equatable {
    var source: String        // "github.pulls", "github.issues", "notion", "drive",
                              // "figma", "linear", "jira", "confluence", "youtube", "feed"
    var host: String          // "github.com", an Enterprise host, a Jira site, a feed's
    var account: String?      // Google's /u/{n}, a Notion workspace left out, …
    var show: Set<String>     // the ticks: "needs-action", "waiting-for-review", …
    var hiddenGroups: [String] // repositories, workspaces left out
    var query: String?        // a search of your own, in the site's words
}
```

- `Tab.live: LiveMark?`: the key (`github.com/owner/repo/pull/n`,
  `notion/{block id}`, `drive/{file id}`), its words, and whether the
  folder brought it.
- `Session.Entry` gains `folderLive` (the `Live`, on each tab of the folder,
  as `folderSearch` is) and `live` (the tab's key and words). An empty live
  folder is one of `Folders.empties` and its `Live` is saved with it in
  `empty-folders.json`.
- `live-folders.json`: per folder, the last refresh, the keys hidden, the
  keys seen and their words when seen (for New and for what comes out).
- New files: `LiveFolders.swift` (the registry across spaces, the clock, the
  diff and the two policies, adopting tabs), `LiveReader.swift`, one file a
  source (`LiveGitHub.swift`, `LiveNotion.swift`, `LiveDrive.swift`,
  `LiveFigma.swift`, `LiveLinear.swift`, `LiveAtlassian.swift`,
  `LiveYouTube.swift`, `LiveFeed.swift`), `LiveViews.swift` (the words, the
  menu, the card's rows), `LiveBench.swift` (bench verbs and a fake source).

## Every source Arc promised, and a few more

Arc promised Figma, Google Drive, Notion and Linear folders, and RSS; each
is a source of the same folder here. Checked on 2026-09-28 with the
author's own sessions in Yab, read only.

### Two kinds of folder

- **To do:** things you finish. Pull requests, issues, Linear, Jira. An
  item stays while it is open and goes when it is done: merged, closed,
  completed, resolved.
- **New for you:** things that happened for you. A mention, a comment, a
  file shared with you, a page someone else changed, a new video. An item
  comes with its words and goes a day after you open it, or after a week
  unopened; twelve at most, newest first. Nothing in it is ever done, so
  it can't be left to grow.

Everything else is the same: tabs asleep until opened, only what it
brought is taken away, and the "needs you" words come out under a shut
folder.

A to-do folder can have a new-for-you list too: Linear's My Issues has
Mentions and Comments. Each list has its kind (`LiveSource.listKinds`),
each tab remembers which kind brought it (`LiveMark.news`), and
`LiveFolder.mixed` reads each by its own rules: assigned issues go when
done, mentions a day after you open them, a week unopened, twelve at most.
A thing both lists name is to do, and a tab of one kind is never brought
again as the other. A mention of a thing open in today's moves that tab
in, and one kept elsewhere stays out, as for to do. `LiveSeen` keeps each
kind's saying, so a mention's tab shows its quote and a to-do tab its date.

| Kind | Words, the first that applies | Come out when shut |
|---|---|---|
| To do | Review, Changes, Failing, Late, Due Thu, Ready, New, Done | Review, Changes, Failing, Late |
| New for you | Request, Mention, Comment, Shared, Changed, New | Request, Mention, Comment |

"Due Thu" is due within two days, "Late" past it. "Request" is someone
asking to open a file of yours (Figma). Words that come out are drawn in
ink, the rest faint.

### The sources

| Folder | Kind | Reads, with cookies only | Lists | Checked |
|---|---|---|---|---|
| Pull Requests | to do | GitHub's pull requests JSON, above | yours, and asked of you or your team | yes |
| Issues | to do | GitHub's search JSON, `is:issue is:open` | assigned to you, yours, mentioning you | yes |
| Notion | new for you | POST `app.notion.com/api/v3/getNotificationLogV2`, `getRecentPageVisits`, `syncRecordValues`, per workspace | unread mentions, comments and invites; pages you visit that someone else edited since | yes |
| Google Drive | new for you | GET `drive.google.com/drive/u/{n}/shared-with-me` and `/recent`: the list the page carries | shared with you since the last look; files changed by someone else after you last opened them | yes |
| Figma | new for you | GET `www.figma.com/api/user_notifications`, `/api/recent_files`, `/api/versions/{file}`, `/api/session/state` | unread comments, replies and mentions, files you may now open, someone asking to open yours; recent files someone else edited since you opened them | yes |
| Linear | to do, mentions new for you | POST `client-api.linear.app/graphql`: `availableUsers`, then each workspace's `assignedIssues` and `notifications` with its `user` header | assigned to you, begun or up next, in every workspace; unread mentions of you and new comments on issues of yours | yes |
| Jira | to do | GET `/rest/api/3/search/jql`, `assignee = currentUser() AND resolution = Unresolved` | assigned to you, open | no site here |
| Confluence | new for you | GET `/wiki/rest/api/search?cql=…` | mentions of you, pages you watch changed this week | no site here |
| YouTube | new for you | GET `youtube.com/feed/subscriptions` | new videos from your subscriptions, no Shorts | yes |
| A feed | new for you | the RSS or Atom file | new posts | standard |
| A routine's | to do | its run hands the folder what belongs (`folder_update`), in its agent's own words at each row | anything a routine is told to keep, [routines.md](routines.md) | evals/folders/routine.py |
| Slack | none | needs the `xoxc` token the page keeps in its local storage | nothing | yes, declined |

**Notion.**
- One folder for every workspace; the card shows each row's workspace, and
  Workspaces › in the menu leaves one out. The author has eleven.
- `getNotificationLogV2` with `{spaceId, size: 20, type: "unread_and_read",
  variant: "no_grouping"}` gives each notification's `type` (commented,
  user-mentioned, user-invited), `read`, `received` and
  `navigable_block_id`; titles come from `syncRecordValues`. Unread ones
  become rows: Mention, Comment, Shared.
- `getRecentPageVisits` gives `visitedAt` and the page's
  `last_edited_time` and `last_edited_by_id`: a page edited by someone else
  after your visit is Changed.
- Never `markNotificationsAsReceived: true`: reading here must not clear
  Notion's own inbox.
- About 20 KB a workspace. Workspaces with notifications every 5 minutes,
  the rest every 30.

**Google Drive.**
- The Recent and Shared with me pages carry their first fifty files as data
  (`window['_DRIVE_ivd']`, escaped JSON, an array per file). Seen there: id,
  title, type, created and modified, when you last opened it, who changed it
  last, its link. The parse finds the fields by their shape (a Drive id, a
  mime type, millisecond times) rather than trusting their places, which
  can shift.
- About 400 KB a page, so every 15 minutes.
- One folder per Google account (`/u/0`, `/u/1`), which spaces already keep
  apart.
- Docs, Sheets and Slides come through Drive: Docs' own home carries no
  list.

**Figma.** Checked on 2026-09-28 with the author signed in; every read
below is a GET with the session's cookies, and a signed-out one is a 401.
- The bell in Figma's file browser reads
  `/api/user_notifications/server_driven/plan`, one team at a time, and
  leaves out files of teams you're not in: the author's showed one
  notification where the account had thirteen. The older
  `/api/user_notifications` has them all at once, each with `read_at`,
  the file's key and name in `locals`, and a `track_back` naming the kind:
  `file_comments_…` (a comment, or a reply in `comment_parent_id`),
  `fig_files_…` (comments on your file, counted in `batch_locals`),
  `file_role_request_approved_…` (you may now open it),
  `file_role_request_created_…` (someone asks to open yours). A comment
  whose `message_meta` names your id is a mention.
- `/api/recent_files` carries `touched_at` (last edited by anyone, the
  "Edited 6 days ago" of the file browser) and `accessed_at` (you last
  opened it). A file edited since you opened it may be your own editing
  after you opened it, so `/api/versions/{file}` says whose the versions
  since then are: `user_id`, never the names beside it
  (`participating_users_array` holds names, not ids).
- About 55 KB for the notifications and 130 KB for Recents, so every ten
  minutes.
- The pin's card is the folder's when there is one, else Recent here.

**Linear.** Checked on 2026-09-28 with the author signed in to three
workspaces. The web client keeps no token: it sends its GraphQL with
`credentials: 'include'` and a `user` header, your user in the workspace
on screen (`setUser` in its client). Without the header every query is an
authentication error, which is why the first try with the cookies alone
failed. `availableUsers` answers the cookies alone and lists you in every
workspace (`id`, `active`, `organization.urlKey`), so no page's storage
is read. The requests are queries written in Yab's code, never a
mutation.

Mentions and comments checked on 2026-10-15, read only, in the same three
workspaces: `notifications(first: 50)` answers `IssueNotification` nodes
with `type` (seen: `issueNewComment`, `issueAssignedToYou`,
`issueUnassignedFromYou`, `issueStatusChanged`), `readAt`, `archivedAt`,
`snoozedUntilAt`, `actor`, `comment.body` and the issue with
`assignee.isMe` and `creator.isMe`; a `productAnnouncement` comes without
an issue. No mention was unread there that day, so `issueMention` and
`issueCommentMention` are Linear's documented names, matched as any type
ending in `Mention`. Introspection is refused to anyone but a super user.

**Jira and Confluence.** No Atlassian site here to check. Their REST API
answers the session the web app has; Jira Cloud's search moved to
`/rest/api/3/search/jql`.

**YouTube.** 2.9 MB a read, so every 30 minutes and only while the folder
exists. The page gives times only as "3 hours ago" in its language, so a
new video is one whose `contentId` wasn't seen before.

**Slack.** Its API wants a token from the page's local storage, not a
cookie, and Yab doesn't lift a token out of a page. Its pin still gets a
count, from the open tab's title.

**A feed.** A page with an RSS or Atom link (a blog, a YouTube channel, a
repository's releases) gets Follow in a Folder in ⌘K.

### How all of them read

Built in `LiveSources.swift`, held to answers in their sites' shapes in
`LiveSourcesTests` and to the new-for-you rules in `LiveNewsTests`; each
parser was also run once over the author's own real answers (kept outside
the repository) on 2026-09-28: 7 issues, Gmail's count and 20 unread, 50
files on each Drive page, 60 subscription videos, 3 Notion notifications
and 3 changed pages.

- `LiveSource`: its id, the folder's name, its kind (to do, new for you),
  its site (for its pin's card and menu), its lists (the menu's ticks) and
  its cadence: five minutes, fifteen for Drive's 400 KB pages, thirty for
  YouTube's 2.9 MB one. `LiveSource.read(live, store:)` answers `.items`,
  `.signedOut` or `.failed`.
- `LiveReader.get` and `LiveReader.post` (Notion's reads are POSTs, from the
  site's own origin): the space's cookies; of the answer only the cookies it
  sets are kept, in the space's store, so a session the site turns over as
  it answers doesn't leave the tabs holding a spent one.
  These are Yab's own requests; the `read:` gate on POSTs stays as it is,
  for agents.
- **New for you** (`LiveFolder.news`): what reached you comes in once, at
  the top, and never again once shown (`live-folders.json` keeps what each
  folder has shown); a tab goes a day after you opened it, or a week after
  it came unopened; twelve at most. The first reading brings only what is
  fresh (the last three days, or the first five when the source has no
  dates), so a folder made today isn't filled with last month.
- **Notion:** `getUserNotificationsInitial` says which workspaces have
  unread, `getNotificationLogV2` lists each one's, and a page the log names
  without holding it gets its title from `syncRecordValues`. Invited or
  asked for access reads Shared (they come on the mentions channel too),
  a comment Comment, a mention Mention. `getRecentPageVisits` gives
  Changed. `markNotificationsAsReceived` stays false.
- **Drive:** the Recent and Shared with me pages' `_DRIVE_ivd`: slots 0 id,
  2 title, 3 type, 10 modified, 12 last opened by you, 22 shared, 114 link,
  checked by shape (an id's length, a type with a slash, millisecond
  times). Shared: from Shared with me. Changed: modified more than a minute
  after you last opened it. Folders are left out. The account is the
  folder's `host` ("0", "1").
- **YouTube:** `ytInitialData` from the subscriptions page, taken apart off
  the main thread: each `lockupViewModel` of a video, its id, title and
  channel. Shorts are another model and left out.
- **A feed:** RSS or Atom with `XMLParser`, CDATA and entities read, Atom's
  `link href` taken.
- **Gmail** is no folder here (docs/mail.md is its own plan) but gives the
  mail pin its count asleep (`fullcount` in the unread feed) and its card
  (Unread: who, the subject, when).
- **Linear** (`LiveLinear.swift`): My Issues, assigned to you and begun
  or up next (Linear's `started` and `unstarted`: the backlog is left out,
  the author's held 36 of 51), from `client-api.linear.app` with the
  session and the page's origin: `availableUsers`, then each workspace's
  issues with its `user` header. Late past a due date, New within a day.
  Workspaces › in the menu leaves one out (`Live.hidden`, the workspace's
  word in its addresses); a workspace that answers as signed out (its own
  SAML) is skipped. A 401 or an authentication error on the first call
  reads as signed out, any other shape as failed. Run over the author's
  real answers: three workspaces, 2, 15 and 0 issues.
  Mentions and Comments, its second list (`LiveLinear.notes`): each
  workspace's `notifications` of the last week, asked in the same query
  as its issues and filtered by type on Linear's side (its filter has no
  `readAt`, and a busy workspace's status changes would crowd mentions out
  of the fifty), then kept when unread, not archived nor snoozed; a mention
  of you anywhere (`issueMention`, `issueCommentMention`) reads Mention, a
  new comment on an issue assigned to you or made by you
  (`issueNewComment`) reads Comment; others' issues you only follow are
  left out. One row an issue, its newest. Nothing is marked read: Linear's
  inbox stays as it was. The row's card says the word and the comment's
  first words ("Mention “which one ships?”"), who said it first in its
  facts, and no button: a click on the tab opens the issue. A folder made
  before the list existed (saved with no lists) shows both.
  `evals/folders/linear_mentions.py` drives it on a built app.
- **Figma** (`LiveFigma.swift`): Comments and Access, and Files Changed by
  Others, as above. Notifications not yet read nor resolved, the newest a
  file, opening the comment when Figma gives its address and the file
  (`/file/{key}`, which Figma sends to its editor) otherwise. A recent file
  edited more than a minute after you opened it, in the last two weeks,
  six at most, asks its versions once for each edit (kept by file and
  time); Changed when a version since is someone else's. Run over the
  author's real answers: three notifications (two files opened to them,
  one comment), two files changed by others.
- **A GitHub search kept as a folder:** Keep This Search as a Folder in a
  tab's menu on a GitHub search, `/pulls` or `/issues` with a query
  (`LiveIssues.search(in:)`, "+" read as a space): source `github.search`,
  the query kept in `Live.query`, read from `/search` in JSON; each result
  opens its own page, `/pull/n` when the search says it is a pull request.
- **Later:** Jira and Confluence with a site to try.

### Where they come from

- GitHub's pull requests by itself, above.
- New Live Folder › on the line's menu lists every source: GitHub Pull
  Requests, GitHub Issues, Notion, Google Drive, YouTube Subscriptions.
- A pin's menu offers its own: "Live Folder from Notion" on a Notion pin,
  and so for GitHub, Drive and YouTube.
- Follow Site in a Folder in a tab's menu: the page's own feed, as its head
  names it (`link rel="alternate"`), in a folder named for the site; "This
  page has no feed to follow" when there is none.

## Pins that say what's new

### A count on the mark's corner

A pin whose site has something waiting wears its count on a plate at the
top corner of its mark: "4", up to "99+". Nothing at zero. Built in
`Corner.swift` (the plate, the cut, the count), `CornerTests`.

- **Cut out, as the call's dot is.** The plate is a capsule, and a capsule
  1.5 points wider all round (`CaptureDot.gap`) is cut out of the mark
  itself with a `destinationOut` mask, so what shows round the plate is
  whatever the pin is drawn on, in any theme and on any space's tone,
  never a ring of some other color. The bottom corner stays the call's
  dot's; both can be there at once. `BadgeCut` is `DotCut` with a
  capsule, and like it the mask is only on while there is a count: a mask
  on every mark cost each row an offscreen pass whenever the column moved.
- **Sizes**, for a 16-point mark: 10 points high, digits 8 points
  semibold, monospaced; one digit is a circle, two 14 points wide, "99+"
  19. The plate's center is the mark's top corner, as the call's dot's is
  its bottom one: half on the mark, so the cut takes the corner, not the
  letter or picture in it. The cut, the plate and its click are placed
  from that one center, each by its own size, so they can't drift apart.
  On top a pin is a 30-point square: a wide plate ("99+", "12m") that
  would pass its edge moves in by that much, as the dot does on a pair's
  chip (`dotInset`); in a row, it stops a point short of the title. A pin
  drawn as its bare letter has no square to take a corner of, and a plate
  on its corner took the top of a 1: there the plate sits 4.5 points
  higher (`MarkCorners.letterLift`).
- **The plate** is the space's ink (`Palette.ink` on its tone), the digits
  in what the pin is drawn on. Not red: red on a mark's corner already
  means the camera or the microphone is live.
- **Motion:** a new number rolls its digits (`RollingText`); the plate
  and its cut come, go and change width at once, as states do. Join's plate
  is the system green with the dark ink Join always had (white on that
  green falls short of 4.5:1).
- **When it waits:** while a Peek mark is on the mark's top corner, the
  count waits. A calendar wears its meeting's time there instead (below).
- **The same everywhere:** a kept tab's mark in the column and a tab's on
  top wear the same plate. The row's end stays for a live folder's words.
  A row drawn with letters rather than icons has no mark: the plate stands
  on its own before the title (`LooseCount`). While the mark shows the
  count, the title's own "(12)" is left out of the row (`Counts.untitled`).

Where the number comes from:

- **The site's own badge:** the page script provides
  `navigator.setAppBadge` and `clearAppBadge` (the Badging API web apps
  already call), and the number comes to Yab.
- **The title**, by a table of sites checked in M0: `(3) Slack`,
  `Inbox (12) - …`, `(2) Home / X`, `Telegram (3)`, `(1) Discord`. The
  title's own "(3)" is taken out of the row, as `Diary.clean` takes it
  out of history.
- **For a pin asleep**, where a site can be read with cookies: Gmail's
  unread feed for Primary (`fullcount` in
  `mail/u/0/feed/atom/%5Esq_ig_i_personal`, as Gmail's own title counts;
  the inbox's feed counts Promotions and Social too), Notion's unread mentions (`getUserNotificationsInitial`, 2.6 KB,
  every workspace). GitHub's own count isn't cheap (its indicator says only
  whether there is something, the list is a 1 MB page), so a GitHub pin
  counts the Pull Requests folder's rows that need you. Every minute
  while Yab is active, and when it comes back or the Mac wakes.
- By default only where a count means someone waits: mail, chat,
  notifications (Gmail, Outlook, Slack, Discord, Telegram, WhatsApp, X,
  LinkedIn, GitHub, Linear). Any other pin has Show Count in its menu.
  YouTube's "(340)" is not a message.

### A meeting's time on the same plate

Today "12m" is drawn under a calendar pin's mark, pushing the mark up, and
Join fills the whole pin green (`PinMeeting`,
[meetings-on-tabs.md](meetings-on-tabs.md)). It moves to the plate at the
mark's corner, with the same cut, and the mark stays where every other
pin's is.

| When | The calendar pin |
|---|---|
| more than an hour before | nothing |
| within the hour | "60m" on the plate, rolling down to "1m" |
| a minute before, until 10 minutes after the start | "Join" on a plate in the call's green; a click on the pin joins, as today, and ⌃⌘J from anywhere |
| in the call | nothing on the pin; the call's tab has its red dot |

- Only the number rolls; the "m" stands still (`RollingText`), and the
  plate and the cut change width on its clock when "10m" becomes "9m".
- The call's own tab wears its last minutes on the same plate, "4m",
  above the microphone's red dot, both cut out at once. The call's
  floating window keeps "5 min left" in words.
- The other way, drawn beside it in the concept, kept Join as the whole
  pin gone green: a bigger target, but the only pin that changed its whole
  look. The pin is still the whole button; only the green is smaller.
- A calendar has no count, and mail and chats have no meetings, so the two
  never share a corner.

### A pin's card lists what is there

Resting on a pin brings its card on the tab card's clock (half a second),
and for a pin it is a list in place of the page's picture; you know what
your own pin looks like. Built in `PinCards.swift`, hosted as a shut
folder's preview is (`TabGlance`, its key "pin:" and the pin's id).

| Pin | Its card |
|---|---|
| a calendar | Today: the meetings left today, "Join" from a minute before (in ink), "in 12m" within the hour, the time for the rest; Return joins or opens the meeting's link |
| a site with a live folder in this window (GitHub) | the folder's name and its tabs, what needs you first, each with its words; Return goes to the tab |
| any other | Recent here: the last six pages opened on that site, from history (`Diary.search("site:…")`), with when; Return opens it in the pin |

- The card takes typing, as a shut folder's preview does: letters search
  its lines, and for Recent here all of the site's history; ↑↓ pick,
  Return opens, Escape puts it away (`TabGlance.typedPin`).
- Recent here is Arc's previews of Notion, Figma, Linear and Confluence for
  every site at once, from `Diary`, with no integration to keep working. It
  shows what you opened, not what others changed; a site with a source (M3:
  Notion, Drive, Gmail's unread) will list the source's items instead.
- `bench glance ID` on a pin answers its card's heading and lines.

## The rest

- **Players.** Built (`PlayerBand.swift`, `Tune.swift`): "+N" on the band
  opens the list of every tab playing or paused in the last five minutes
  (`Player.all`), each played or paused by a click, the one the band shows
  first, and Pause All at its foot; the band's tail has a sound door, the
  playing tab muted or heard again, drawn muted while it is. `bench band
  mute|pauseall` and the report's `silent`, `players`, `playing_all`.
  Still to do: the band on top, where there is no column, as a pill at the
  strip's end, which needs room kept for it in `StripWidths` and a drawing
  first.
- **Short names for kept tabs.** Built (`ShortNames.swift`): the site's
  name and a count come out of the title by rule (`MarkdownLink.title`); a
  title still past 28 characters is said in two to four words by the
  on-device model (FoundationModels, greedy, as `FormModel` asks it), once
  per address and title, kept in `short-names.json`; an answer that isn't
  shorter, or runs past five words or 32 characters, is dropped for the
  rule's. Never over a name you gave (`Tab.name`, ⌃⌘R), nor a live folder's
  tab (its own title). The full title stays in the card. No switch since
  2026-10-13, as Arc Max has none once on. On this Mac: 0.6 to 1.5 s a title,
  "Nginx reverse proxy" for "How to Configure Nginx as a Reverse Proxy for
  Node.js Applications on Ubuntu 24.04".
- **A link's summary on ⇧ hover.** Removed 2026-10-13 at the user's ask.
  `LinkSummary.swift` keeps only reading a page's words and their gist from
  the on-device model, for a boost's `summarize(url)`.
- **Grouping by a model: no.** Yab groups by where tabs came from (a
  search's folder, a task's folder) because that rule always holds and is
  said in one sentence.

## Order

| Step | What | Done when |
|---|---|---|
| M0 | What's left to check: which sites call `setAppBadge`; the title table. Figma and Linear checked | a note here with what holds |
| M1 | GitHub Pull Requests: model, reader, diff, words, coming out, the menu, made by itself, the card. Built | bench, tests, and a week on the author's own pull requests |
| M2 | Pins: the count and a meeting's time on the corner plate, the card's lists (calendar, live folder, Recent here). Built; Gmail's unread in its card comes with M3's sources | the same |
| M3 | The sources already checked: Notion, Google Drive, GitHub issues, YouTube, feeds, a GitHub search kept as a folder; each with its count and card. Built | the same |
| M4 | Linear and Figma, checked signed in and built; Jira and Confluence with someone who has a site | the same |
| M5 | Players: the list behind "+N" and sound, built; short names, built; the band on top later | the same |
| M6 | The link's summary on ⇧ hover. Built | |

## Checks

- `LiveGitHubTests`: saved answers as fixtures (each inbox list, the
  deferred call, a search, none, the sign-in page, an Enterprise host); the
  words from categories and rollups.
- One test file a source (`LiveNotionTests`, `LiveDriveTests`, …): saved
  answers, one of them changed in shape, which must keep the last list
  rather than empty the folder.
- `LiveDiffTests`: both policies; comes in at the top, goes, stays while on screen or with
  something typed, hidden until its words change, a tab dragged out left
  out, a tab dragged in kept, today's tab moved in instead of a second row,
  thirty and "N more", New and what comes out.
- `bench live`: a fake source to add, change and take pull requests;
  `bench live state` reads the folder back; `bench pace idle` with three
  live folders of thirty: nothing on the main thread between refreshes, one
  pass of a few milliseconds at one.
- `PinCountTests`: the title table, the badge, nothing at zero, 99+.
- `BadgeCut`: the cut's frame against the plate's for one, two and three
  characters, and against the call's dot when both are on.
