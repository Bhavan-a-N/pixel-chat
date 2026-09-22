# ADR 0020: Conditional Monotonic Pointer Updates

## Status
Accepted

## Context
When clients acknowledge message delivery (`chat.delivered`) or read receipts (`chat.read`), network delays, concurrent device usage, or out-of-order delivery could result in stale or out-of-order acknowledgements. Performing read-then-write updates in application code (`SELECT` then `UPDATE`) introduces race conditions under concurrent acks and wastes database IO.

## Decision
1. **Single Conditional UPDATE**:
   - Pointers only move forward monotonically.
   - For `chat.delivered`:
     ```sql
     UPDATE chat_membership
     SET last_delivered_seq = %(seq)s
     WHERE user_id = %(user_id)s
       AND conversation_id = %(conversation_id)s
       AND last_delivered_seq < %(seq)s
     ```
   - For `chat.read`:
     ```sql
     UPDATE chat_membership
     SET last_read_seq = %(seq)s,
         last_delivered_seq = GREATEST(last_delivered_seq, %(seq)s)
     WHERE user_id = %(user_id)s
       AND conversation_id = %(conversation_id)s
       AND last_read_seq < %(seq)s
     ```
2. **Silent Stale Handling**: If zero rows are updated, the ack is stale or redundant; it is silently ignored with no broadcast and no error.
3. **Commit Broadcast**: When rows are updated, the membership row is re-read for exact persisted values, and a `chat.status` event is broadcast in `transaction.on_commit` to each member's `user_{id}` group. Channel layer failures are logged and caught so the connection is not terminated.
4. **Validation**: Out-of-bounds `seq` (`seq <= 0` or `seq > next_seq - 1`) returns an error event (code 400). Non-members are rejected with code 403.
5. **Rate Limiting**: Status acks are protected by a separate rate limit (60 acks per 10 seconds per connection).

## Consequences
- **Pros**: Perfectly safe under concurrent execution across multiple worker processes without row-level locks. Eliminates duplicate or redundant broadcasts on retransmissions.
- **Cons**: Requires executing a `GREATEST` expression or conditional filter on updates.
