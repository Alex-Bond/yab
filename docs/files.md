# Files

⇧⌘J opens Files: everything that came to this Mac through Yab or left it,
in one list. It grew out of the downloads place, and downloads are still
its first rows. Concept and every state:
[prototype](prototypes/files-purchases-2026-10-21/prototype.html),
published at https://claude.ai/artifact/PSpTWg3EnDCwjxrDtenRMP.

Code: `FileShelf.swift` (mail's files, what you gave sites, the words
inside), `Places.swift` (`downloadItems`, `shelfActions`), `PlaceViews.swift`
(the preview's head and lines), `FormFiles.swift` (`FileRows.shelfRows`),
`AgentBenchShelf.swift` and `McpToolsShelf.swift` (the agent's tools).

## What is in it

- **Downloaded**: Loot's list, as before: In Progress first, then each
  file with the page it came from.
- **From Mail**: every file a mail of the last year carried (attachments,
  and the pictures pasted into a mail's words, Apple Mail's and Gmail's
  "[image: image.png]", a `cid:` part of 4 KB or more, so no logo spacer or
  tracking pixel), from every connected account, with
  who sent it and the thread. `MailStore.shelf(since:limit:)` reads them; a
  file not fetched yet is listed by its name and kind and fetched the first
  time it is opened, copied or shown (`FileShelf.fetch`, MailFiles).
- **Sent by You**: files your mail carried out, and files given to a site's
  file field, by you (Attach in the file place) or an agent (`upload`),
  kept in `files-sent.json`, the last 200.

The filter at the field's end (⌘P) steps All Files, Downloaded, From Mail,
Sent by You, Images, Documents. Only Site keeps the list to a site or a
sender's domain.

## The words inside

A search looks in names, in where each file came from (the sender, the
mail's subject, the site) and in the words inside: a PDF's text, a Word,
RTF, HTML or text file's. "security deposit" finds the lease a landlord
mailed, and its row says the words around what was found instead of its
source. The words are read in the background when the place opens, for
downloads still on the disk and mail's files already fetched, and kept in
`file-words.json` by each file's date (60,000 characters a file, 800
files). Pictures are not read for words yet.

## A row

↩ opens it (fetched first when it is mail's), ⌘↩ copies the file, ⌘O goes
where it came from: the mail's thread, or the site. Show in Finder, Copy
Path, and for something given to a site, Remove from List. The preview
shows who it came from or went to, the mail's subject (a link to it), when,
its size and where it is.

## A page's file field

When a page asks for a file, the Files place it opens lists, before Recent:

1. **Sent to <site> Before**: what this site was given, newest first, three
   at most. The passport scan United had in September is the first row the
   next time United asks.
2. **From Mail**: files of the last two months' mail already on this Mac,
   five at most, kept to what the field takes (`accept`).

## For agents

- `files_search` (query, from: downloaded | mail | sent, limit): what Files
  lists, newest first, each with an id and its path when it is on this Mac,
  and the words around a match inside; a picture a mail's words drew says
  "(inline in the mail)".
- `files_read` (id or path, `FileShelf.give`): the file's path on this Mac
  first (`path: …`, a mail's file fetched when it isn't here yet), then
  its words, at most 20,000 characters, fenced as data: a PDF's, a
  document's, a text file's, the words read in a picture. A picture
  without words, a video or a sound answers its path alone, never an
  error, so an agent can look at it, upload it or attach it. Only files
  Files lists, and the files the person gave the chat (attached, pasted,
  dropped) by the path their message names (`AgentBenchGiven`): never an
  arbitrary path. A chat kept to the browser has no file reader of its
  own, so this is how it opens what was pasted into it. A picture comes
  back as a picture too (`image`, its long side at most 2048 px, a
  screen's as a PNG, a photo's as a JPEG).
- From a terminal: `yab files search [WORDS] [--from downloaded|mail|sent]
  [--limit N]` and `yab files read ID|PATH [--path]` are those two tools
  called once (`CliFiles`, `Mcp.once`), with their refusals and the
  person's yes for mail; `--path` prints the path alone, for a script.
- A path from files_search goes to `upload` or `mail_draft`'s files; a
  mail's file may go up from where MailFiles keeps it (`AgentFiles.refuse`
  lets that folder through), the card still asking first.
- Mail's files ask as mail reads do (`mailAsks`): the person's yes for the
  chat, or Mail you hand to Claude on. Downloads and what was given to
  sites are like History and ask nothing.

## Testing

`Tests/FastTests/FileShelfTests.swift`: what a site was given, the words
inside, the agent's search, files_read's path for a picture and a video, a
page field's first rows. `MailAttachmentTests` holds Files' inline
pictures and their 4 KB floor. `AgentBenchGivenTests`: the picture an agent
is shown. `evals/chat-picture`: a screenshot pasted into a chat with Claude
kept to the browser, read back through files_read.
