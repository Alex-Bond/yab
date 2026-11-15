# First Edition gifts

A manual thank-you for useful early feedback, independent of invitations
and public posts. The selected art is the transparent metal badge from
`work/design/yab-early-users-2026-10-20/01-first-edition-transparent.png`.
`001` names the edition, not the recipient's member number.

## Award and delivery

In the site's `/admin/inbox`, open a report and choose **Prepare First
Edition reply**. The report must have a valid email. All reports from the
same trimmed, lowercase email share one gift, enforced by a database unique
constraint, including concurrent requests. Different email addresses are
not assumed to belong to the same person.

Preparing reserves the reply. Another support session sees **Reply in
progress**, cannot get a second link, and must not send. The preparing tab
can resume after a reload. The register at `/admin/gifts` shows recipient,
source report, preparation, delivery reference and claim date. Copying is
not sending. After actually delivering the message, enter the conversation
URL or date and channel and press **Mark sent**. That date/reference are
kept on retries. A sent or claimed gift cannot be prepared again.

**Cancel unsent reply** explicitly releases the reservation while retaining
the same gift/link. A reservation never times out automatically: an uncertain
delivery must be checked in the conversation before any retry. Browser
reservations live in that tab's session storage. If the tab is lost, an
operator must reconcile the actual conversation before resetting the
reservation in the database; do not create another award.

Agents reading feedback see the register with `pnpm gifts status EMAIL` in
`fast-web`. `pnpm gifts prepare FEEDBACK_ID` reserves there, with a key
kept per sending session under `~/.local/state/yab-gifts/`. Codex's thread
ID or Claude's session ID separates senders automatically; otherwise set a
unique `YAB_GIFT_SENDER` and reuse it for that reply. After an authorized send,
`pnpm gifts sent GIFT_ID "THREAD_URL"` records it. `pnpm gifts release ID`
is only for a reply confirmed unsent. These commands never send messages.
All senders, including agents, must use this reservation protocol and check
the actual conversation first. No system can deduplicate mail sent outside
it or infer that two different addresses are the same person.

## Receiving

The recipient opens `/gift/TOKEN` in a supporting Yab and clicks **Use
icon**. Page reads and link previews do not consume the gift. An app POST
atomically claims it for the installation; retrying from that installation
returns the same receipt. Another installation cannot use the link.
The receipt is a separate random secret, saved as `gift.firstEdition.receipt`
and encrypted through the existing Sync settings. Restore Sync to recover
it on another Mac or after reinstalling. Without a Sync backup, reply to the
gift email for manual recovery; the link alone cannot be redeemed twice.

Once claimed, Yab switches to the icon and says "First Edition is yours,
thanks" in the corner (one line: a longer notice is cut in its middle).
The icon is hidden until received, then appears in Settings → App Icon.
Choosing it uses the existing Dock icon/quit persistence. Its ICNS files
use the same Icon Composer rounded backing and light/dark fill as the other
alternate icons, with the supplied badge art unchanged.
The signed app's built-in icon and bundle identity stay as they are.

## Rollout

Apply **only** `fast-web/db/feedback-gifts.sql` (also appended to schema.sql)
before deploying the new admin queries/API. Deploy the website and include
the native files/art/build change in a subsequent Mac release. Older apps
show the gift page's update instructions and cannot consume the link.
Do not send real gifts until that Mac release is available.

The gift path is excluded from visit counters and Google Analytics, has
no-referrer metadata and no-index metadata; the claim API returns only the
icon and receipt, never recipient/contact or delivery data.
