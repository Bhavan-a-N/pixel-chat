# ADR 0018: WebSocket Client Lifecycle, Reconnection, and Auth Handling

## Status
Accepted

## Context
Real-time messaging in Pixel Chat requires a robust WebSocket connection that can handle network blips, application background/foreground transitions, expired access tokens, and server spin-up delays (e.g. cold starts) while preserving an intuitive user experience.

## Decision
1. **Abstraction**:
   - web_socket_channel (IOWebSocketChannel) is hidden behind a WebSocketChannelWrapper interface with a WebSocketConnector function type, enabling comprehensive unit and widget testing with fake channels.
2. **Authentication & Handshake**:
   - The access token is sent strictly in the Authorization: Bearer <token> header during the WebSocket upgrade handshake. No tokens are passed in query strings or message bodies.
   - Pinned timeouts: 10s connection timeout and 20s ping interval to detect dead sockets proactively.
3. **Reconnection & Exponential Backoff**:
   - An injectable BackoffStrategy provides exponential backoff with full jitter (up to 20%), doubling delay on each attempt up to a 30s cap, resetting on successful connection.
4. **Close Code 4401 Handling**:
   - When the server accepts the connection and immediately closes with code 4401 (indicating token expiration), the client calls the shared single-flight TokenRefresher.refreshToken().
   - If refreshed successfully, the socket reconnects immediately with the fresh token.
   - If the fresh token *also* yields 4401, or if refresh is rejected with 401/400, the client clears tokens and logs out (breaking any potential reconnection loop).
   - If token refresh fails due to a network error, the client does not log out; it continues backoff retries.
5. **Server Waking State**:
   - The connection state transitions to serverWaking upon handshake timeout, 503 HTTP responses during handshake, or 3+ consecutive connection failures, rendering a friendly banner.
6. **Lifecycle Management**:
   - An AppLifecycleManager observes AppLifecycleState: pausing/closing the socket when the app goes into the background, and reconnecting when resumed.
   - The socket connection exists only while the user is authenticated.

## Consequences
* **Pros**:
  - Resilient to network disruptions, expired tokens, and mobile app lifecycle pauses.
  - Zero token exposure in URLs or logs.
  - Complete testability with mocked channels and deterministic fake timers.
* **Cons**:
  - Requires maintaining lifecycle hooks and single-flight token refreshing between HTTP and WebSocket layers.
