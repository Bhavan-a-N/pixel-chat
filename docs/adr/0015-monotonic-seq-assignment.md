# ADR 0015: Monotonic Sequence Assignment Under Concurrent Sends

## Status
Accepted

## Context
Messages in Pixel Chat must have a strictly monotonic, gapless, and orderable per-conversation sequence number (`seq`). Clients rely on this sequence number for message ordering, read/delivered pointer updates, and delta synchronization via `after_seq`. When multiple members of a conversation send messages simultaneously, race conditions must not produce duplicated or skipped sequence numbers.

## Decision
1. Each `Conversation` maintains a persistent integer counter: `next_seq` (initial value 1).
2. During `send_message`, the transaction issues a row-level lock on the conversation row:
   ```python
   conversation = Conversation.objects.select_for_update().get(id=conversation_id)
   ```
3. The message is assigned `seq = conversation.next_seq`, and `conversation.next_seq` is incremented and saved in the same transaction.
4. Database constraint `UniqueConstraint(fields=['conversation', 'seq'])` guarantees uniqueness at the schema level.
5. Idempotent duplicate sends (matching an existing `(sender, client_id)`) return the existing message without locking or incrementing `next_seq`.

## Consequences
* **Pros**:
  - Guarantees strict monotonicity and eliminates gaps under concurrent sends.
  - Keeps conversation ordering logic deterministic and simple.
* **Cons**:
  - Serializes writes per conversation through row-level locking (acceptable at target scale and standard for chat rooms).
