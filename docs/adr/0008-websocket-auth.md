# ADR 0008: WebSocket Authentication

## Status
Accepted

## Context
We need to authenticate clients connecting to the Django Channels WebSocket endpoint securely.

## Decision
1.  **Handshake**: Authentication relies on the `Authorization` HTTP header during the initial WS handshake.
2.  **Validation**: The token is validated at connect only.
3.  **Expiration Handling**: If the token is expired, the server rejects the connection and closes with a custom code `4401`. The client will catch this, refresh the token via REST, and reconnect.
4.  **Fallback Mechanism**: If intermediate host proxies (e.g., reverse proxies, load balancers) strip WebSocket headers, we will fall back to passing the token in the first message sent over the WS.

## Consequences
*   **Pros**: Highly secure standard approach. Clear separation of concerns (auth on connect, data on channel). Built-in resilience against proxies stripping headers.
*   **Cons**: Custom code 4401 requires specific handling in the Flutter client's retry loop.
