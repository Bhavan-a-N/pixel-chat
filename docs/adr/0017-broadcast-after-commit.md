# ADR 0017: Post-Commit Message Broadcast and Per-User Fanout

## Status
Accepted

## Context
When a message is sent over WebSocket or REST, broadcasting the message event to recipients before the database transaction commits risks emitting "phantom messages" that might be rolled back. Furthermore, if each client joins dynamic conversation groups, newly created conversations would require clients to reconnect or receive dynamic group join instructions. Finally, if the ephemeral channel layer (Redis) experiences a temporary network blip or failure after commit, the message is already safely stored in PostgreSQL, and the sender must still be acknowledged rather than crashing the consumer.

## Decision
1. **Post-Commit Broadcast**: We defer channel layer broadcasting until `transaction.on_commit(...)` fires. If the transaction rolls back, zero messages are broadcast.
2. **Per-User Group Fanout (`user_{id}`)**:
   - Each client connection joins exactly one Channels group: `user_{user_id}` on connect.
   - On commit, the application queries all member user IDs of the conversation and iterates over them, sending the `chat.message` event to `user_{member_id}` for every member (including the sender's other connected devices).
   - This design guarantees that conversations created *after* a client has connected will deliver messages to that client immediately without requiring group join updates or socket reconnections.
   - Clients deduplicate incoming messages by `message_id`.
3. **Failure After Commit**:
   - If `channel_layer.group_send` raises an exception after commit, the error is caught and logged.
   - The sending connection still receives its `chat.ack` with the assigned `seq` and `message_id`, because the message is safely persisted in the database.
   - The consumer does not crash. Recipients will catch up upon reconnect or REST sync (`after_seq`).

## Consequences
* **Pros**:
  - Eliminates phantom messages during transaction rollback.
  - Transparent support for multi-device sync and newly created conversations without client-side group management.
  - Resilient to transient Redis channel layer drops.
* **Cons**:
  - Group fanout in application code requires $N$ `group_send` calls for a conversation of $N$ members (trivial at our target group size and scale).
