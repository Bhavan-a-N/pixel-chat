# ADR 0009: Typing Indicator Delivery

## Status
Accepted

## Context
Typing indicators show when a user is actively composing a message. We must decide if this state should trigger push notifications or be persisted.

## Decision
Typing indicators will be **WebSocket-only, strictly ephemeral, never persisted, and never sent via FCM push notifications**. 

## Consequences
*   **Pros**: Typing indicators are only useful to recipients who are actively looking at the screen (connected). This decision prevents spamming users with unnecessary push notifications and saves massive amounts of database storage and FCM quota.
*   **Cons**: None. Standard behavior for modern chat applications.
