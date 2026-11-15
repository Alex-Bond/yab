# Feature hints

Yab says what it can do at the moment it would have helped, in the corner
notice it already uses, and stops for good once you use the thing yourself.
Code: `Sources/Fast/Teach.swift`. Prototype:
https://claude.ai/artifact/4HMkJ8aMkwCm2aDShETyGy

## Two kinds

**A key after the act.** A notice Yab gives anyway gets the key that does
the same, when the act came from a menu or a button:

| Act | Notice | Key |
|---|---|---|
| Copy URL (tab menu, app menu) | Link copied | ⇧⌘C |
| Copy Markdown Link | Markdown link copied | ⌥⇧⌘C |
| Bookmark (star, menu) | Bookmarked | its key, when one is chosen (none by default) |

Up to three times each. Pressing the key once ends it. When the address bar
or the bookmarks bar answers instead of the corner, nothing is said, and the
key is still counted.

**Noticed.** Something you did that a feature does better:

| Feature | When | Notice | Button |
|---|---|---|---|
| Peek | a link opened in a tab of its own and shut within 15 s, the third time in a day | Peek at links with ⇧ Click | |
| Split View | four switches between the same two tabs within a minute | Both at once? | Split View |
| Spaces | a second account signed in to on the same site within a week, Spaces off | Two accounts here? One space each | Set Up |

Set Up turns Spaces on and opens New Space with its own sign-ins chosen.

## Rules for what is noticed

- Kept on this Mac only, in the settings store (`teach.*`): uses, how often
  each was said, when. Accounts are kept as short hashes, never names.
- Using the feature, any way, ends its hint.
- Not in anyone's first day, not in a session's first 10 minutes, and at
  least two days between any two. Peek and Spaces at most twice a week
  apart, Split View three times a day apart.
- Quiet while typing in the field, on a call, with an agent at work in the
  tab, a password card up, the New Space tray open, another notice in the
  corner, or the window not in front.
- Settings › Search › "Suggestions under the field" turns them off. The keys
  after an act stay: they only finish a notice already there.

## Trying them

On a `--test` run: `./bench --test teach hurry` turns the waits off (uses
and counts still hold), `teach reset` forgets everything, `teach state`
shows the ledger and the corner, and `teach shut`, `teach signin HOST USER`,
`teach copy|markdown|bookmark` pull a trigger as the page would.
