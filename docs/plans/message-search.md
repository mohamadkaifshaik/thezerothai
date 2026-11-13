# Message search

Flag: `message_search` (server `FEATURE_MESSAGE_SEARCH`, in `GetMe.enabled_features`). UI is shown only when the
flag is on and Messages access is not `hidden` (read-only access may search: it only reads the local cache).

## Scope and decisions

- Only the caller's own conversations.
- Search runs ON THE DEVICE over the cached drift rows. No server-side text index, no new endpoint, no message text
  or query leaves the device. The query is never logged, never put in a URL and never persisted.
- Never matched: messages whose state is not `VISIBLE` (deleted account, moderator-removed, unspecified; the
  protocol has no "unsend" or per-message hide, so "deleted, unsent, hidden" all map to "not VISIBLE"), outbox
  items (in memory, not in `message_entries`), messages in a conversation with no cached header (orphans left behind
  by a blocked request), and conversations with `can_reply == false` (either side blocks, or the peer's account is
  gone: the conservative direction). A block made from the open chat also marks the cached header read-only at once.
- Only the message's own text is matched, never a shared post's content.
- Sign-out: no new tables or columns, so `AppDatabase.clearAll` already covers it (a test proves it).

## Cache finding

`message_entries` keeps the newest 200 messages per conversation (`kMessagesPerConversation`, trimmed on every
write), only for threads opened (or sent to) on this device. Cached headers are the Inbox and Requests pages that
were loaded. So the cache holds recent history of visited conversations, not all history. Payloads are protobuf
blobs, so SQL `LIKE` cannot filter: rows are decoded and matched in Dart. No migration.

"Load older messages": writing older pages into drift would be undone by the 200-row trim, whose invariants stay.
So for ONE conversation the search fetches older pages through the existing `ListMessages` path and holds them in
memory only (dropped when the search closes).

## UI

- Copy: "Searching messages on this device". List results grouped by conversation, newest first, term highlighted,
  case-insensitive; highlight ranges index the original string.
- Messages list: search action in the top bar opens an in-place field that swaps the list for results. In a chat:
  search action searches that conversation only, with "Load older messages".
- Tapping a hit opens `/messages/<id>?m=<messageId>`; the chat scrolls to and highlights it (pages back, bounded,
  if the hit came from older in-memory pages).
- Phone <600 / tablet 600-1199 / desktop >=1200: one cubit, one result model, same actions; paddings and column differ.

## Out of scope

Server-side search, never-opened conversations, attachments, search history, fuzzy or relevance ranking.
