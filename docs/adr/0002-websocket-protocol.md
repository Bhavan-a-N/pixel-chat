# ADR 0002: WebSocket Protocol and Sync Strategy

## Status
Accepted

## Context
A chat application requires real-time message delivery. We need a reliable mechanism to deliver messages, acknowledge receipt, and ensure clients can catch up on messages they missed while disconnected. We must decide whether to implement a complex event-sourcing sync protocol entirely over WebSockets, or a hybrid approach.

## Decision
We will use a hybrid approach:
1.  **Real-time Delivery**: A versioned JSON envelope over WebSockets for active chat events (`chat.send`, `chat.receive`, `chat.typing`).
2.  **Idempotency**: Clients generate a UUID (`client_id`) for every outgoing message. The server enforces uniqueness on `(sender_id, client_id)`. If an ACK is lost, the client can safely retry sending without duplicating the message in the database.
3.  **Syncing**: Missed messages are synced via a standard REST API endpoint (`GET /api/messages/sync/?after_id=<id>`) rather than building a custom replay protocol over the WebSocket.

## Consequences
*   **Pros**: Significantly simplifies the WebSocket state machine. The WebSocket is only responsible for "now", while REST handles "the past". HTTP/REST is naturally suited for paginated, large payloads (like fetching days of missed messages).
*   **Cons**: Requires the client to make an extra HTTP request immediately after establishing the WebSocket connection.
