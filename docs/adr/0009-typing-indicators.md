# ADR 0009: Typing Indicator Delivery

## Status
Accepted

## Context
Typing indicators show when a user is actively composing a message. We must decide if this state should trigger push notifications or be persisted.

## Decision
Typing indicators will be **WebSocket-only, strictly ephemeral, never persisted, and never sent via FCM push notifications**. 

## Consequences
*   **Pros**: Typing is ephemeral and only useful to connected recipients, so it is WebSocket-only and never persisted or pushed.
*   **Cons**: None. Standard behavior for modern chat applications.
