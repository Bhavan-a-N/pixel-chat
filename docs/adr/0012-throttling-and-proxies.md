# ADR 0012: API Throttling & Proxy Configuration

## Status
Accepted

## Context
To prevent brute force attacks on authentication endpoints and abuse of search endpoints, we are applying rate limiting via Django REST Framework's `ScopedRateThrottle`.

## Decision
1.  We apply specific throttle scopes (e.g., `login`: 5/min, `register`: 3/min, `search`: 30/min).
2.  These rates are configurable via environment variables (`THROTTLE_LOGIN`, etc.).

## Critical Deployment Note (Proxies)
Because rate limiting relies on tracking client IP addresses, deployments behind reverse proxies or load balancers (e.g., Nginx, AWS ALB, Render) **must correctly configure the client IP**. 
If the application is deployed behind a proxy without configuring DRF to read the `X-Forwarded-For` header, the throttle will rate-limit the *proxy's IP* instead of the individual clients, potentially locking out all users.

## Consequences
*   **Pros**: Protects critical endpoints from abuse out-of-the-box.
*   **Cons**: Requires careful HTTP header configuration at deployment time.
