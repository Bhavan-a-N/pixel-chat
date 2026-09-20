# ADR 0006: Presence Tracking Strategy

## Status
Accepted

## Context
We need to track user online presence to accurately route push notifications versus WebSocket events. 

## Decision
We will use a hybrid presence strategy:
1.  **Heartbeat**: The foregrounded app sends a ping every 30s to refresh a Redis TTL set to ~60-90s.
2.  **Disconnect Hook**: The server will also immediately mark the user as offline upon a TCP WebSocket disconnect.
3.  **Backgrounding**: The heartbeat stops immediately when the app is backgrounded.

## Consequences
*   **Pros**: Maximizes accuracy. Handles both clean disconnects (instant status update) and ungraceful drops (e.g., cell tower loss, caught by the TTL). Saves battery by stopping the heartbeat in the background.
*   **Cons**: Requires handling presence cleanup in the Django Channels `disconnect` handler.
