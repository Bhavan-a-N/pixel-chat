# ADR 0027: Production hosting (Render + Neon + Render Key Value)

## Status

Accepted

## Context

Pixel Chat needs a $0 stack for ~3 users: Django ASGI (Daphne) with WebSockets, Postgres, and Redis (Channels + ephemeral presence). The app already handles host idle sleep and reconnect UX.

## Decision

- **Web:** Render free web service, **Docker**, region **Singapore**.
- **Postgres:** Neon free tier, project region **AWS ap-southeast-1 (Singapore)**, connection via **pooled** URL with `sslmode=require`.
- **Redis:** Render **Key Value** (free), same **Singapore** region as the web service, connected over Render private network when possible.

### Health checks

| Path | Purpose |
|------|---------|
| `/health/live` | Liveness only — always 200, **no DB/Redis I/O**. Used for Render health checks and optional keep-warm HTTP pings. |
| `/health/ready` | Readiness — `SELECT 1` on Postgres and Redis `PING`; 503 if either fails. |
| `/health` | Alias for **ready** (backward compatible). |

**Do not** point Render health checks or keep-warm cron jobs at `/health`, `/health/ready`, or any endpoint that queries Postgres. Neon free tier scales compute to zero after idle; unnecessary DB probes keep it awake and consume **CU-hours**.

### Neon database connections

- Use Neon’s **pooled** connection string (PgBouncer), not the direct primary URL.
- Django: `CONN_MAX_AGE=60` (short), `CONN_HEALTH_CHECKS=True`, `sslmode=require` via `dj-database-url`.
- Dropped connections (Neon suspend, network blip) should recover on the next request via health checks and `ensure_connection()`.

### Redis is ephemeral

- Render free Key Value is **in-memory** (no persistence across restart).
- **Authoritative data:** Postgres only.
- **Channels:** group membership is re-established on WebSocket reconnect (`group_add` on connect).
- **Presence:** `presence:user:*` cache keys are TTL-based (~60s); lost on Redis restart → users appear offline until reconnect/refresh; FCM may send extra pushes briefly — acceptable.
- No message content or JWT state lives in Redis.

### Migrations on deploy

- Render **pre-deploy command:** `python scripts/pre_deploy_migrate.py`.
- Applies pending migrations automatically.
- **Blocks** deploy if pending migrations contain `RemoveField` or `DeleteModel` unless `ALLOW_DESTRUCTIVE_MIGRATIONS=true` is set for that deploy after manual review and `pg_dump` backup.

## Consequences

- **Pros:** $0, matches env-only config upgrade path, Singapore latency for Bengaluru users, avoids Neon on health probes.
- **Cons:** Render web **15-minute idle spin-down** (~1 min wake); Neon **DB cold start** after scale-to-zero; free Key Value **25 MB** and volatile; Neon **0.5 GB** storage cap; multi-provider ops (Render + Neon).

## Alternatives considered

- **Render all-in-one Postgres:** rejected due to **30-day free DB expiry**.
- **Northflank sandbox:** always-on but requires card, only one free DB addon, less doc alignment.
- **Fly.io / Railway sustained free:** not available at $0 for this stack.
