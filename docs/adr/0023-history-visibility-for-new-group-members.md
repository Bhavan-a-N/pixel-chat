# ADR 0023: History Visibility for New Group Members and Join Point Assignment

## Status
Accepted

## Context
When a user is added to an existing group conversation, historical messages sent prior to their arrival may contain sensitive conversations that the new member should not see. Furthermore, message sequence numbers (`seq`) and delivery/read pointers are monotonic and scoped to each conversation. We must define how history visibility is bounded for new members and how their delivery and read pointers are initialized.

## Decision
1. **Join Point Recording (`joined_at_seq`)**:
   - Each `Membership` record stores `joined_at_seq` (integer, default 0).
   - For initial creators and members added at creation time, `joined_at_seq = 0`.
   - When new members are subsequently added to an existing group:
     - The join point is captured *immediately before* the `"user added"` system message is generated:
       $$\text{joined\_at\_seq} = \text{conversation.next\_seq} - 1$$
     - The new member's initial delivery and read pointers are initialized to this join point:
       $$\text{last\_delivered\_seq} = \text{last\_read\_seq} = \text{joined\_at\_seq}$$
     - The system message announcing the addition is then assigned $\text{next\_seq} = \text{joined\_at\_seq} + 1$, ensuring the new member sees the addition system message as their very first event.
2. **Re-added Members**:
   - If a previous member who left or was removed is re-added, their membership is re-created with a new `joined_at_seq` reflecting their new join point. They do not regain visibility into messages sent during their absence.
3. **Query Filtering & Pagination Enforcement**:
   - `GET /api/conversations/<id>/messages`: Messages are strictly filtered by `seq > membership.joined_at_seq`.
   - Cursor pagination (`before_seq`, `after_seq`) cannot bypass `joined_at_seq`: `before_seq` queries are clamped so messages with $\text{seq} \le \text{joined\_at\_seq}$ are never returned.
   - Conversation list (`GET /api/conversations`): The `last_message` preview subquery filters messages by `seq > membership.joined_at_seq`, ensuring new members do not see snippets of messages sent before they joined.

## Consequences
- **Pros**: Clear privacy boundary. Simple O(1) integer comparison in SQL queries. Eliminates complex per-message access-control lists.
- **Cons**: Users cannot see past history unless explicitly forwarded or invited with a distinct historical-sharing mechanism.
