# ADR 0004: Push Notification Strategy (FCM)

## Status
Accepted

## Context
Firebase Cloud Messaging (FCM) is required to notify Android users of new messages when the app is in the background or closed. However, sending FCM pushes while the user is actively chatting in the app is wasteful and causes annoying duplicate notifications.

## Decision
We will conditionally fire FCM pushes based on **Redis Presence**.
1. Active WebSocket connections will maintain a short-lived presence key in Redis (`presence:user:<user_id>`) with a 60-second TTL, refreshed every 30 seconds via heartbeat.
2. When the Django backend saves a new message, it will query Redis for the recipient's presence key.
3. If the key exists, the backend skips sending the FCM push and relies entirely on the WebSocket `chat.receive` event.
4. If the key does not exist, the backend dispatches an FCM push notification.

## Consequences
*   **Pros**: Drastically reduces FCM API calls. Prevents double-notifications on the client side. Accurately handles edge cases where the app crashed but the server hasn't noticed the TCP drop yet (thanks to the short 60s TTL).
*   **Cons**: Adds a Redis read dependency to the critical path of sending a message. Given Redis's sub-millisecond latency, this is acceptable.
