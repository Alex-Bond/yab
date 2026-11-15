# Halloween 2026

From the release that brings it (0.0.31) to the end of November 2, Yab
dresses up. The concept with every state drawn: artifact EK5pRND6w5U9qxYf5jEPZU,
sources in `work/design/yab-halloween-2026-10-19`.

- **The update note** (`UpdateDoodle.swift`): pumpkin ink, a pumpkin where the
  heart and the tick go, and after the restart "dress it up" by What's new,
  which opens the release's version page.
- **The version page** (fast-web, `app/changelog`): a "Dress Yab up" block.
  Opened in Yab its icons and drawings tiles are `yab-dress:` links:
  `yab-dress:icon/halloween-ghost` (or `default`), `yab-dress:drawings/halloween?strength=0.45`,
  `yab-dress:drawings/none`. Yab takes them only from a click in the main frame
  of yetanotherbrowser.com and never hands them to another app (`Dress.swift`).
  Yab sets `data-yab`, `data-yab-icon` and `data-yab-drawings` on the site's
  root before its scripts, and again with a `yab:dress` event after a change,
  so the page knows it is in Yab and what Yab wears. Elsewhere the block asks
  for a download.
- **App Icon** (`AppIcons.swift`): Pumpkin, Ghost, Mummy and Witch right after
  Default, orange dots, a plate with the days left ("12 days left", "Leaves
  tomorrow", "Last day") and the line under the name saying until when. The
  first time App Icon opens it lands on Pumpkin. Every one worn while it lasts
  is kept (`halloween.worn`); on November 3 the others leave, shown once as
  they turn away and the row closes up, and the kept ones say "Halloween 2026".
- **Drawings** (`LookDrawings.swift`): a third set, Halloween, beside Browser
  and Life in Edit Look…, drawn in one line like them. It stays after the event.

The clock is `Halloween.now`; a test world sets the `halloween.now` date
setting to see another day. Pictures of every state: `evals/halloween/shots.py`.
Tests: `HalloweenTests`, `UpdateInkTests`.
