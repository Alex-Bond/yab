# One list a box: password managers on page fields

The rule since 2026-10-20, after reports that Yab and a password manager
both answered the same box: Dane Kapoor's "two separate 1Password
integrations competing" (#192, #193), Dima Braven's 1Password menu on
every field (#140, #203), NordPass before it (#5), and KeePassXC, Enpass,
Proton Pass and Bitwarden reports (#16, #41, #51, #128, #166, #208).

## The rule

A box on a page has one list, and one owner:

| On in Yab | Sign-in boxes (name, email, password, new password, a sign-in in a frame) | Saving a new sign-in | Card boxes | Address and form boxes | Any other box (search, chat, comments) |
|---|---|---|---|---|---|
| no password manager extension | Yab's list and plate, when Yab's passwords are on | Yab's card | Yab's cards | Yab's addresses and Fill Form | nothing |
| a password manager extension, connected or not | the extension's icon and menu only | the extension's offer only | Yab's, unless the extension took cards | Yab's, unless the extension took addresses | nothing of Yab's |

- **A password manager extension** is one Yab knows by its store id
  (1Password and its beta, Bitwarden, NordPass, Proton Pass, Dashlane,
  LastPass, Keeper, Enpass, RoboForm, KeePassXC-Browser, iCloud Passwords),
  or any extension that told the browser it does the saving itself, as
  Chrome hears it (`chrome.privacy.services.passwordSavingEnabled` set
  false). On and enabled is enough: connecting it in Settings › Passwords
  is for agents (who unlocks it, whose menu sign_in uses), not for fields.
  `PasswordManagers.fieldOwner`.
- **Took cards, took addresses**: the extension set
  `autofillCreditCardEnabled` or `autofillAddressEnabled` false, Chrome's
  own signal that it fills those (`PasswordManagers.walletOwner`). Yab
  doesn't guess past that: a manager that didn't say so leaves Yab's cards
  and addresses where they were.
- **While a manager has the boxes, Yab draws nothing on them**: no list,
  no plate in the box, no "Use Strong Password", no fill by itself, no save
  card, and it hides nothing of the extension's (no icon CSS, no menu
  hidden). The extension behaves as it does in Chrome. Yab's passwords stay
  where they are: ⌘T's Passwords, Settings, and agents' `sign_in`, which
  still tries Yab's login first.
- **Yab reading a vault itself** (`bw` already signed in, 1Password's CLI
  integration on) lists that vault in Yab's own list only while no manager
  extension is on in Yab (`ManagerVaults.listed`). With the extension on,
  the extension is the list, never both.
- **Codes a site mailed or texted** (MailCodes) still hang under a code box:
  no manager has those.
- Settings › Passwords says who fills: "1Password fills and saves passwords
  on pages while its extension is on."

Turning the extension off in Yab (Extensions, or ⌘E) gives the boxes back
to Yab at once; on again, back to the extension.

## What Yab does with each manager

Only what was checked end to end stays; the rest went 2026-10-20.

| Manager | Fields | Connect: agent sign_in through its menu | Yab unlocks it (unlock password kept) | Yab reads its vault (CLI) |
|---|---|---|---|---|
| 1Password | its own | yes | no: its app's Touch ID | `op`, stand-in checked; only with the extension off |
| Bitwarden | its own | yes, picked from its menu (password_unlock.py) | yes (synthetic vault, password_unlock.py, password_keep.py) | `bw`, stand-in checked; only with the extension off |
| NordPass | its own | yes (its closed menu read by the shim) | yes (signed in by hand, its unlock page) | no |
| Proton Pass | its own | yes | **removed**: its unlock page was never tried signed in | **removed** (`pass-cli` never run) |
| Dashlane | its own | yes | **removed** | **removed** (`dcli`) |
| LastPass | its own | yes | **removed** | **removed** (`lpass`) |
| Keeper | its own | yes | no unlock page | **removed** (Commander) |
| Enpass | its own | yes | no unlock page | no |
| RoboForm, KeePassXC-Browser, iCloud Passwords, any other that takes saving | its own | no | no | no |

A connection kept from before with "Yab unlocks it" on a manager that no
longer allows it reads as "You unlock it", and unlock_manager hands off.

## Checking it

`evals/extensions/password_fields.py` (farm, `--display --needs capture`):
the real store extensions, one test world each, Yab keeping two fixture
logins. Bitwarden signed in to the public synthetic vault, its menu on
field focus, unlocked, locked, and connected; the others never signed in.
For every box (sign-in name and password, sign-up email and new password,
an email-only step, the password step, search, chat, title, comment, an
address, a card, a sign-in in another site's frame): Yab's list, plate and
wallet list, what the extension put near the box, a picture of the
window, light (and dark for Yab alone and Bitwarden). Then a sign-in sent:
whether Yab asks to save. `--no-rule` records a build before the fix.

Not checked signed in: every manager but Bitwarden. The stand's
`passwords` world on adhd (NordPass, Bitwarden, 1Password) waits for the
user to sign in (docs/testing-real-profiles.md); until then a report past
sign-in (a fill, a menu's rows, 1Password on every field) stays "not
verified".

Related: [password-managers.md](password-managers.md) (connections, unlock,
agents), [password-manager-vaults.md](password-manager-vaults.md) (Yab's
list for a vault it reads).

## Checked so far (2026-10-20)

Report page with every box before and after:
https://claude.ai/artifact/9VPKg5XWf4KbAgY8fWZXL4 (built by
`evals/extensions/password_fields_report/report.py` from the runs' reports).

- Fresh worlds, store extensions (farm 9ab6e3dc main, e1418a32 fix): with
  Bitwarden signed in to the synthetic vault, main showed Yab's list over
  Bitwarden's menu on every sign-in box; the fix shows Bitwarden's alone.
  Beside a manager only installed, main put up Yab's list and "Use Strong
  Password"; the fix shows nothing of Yab's. Yab asks to save only with no
  manager on.
- The user's test accounts in the stand world on adhd, eight managers, the
  fix (farm bc4ce659): nothing of Yab's on any box, no save card; Bitwarden,
  Proton Pass and Dashlane open their menus on sign-in, address and card
  boxes and never on search, chat or comments; 1Password and Keeper, locked
  there, put their icon on sign-in boxes only (#203 not reproduced on these
  pages). The world's extensions are put back as found.
- chrome.privacy: NordPass, Dashlane, RoboForm and iCloud Passwords take
  saving, cards and addresses; 1Password, Bitwarden, Proton Pass, LastPass,
  Keeper, Enpass and KeePassXC-Browser take nothing.
- Keeper takes typing (`evals/extensions/keeper_input.py`, farm 5d7a5edf):
  real keys keep all 16 characters and turn its button on. The setup's
  "Log In stays off" came from setting the value by script.
- Idle CPU, four quiet tabs, 20 s: NordPass signed out 190-240% (main and
  fix alike; its own session, branch claude/dazzling-engelbart-855658),
  signed in 2%; Proton Pass 11-19%; Keeper signed out 11%; the rest under 7%.

- Dashlane's menu timed (row 1049, #644: "menus glitch, don't close in
  time", 284 tabs on 0.38.11; `evals/extensions/webcard.py`). Signed out,
  its "Unlock Dashlane to log in" menu is the webcard its signed-in list
  uses, framed from its own page and sized and placed over its worker's
  relay. With 1 tab, 284 kept, and 284 asleep plus 20 awake: up 35-130 ms
  after a click, gone 140-165 ms after a click beside it or Escape (its
  own fade), moved to the password box in about 200 ms, drawn right; the
  same on 0.38.11 and main (farm 6d49fce0, 9c4347d9, 36bf33c4). The relay
  in small (Webcard Relay) answers in 1-35 ms with 61 tabs. Not
  reproduced: the signed-in list (rows, arrow keys, the fill itself) is
  untried, Dashlane isn't signed in to the stand.

## Left to do

- **Keeper's master password in the stand:** `keeper_input.py --kept` didn't
  run (it was chained after the fields run, which exited on key-window rows).
  Run it alone, `--urgent --needs stand-passwords`; then the user types
  Keeper's master password by hand in the stand world.
- **Unlocked 1Password and Keeper:** both locked in the stand. The user
  unlocks them by hand in the stand world; then `password_fields.py --kept
  --only 1password --only keeper`, and check #203 on the boxes Dima names
  (ask him which sites).
- **LastPass with entries:** its vault import failed during setup (the web
  vault errored and the page grew to 2.5 GB). Try the import again and find
  out whether Yab is at fault (the web vault in a Yab tab against Chrome).
- **Dashlane and RoboForm:** accounts exist with the eight logins; sign them
  in to the stand world. Dashlane's sign-in on adhd stopped at its security
  check ("Something went wrong", challenges.cloudflare.com) on 2026-10-20;
  once signed in, row 1049 is tried past sign-in there (its list, arrow
  keys, a fill) with 284 tabs.
- **Enpass and KeePassXC:** pair each app with its extension on adhd (Enpass's
  code; KeePassXC Browser Integration on with Chrome ticked). Then #208's
  slowness with the app running, measured with `idle_cost`.
- **Key window on busy Macs:** rows lost the key window to other jobs on the
  same Mac (`key_window` false). Rerun those managers alone when the farm is
  quiet, or run the eval with `--host` on a Mac with nothing else showing.
- **Fill end to end:** pick a login from each manager's own menu on the
  public test page (the-internet.herokuapp.com) and check the sign-in lands.
  Only Bitwarden's fill is checked today.
- **Feedback and register:** once this ships, mark #192, #193, #203 and #208
  (`scripts/feedback.mjs mark` in fast-web) and add register rows for #203
  and #208 (`pnpm -s requests add`); no replies to reporters until the
  release is out.
