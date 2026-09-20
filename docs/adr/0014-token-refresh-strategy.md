# ADR 0014: Single-Flight Token Refresh Strategy

## Status
Accepted

## Context
The Pixel Chat backend uses short-lived JWT access tokens (15 minutes) and 30-day rotating refresh tokens. Because refresh tokens are blacklisted immediately upon rotation, if multiple HTTP requests expire and fail with 401 simultaneously, uncoordinated refresh calls would result in race conditions: the first refresh succeeds, while subsequent refreshes submit an already-blacklisted token, causing the backend to reject them and erroneously force-logout the user.

## Decision
We implement a coordinated **Single-Flight Refresh Interceptor** (`AuthInterceptor`) in Dio:
1. **Separate Refresh Client**: Refresh calls are executed through a separate `refreshDio` instance containing no interceptors to eliminate infinite recursion.
2. **Endpoint Exclusions**: Requests to `/api/auth/login`, `/api/auth/register`, and `/api/auth/refresh` bypass refresh logic entirely.
3. **Token Divergence Check**: When a 401 occurs, the interceptor compares the failing request's bearer token against the current stored access token. If they differ, another concurrent request has already completed a refresh; the interceptor immediately retries the request with the new stored token without invoking the refresh endpoint.
4. **Single-Flight Coordination**: A shared `Completer<String?>` synchronizes all simultaneous 401s so exactly one refresh request is dispatched to `/api/auth/refresh`. All pending requests await this completer and retry with the rotated access token upon completion.
5. **Rotated Token Storage**: Every successful refresh persists both the newly issued access token and the newly rotated refresh token to secure storage.
6. **Strict Logout Boundaries**: The interceptor clears tokens and triggers session termination **only** when the server explicitly rejects the refresh token with HTTP 400 or 401. Network timeouts, connection drops, or 5xx server errors do NOT log out the user.
7. **Decoupled Notification**: The interceptor signals session expiration via a callback (`onSessionExpired`), keeping the network layer completely decoupled from state management notifiers.

## Consequences
* **Pros**:
  - Eliminates refresh race conditions and accidental logouts.
  - Transparently retries failed requests without caller intervention.
  - Prevents network instability from nuking user sessions.
* **Cons**:
  - Requires maintaining a dedicated interceptor with asynchronous queue coordination.
