# ADR 0011: JWT Refresh Rotation

## Status
Accepted

## Context
We need a stateless authentication mechanism for the REST and WebSocket APIs. However, standard long-lived JWTs pose a security risk if compromised.

## Decision
We will use **JSON Web Tokens (JWT)** via `djangorestframework-simplejwt` with the following configuration:
1.  **Access Tokens**: Short lifetime (15 minutes).
2.  **Refresh Tokens**: Long lifetime (30 days).
3.  **Rotation & Blacklisting**: `ROTATE_REFRESH_TOKENS = True` and `BLACKLIST_AFTER_ROTATION = True`. 
4.  When a client uses a refresh token, it receives a *new* access token and a *new* refresh token. The old refresh token is blacklisted.

## Consequences
*   **Pros**: High security. If a refresh token is stolen, using it will either fail (if already used and blacklisted) or result in the legitimate client's subsequent refresh failing (alerting them to the compromise).
*   **Cons**: Requires a database table to track blacklisted tokens, adding a minor DB write on every refresh. Requires a cron job to flush expired tokens from the blacklist table.
