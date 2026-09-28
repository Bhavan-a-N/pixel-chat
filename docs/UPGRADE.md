# Production Upgrade Guide

Moving from the current **free** stack (Render web + Neon Postgres + Render Key Value) to paid production is **configuration and dashboard changes**, not application rewrites.

## Current free topology

| Piece | Free tier | Limitation |
|-------|-----------|------------|
| Render web | 512 MB, 0.1 CPU | Spins down after 15 min idle; ~1 min wake |
| Neon Postgres | 0.5 GB / project | Scale-to-zero after ~5 min idle; 100 CU-hours/month |
| Render Key Value | ~25 MB RAM | No persistence; restarts wipe Redis |

## 1. Database (PostgreSQL)

**Upgrade when:** approaching 0.5 GB, need PITR/backups, or tired of Neon suspend latency.

1. Create Neon **Launch/Scale** (or another provider: RDS, Render paid Postgres).
2. `pg_dump` from current Neon (see `scripts/backup-db.ps1`).
3. Restore to new instance.
4. Update Render `DATABASE_URL` to the new **pooled** URL.
5. Redeploy web service.

## 2. Redis

**Upgrade when:** connection limits, need persistence, or larger channel volume.

1. Create Render **paid** Key Value (persistence enabled) or managed Redis elsewhere.
2. Update `REDIS_URL` on Render.
3. Redeploy. Clients reconnect; no data loss (messages live in Postgres).

## 3. Application host

**Upgrade when:** eliminate spin-down, need more RAM/CPU, or 750 free hours exhausted.

1. Render web service → change plan from **Free** to **Starter** (or higher).
2. Same Docker image and env vars; no code change.
3. Optional: increase workers by scaling instance count on paid tiers.

## 4. Monitoring

- Add Sentry or similar via env (future).
- Alert on `/health/ready` from an **external** monitor (low frequency) — not on every minute if still on Neon free.

## 5. Backup script

Local scheduled backup (PowerShell):

```powershell
$env:DATABASE_URL = "<neon-url>"
.\scripts\backup-db.ps1
```

See `docs/DEPLOY.md` for Task Scheduler steps and restore with `psql -f`.

## Cost reference after upgrade (indicative)

- Render Starter web: fixed monthly + no spin-down
- Neon Launch: usage-based storage/compute
- Render Key Value Starter: fixed monthly with persistence

Update `docs/COST.md` when you move to paid tiers.
