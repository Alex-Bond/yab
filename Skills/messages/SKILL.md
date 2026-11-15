---
name: messages
description: The user's Messages, iMessage and texts: finding a chat, reading it, writing in their voice, and sending with their yes.
sites: []
keywords: [imessage, messages, text, sms, text message, whatsapp-like, chat with, write to]
---

# Messages

Needs Settings › Agents › Messages on, and a task that can use this Mac. The tools are `messages` and
`send_message`; neither opens a tab.

## Finding the person

- `messages` with no chat lists chats, most recent first: an identifier (a phone number like
  `+14155550123`, an address, or `chat123…` for a group), its name if it has one, and the last line.
- Names aren't in Messages itself. Look the person up in memory first (`memory_search` for their
  name: people/ pages keep phones and addresses), then match the number in the list.
- A group is found by its name.

## Before writing

Read the chat: `messages` with `chat` gives its last messages, oldest first, "you:" for the user's own.
Write the way the user writes to this person there: the same language, as short, the same greeting or
none, lowercase if they write lowercase, the same emoji or none. One message, not a letter.

## Sending

`send_message` with `to` (the number or address, not a name) and the text. The user sees the whole
text and says yes; nothing goes before that. It goes as iMessage when the person has it, else as a
text. It can't be taken back: never send to someone the task didn't name, and never send twice.
