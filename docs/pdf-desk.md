# PDF desk: read, mark, put together, sign

The next round after [Fill and Sign](pdf-sign.md). A PDF comes by mail, gets
read, marked, has its pages put in order, gets filled and signed, and goes
back, all in its tab. The agent can do the filling for the person, and the
signing after the person's yes.

Prototype (clickable, 5 modes and the whole path from the letter to the
reply): artifact "Yab PDF Desk",
https://claude.ai/artifact/BeXd8Dc4iiBDDQ5Sz26Bxj, source
`docs/prototypes/pdf-desk-2026-10-24/index.html`.

## Where Yab is against Acrobat

| Task | Acrobat | Yab now |
|---|---|---|
| Read, find, print | [find](https://helpx.adobe.com/acrobat/using/searching-pdfs.html), [print](https://helpx.adobe.com/acrobat/desktop/print-documents/set-up-and-print-pdfs/print-settings.html) | yes, WebKit's viewer |
| Fill a form | [yes](https://helpx.adobe.com/acrobat/desktop/work-with-pdf-forms/fill-sign-forms/fill-sign.html) | boxes, ticks, lists, profile hints (`FormRules`) |
| Text and signature | [yes](https://helpx.adobe.com/acrobat/desktop/work-with-pdf-forms/fill-sign-forms/fill-sign.html) | yes, trackpad, initials, ⌘Z |
| Highlights and notes | [mark](https://helpx.adobe.com/acrobat/desktop/share-and-review-documents/review-documents/add-markups.html), [comment](https://helpx.adobe.com/acrobat/desktop/share-and-review-documents/review-documents/add-comments.html) | none |
| Reorder, delete, extract pages; join PDFs | [organize and combine](https://www.adobe.com/acrobat/how-to/merge-combine-pdf-files-online.html), [extract](https://helpx.adobe.com/acrobat/desktop/edit-documents/organize-pages/extract-pages.html) | none for the person |
| Text in scans | [OCR](https://www.adobe.com/acrobat/how-to/ocr-software-convert-pdf-to-text.html) | Vision is in Yab, not wired to PDF |
| Questions to the document | [AI Assistant](https://www.adobe.com/acrobat/generative-ai-pdf.html) | Files reads flat text, first 20 000 characters, no pages |
| Edit the words, export to Office | [edit](https://helpx.adobe.com/acrobat/desktop/edit-documents/edit-text-in-pdfs/modify-text.html), [export](https://helpx.adobe.com/acrobat/using/exporting-pdfs-file-formats.html) | no |
| Ask others to sign, track it | [yes](https://helpx.adobe.com/acrobat/desktop/e-sign-documents/request-e-signatures/send-for-signing.html) | own signature only |

Adobe sources checked on 2026-10-24. The column covers Acrobat's product
family; availability depends on the feature and plan.

## Plan

**R1, one release.**

The first implementation tranche is item 1: persistence and restoration
under the existing Fill & Sign UI, with unit tests and a real process
relaunch check. New panels, marking, page operations and agent tools are
subsequent tranches. There is no promise of persisted Undo history across
a restart; restored edits remain editable and subsequent edits undo normally.

**Foundation status, 2026-10-24:** implemented under the existing UI. Fields,
free text, custom signature ink, pending editor drafts, page/zoom and Mail
origin survive relaunch; the source bytes stay unchanged. Autosave coalesces
100 rapid edits into one content snapshot; viewport-only saves reuse it.
[34 tests passed](../work/pdf-desk-persistence-20261024-a94f190b41c94470/appkit-gate-tests/result.json),
including the native page-gap and document-end regression.
[32 native end-to-end checks passed](../work/pdf-desk-persistence-20261024-68f6aeb85c434883/pdf-restart/results.json):
graceful quit, settled hard termination, Undo/Redo, rendered signature in the
final export, editable reopen and explicit Discard. Captures and `Final.pdf`
are beside that receipt. Tests cover this PDF patch on baseline
`2efc2bf1c75b362be1556857bd1f626c5b3aea8d`; the full parallel dirty checkout
was not verified after its initial build failed in unrelated `Bench.swift`.

1. **Working copy apart from the final file.** Today Done always flattens
   (`PDFFill.flattened`, `PDFFill.swift:249`). Split it: a working copy that
   keeps boxes, notes and page order editable, saved on its own and opened
   again after a restart at the same page; and a final copy made only for
   sending. The original is kept byte for byte. This is the ground for
   everything below.
2. **Highlight, underline, note.** Three colors, a pinned note, delete, ⌘Z.
   Standard `PDFAnnotation` (`.highlight`, `.underline`, `.text`) so Preview
   and Acrobat show them. Built into `PDFDesk`; WebKit's light viewer stays
   until a mode is pressed. Going between viewing and a mode keeps the page,
   the zoom, the selection and the find.
3. **Pages.** One panel of thumbnails: drag to reorder, rotate, delete, save
   the picked pages as a new PDF, insert another PDF (the mail's second
   attachment offered first). `PDFDocument` `insert`/`removePage`/
   `exchangePage`; joining is already done in `PageSaveBook.swift:70`. Boxes
   and notes stay on their page when it moves; numbers in notes follow.
4. **Join from Documents.** Pick two PDFs in Files (⇧⌘J) and Combine; the
   result opens in the pages panel.
5. **Status on the file.** A PDF attachment in Mail and its row in Files say
   what is left: "needs signature", "3 items left", "working copy".

**R2.**

6. **Text in scans.** Vision on demand per page, text and boxes kept beside
   the working copy, then used by find, copy and highlights.
7. **Questions with page links.** The agent reads page ranges, not one flat
   text, and every answer carries a link to the sentence it came from. A
   scan without text is named in the answer with "Recognize text".
   (`MailFiles.swift:655` is the 20 000 character cut today.)

**Later.** Making a file smaller for an upload limit, a scan from the iPhone
camera, asking other people to sign, real redaction (checked that the words
are gone from the file), editing the words, export to Word and Excel.

**R1 is done when:** a file with notes opens in Acrobat and Preview with them;
edits live through a restart; every page action undoes; notes and boxes move
with their page; the signature is in the final copy; the original is
unchanged.

## Design

From the prototype; native look as in Fill and Sign (`CaptureGlass`, the
plate, the bar).

The prototype shows the eventual flow. R1 does not expose Ask, Recognize
text or compression as working controls: Ask and OCR belong to R2, and
compression is later. New visible controls follow the owner's picture
review before implementation.

- **The bar** over the PDF: **Read · Mark · Pages · Fill & Sign · Ask**, zoom,
  Undo, **Done**. Fill & Sign carries "N left". Under the file's name:
  "working copy · saved just now · original kept".
- **Read.** Thumbnails at the left, the pages, a right panel with find (its
  matches listed by page), the contents and the file's facts. A scan page
  says "scan, no text" with **Recognize text**.
- **Mark.** Tool Highlight · Underline · Note, three colors. A click on a
  sentence marks it, again takes it off; Note pins where clicked. The panel
  lists every mark by page and goes to it.
- **Pages.** The thumbnails fill the window. Each says what rides with it
  ("1 mark · 1 note · 3 fields"). Rotate, Move earlier/later, Delete, Save
  selected as PDF, Insert guarantor.pdf.
- **Fill & Sign.** A list of what is required with a ring of progress and Go
  per item; **Fill 3 fields** from the profile and a date found in the mail
  ("Move-in date found in Jordan's email"); Place signature; Initial every
  page.
- **Ask.** Suggested questions, answers with `p.2 §5` links that scroll and
  flash the sentence.
- **Done** is a sheet: **Final copy to send** or **Keep working**. For the
  final copy: include my notes (off), make it smaller, and where it goes:
  Reply to the sender (a draft in Mail with the file, sending is the
  person's), the upload box on the open site, or Downloads. Anything
  required and empty is named at the top with Go to Fill & Sign.
- **Restored** after a restart: "Restored where you left off: page 2, 1
  highlight, 1 note."

## Signatures kept in Preview

Checked on this Mac (macOS 27.0.1, 26A434), 2026-10-24.

- **Reading them is not possible.** Preview keeps signatures in its own
  sandbox, `~/Library/Containers/com.apple.Preview/Data/Library/...`, and
  there is `~/Library/Group Containers/com.apple.PreviewLegacySignaturesConversion`.
  Both answer "Operation not permitted" to another app (macOS App Data
  protection), and a Yab build would get the same, with a prompt at best.
  Older notes describe the file `com.apple.Preview.signatures.plist` as
  encrypted with a keychain key ("Signature Annotation Privacy"); no such
  keychain item is on this Mac now. There is no public API (PDFKit, Quick Look
  or Markup) that lists or returns the person's signatures. Reading the
  container would be private, break between macOS versions and look like
  taking someone's signature, so we don't.
- **What we can do instead, all with the person's own action:**
  1. **From a PDF they signed before.** First verify extraction on a real
     PDF saved by Preview on the target macOS version. If the signature is
     preserved as a separate annotation, read its drawing from the file and
     keep it in Yab's keychain (`SignatureKeychain`). Do not assume every
     signed PDF has a separately extractable signature. If it does not,
     offer selection of its visible area and a preview rather than silently
     choosing an image. Files already knows the person's PDFs; the person
     picks the file, confirms that the signature is theirs and sees the ink
     before it is kept.
  2. **Paste or drop.** In Preview's Markup the person copies a placed
     signature, or drops a PNG of it, into Yab's signature sheet; Yab takes
     the ink with nothing behind it.
  3. **Draw once** as today (trackpad, mouse, typed), then it syncs to their
     own iPhone through Sync (later).
  The first one is the one worth building: it is the one where the person
  already has the signature and does not need to know where it lives.

## The agent fills everything for you

Today the agent's `pdf` tool only saves a page as PDF; `pdf_fill` is named
in Fill and Sign's "not in this round". What it needs:

Six tools follow, including `pdf_mark`. Read-only does not bypass source
access: tools inherit the existing Mail/Files permissions, including a mail
read confirmation when access has not already been granted. Filling records
the source of each supplied value for the signing review; an email or PDF
is input data, not authorization to sign or send.

- **`pdf_read`** (a tab or a file from Files): pages with their text by page
  (and the recognized text of scans), the boxes in reading order with id,
  page, kind, label and value, the signature boxes, initials boxes, and what
  is required. Read only; no additional card once source access is allowed.
- **`pdf_fill`** `{tab, values: {boxId: text | true | choice}}`: puts words,
  ticks and choices in, each a step of ⌘Z, in the pen's blue, shown live in
  the tab. Fills from what Yab already has: the profile (`profile`), kept
  answers (`form_answers`), the mail the file came with (dates, addresses,
  amounts), and the person's files. `FormRules` holds for the agent as for
  hints: no ids, money, dates of birth or signatures guessed; those it asks
  for. No card for filling: it is an editable working copy.
- **`pdf_sign`** `{tab, box | page+point, signature: "Signature 1" | "Initials 1", every_page?: bool}`:
  only with the person's yes on a card, the way `mail_send` and paying ask.
  The card shows the document, the page and the place, and every box the
  agent filled. The yes is bound to the document revision, filled values,
  selected signature and all placement targets, including every page when
  initials repeat. A relevant change invalidates that approval; retries of
  the same approved operation must not duplicate signatures. The agent never
  sees the signature's picture; Yab puts it in from the keychain.
- **`pdf_pages`** `{tab, order?, rotate?, delete?, insert_file?}` and
  **`pdf_mark`** for highlights and notes, both undoable, no card.
- **`pdf_finish`** `{tab, final: bool, include_notes?, to: "reply" | "upload" | "downloads"}`:
  the final copy, then a Mail draft (sending stays `mail_send`'s yes), the
  upload box on the open site (`upload`), or Downloads.

The flow for "sign the lease Jordan sent": `mail_read` → open the attachment
→ `pdf_read` → `pdf_fill` from the profile and the letter, asking only for
what it cannot know → a card with all of it and the place to sign → yes →
`pdf_sign` → `pdf_finish(to: reply)` → a draft reply → `mail_send` after a
second yes. Two action confirmations in this reply flow, one to sign and
one to send, with source-read access already allowed. Uploads retain the
existing upload approval and bind it to the final file and destination.

Out: signing for the person without a yes, a signature the person did not
make, certificate signatures.
