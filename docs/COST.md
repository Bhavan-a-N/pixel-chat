# Cost and Service Limits

Infrastructure targets **$0** today (Candidate B). No paid services required for ~3 users.

## Storage (Postgres — Neon free)

- **Service:** [Neon](https://neon.tech) free plan, region **ap-southeast-1 (Singapore)**.
- **Limit:** **0.5 GB** storage per project; **100 CU-hours** compute per project per month; scale-to-zero after ~5 min idle.
- **Users:** ~3
- **Usage estimate:** ~1 KB/message (indexes included) → ~50–100 MB/year at heavy use.
- **Retention:** deferred (ADR 0001); revisit near ~70% of tier capacity.

## Application hosting (Render free web)

- **Service:** Render web service (Docker, Daphne), region **Singapore**.
- **Limit:** 512 MB RAM, 0.1 CPU; **750 instance hours/month**; spins down after **15 min** idle (HTTP or WS messages reset timer); ~**1 min** cold start.
- **Health check:** `/health/live` only (does not query Neon).

## Redis (Render Key Value free)

- **Service:** Render Key Value, region **Singapore** (same as web).
- **Limit:** ~**25 MB** RAM, **in-memory** (data lost on restart); ephemeral Channels + presence only.
- **Note:** Not used for durable data.

## CI/CD

- **Service:** GitHub Actions
- **Limit:** 2,000 minutes/month (private repos); current usage: backend + Flutter workflows per push.

## External services (not in use yet)

- **FCM:** not configured in v1 deploy scope.
