# ADR 0019: In-Memory Outbox, Deduplication, and Multi-Page Catch-Up

## Status
Accepted

## Context
When users send messages, they expect instantaneous optimistic UI updates, resilient retries if delivery fails, and strict ordering without duplication across network reconnections. Furthermore, when returning online or upon encountering a gap in sequence numbers, the client must seamlessly catch up on missed messages.

## Decision
1. **Optimistic Sending & In-Memory Outbox**:
   - Each outbound message is assigned a client-generated UUID client_id and added immediately to the active state with status = MessageStatus.pending.
   - The message is enqueued in an in-memory _outbox queue.
   - Resends (manual retry or automatic reconnection flush) preserve the exact same client_id so the backend deduplication constraint triggers idempotent responses.
2. **Deduplication & Arrival Order Independence**:
   - The client handles both possible arrival sequences (ck then chat.receive echo, or chat.receive echo then ck).
   - Matching inspects client_id first, transitioning pending messages to sent and removing them from the outbox.
   - Subsequent id-based matching ignores redundant incoming echoes.
3. **Reconnection Flush & Rate Pacing**:
   - When the socket transitions to connected, the outbox is flushed in sequence.
   - Outbox sends are paced by $\ge 550 intervals to strictly comply with the backend throttle limit of 20 sends / 10 seconds.
   - If a 429 error event is encountered during flush, the flush is rescheduled with a backoff delay rather than marking messages permanently failed.
4. **Gap Detection & Multi-Page Catch-Up**:
   - If an incoming message has sequence number seq > highestConfirmedSeq + 1, a sequence gap is identified.
   - The client triggers catchUp(fromSeq: highestConfirmedSeq): querying GET /api/conversations/<id>/messages?after_seq=<seq>&limit=100 in a loop until receiving a short page (< 100).
   - Live events arriving during the catch-up loop are held in a buffer (_liveEventBuffer) and processed in order once catch-up completes.
5. **State Clearing**:
   - On logout, the message state, outbox, and conversation list are cleared.

## Consequences
* **Pros**:
  - Instant UI feedback with zero perceived latency.
  - Safe against double-sends, server rate limits, and live network drops.
  - Gapless, ordered chat history maintained automatically.
* **Cons**:
  - Outbox is in-memory only for this milestone; pending messages do not survive an app process kill before local SQLite persistence is introduced in future milestones.
