# ADR 0003: Message Read and Delivery State Strategy

## Status
Accepted

## Context
We need to track which messages a user has successfully received (delivered) and read. In v1, there are only direct messages (DMs), but the architecture must support group chats without a rewrite. Creating a `MessageStatus` database row for every user for every message leads to unbounded exponential data growth (O(Users * Messages)). Additionally, comparing UUIDs for catch-up mechanisms does not guarantee strict ordering.

## Decision
1.  **Monotonic Sequence**: Every message will be assigned a per-conversation monotonic integer `seq` upon insertion. This guarantees strict, sortable ordering.
2.  **State Pointers**: We will track delivered and read states using **two pointers per user per conversation**: `last_delivered_seq` and `last_read_seq`.
3.  These pointers will be stored on the `Membership` table (which maps a User to a Conversation).
4.  When a client receives or reads a message, it sends a `chat.delivered` or `chat.read` event with the latest message `seq`. The server simply updates the `Membership` row.

## Consequences
*   **Pros**: Constant space requirement per user per conversation (O(Users * Conversations)). Highly efficient to query ("give me all messages after seq X"). Naturally solves message ordering without relying on UUID timestamps. Group-chat ready out of the box.
*   **Cons**: We cannot track if a user read a specific message out of order (e.g., skipped a message). This is an acceptable tradeoff as modern chat apps assume sequential reading. Requires transactional locking (e.g., `SELECT FOR UPDATE` on the conversation row) during message inserts to guarantee `seq` increments without gaps or collisions under concurrent loads.
