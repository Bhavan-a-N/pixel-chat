# ADR 0024: Fanout Access Control and Open Socket Safety

## Status
Accepted

## Context
In a real-time WebSocket chat system, users maintain long-lived connections across group membership changes. If a user is removed from a group while their WebSocket connection remains open, two critical security hazards must be prevented:
1. The removed user must not receive subsequent broadcast frames (messages, typing events, membership changes) sent to that group.
2. The removed user must not be able to send frames (messages, acks, typing events) to that group through their existing connection.

## Decision
1. **Atomic Recipient Fan-Out Computation**:
   - The set of recipient user IDs for every message or event broadcast is computed *inside the locked database transaction* (`select_for_update`) or read directly from the current database state immediately prior to dispatch.
   - We do not rely on static Channels group subscriptions (e.g. `conversation_<id>`) that could linger on open sockets across membership removals. Instead, messages are dispatched to per-user channels (`user_<user_id>`), guaranteeing that removing a user from `Membership` instantly and completely removes them from future fan-outs.
2. **Instant Removal Signal (`membership.removed`)**:
   - When a member is removed (or leaves), a `membership.removed` frame is immediately sent to all current members including the removed member.
   - Upon receiving `membership.removed`, client instances discard any queued messages in their outbox for that conversation, halt retry attempts, and transition the conversation UI to an archived/removed state.
3. **Open-Socket Send Verification**:
   - When the WebSocket consumer receives an incoming frame (`chat.send`, `chat.delivered`, `chat.read`, `chat.typing`), it queries `Membership.objects.filter(conversation_id=..., user=...)` before processing.
   - If the user is no longer a member, the action is rejected immediately with an error event (`403 Forbidden` / `Not a member`), preventing any message insertion or sequence advance.
4. **Concurrent Remove and Send Serialization**:
   - Both `send_message` and `remove_group_member` acquire a `select_for_update()` lock on the parent `Conversation` row, guaranteeing strict serialization under concurrent race conditions.
   - One of two consistent outcomes is guaranteed:
     - **Removal wins race**: The removal transaction commits first, deleting the target's membership. The concurrent send then acquires the conversation lock, detects that the user is no longer a member, and is rejected with `PermissionDenied` (HTTP 403 / error event). No message is persisted, and no sequence number is consumed.
     - **Send wins race**: The send transaction commits first, assigns the next monotonic sequence number, and delivers the message to all members (including the target, who was still a member at send time). The subsequent removal transaction then acquires the lock and removes the member, assigning the next sequential number to the `member_removed` system message.
   - Under no circumstances can partial state occur: there are no sequence gaps, no messages without recipients, and no server crashes.

## Consequences
- **Pros**: Zero possibility of information leakage to ex-members with open sockets. Outbox retries are cleanly terminated. Strict row-level serialization ensures atomic consistency under concurrent remove and send races without deadlocks or sequence gaps.
- **Cons**: Per-send membership checks add a fast index lookup, which is mitigated by PostgreSQL composite indexes on `(conversation_id, user_id)`.

