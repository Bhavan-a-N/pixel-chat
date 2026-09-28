# Deploy backend (Render + Neon + Render Key Value)

**Regions (Bengaluru-adjacent):**

| Component | Provider | Region |
|-----------|----------|--------|
| Web (Daphne) | Render | **Singapore** |
| Redis (Key Value) | Render | **Singapore** (same as web — private network) |
| Postgres | Neon | **AWS ap-southeast-1 (Singapore)** |

---

## Step 1 — Neon Postgres (you)

1. Sign in at [neon.tech](https://neon.tech) and create a project.
2. **Region:** choose **Singapore (ap-southeast-1)**.
3. Open **Connection details** → enable **Connection pooling** → copy the **pooled** connection string (host usually contains `-pooler`).
4. Ensure the string includes **`sslmode=require`** (Neon often appends this).
5. Keep the string private — you will paste it only into the Render dashboard as `DATABASE_URL`.

---

## Step 2 — Render Key Value (you)

1. Sign in at [render.com](https://render.com).
2. **New → Key Value** → name e.g. `pixel-chat-kv` → **Region: Singapore** → plan **Free** → Create.
3. After creation, copy the **Internal URL** (for a web service in the same region) or **External URL** if required.
4. Set Render env `REDIS_URL` to that value (often `rediss://...`).

---

## Step 3 — Render Web Service (you)

1. **New → Web Service** → connect this GitHub repo.
2. **Region:** **Singapore**.
3. **Root Directory:** `backend`
4. **Runtime:** Docker
5. **Instance type:** Free
6. **Health Check Path:** `/health/live` (not `/health/ready` — see ADR 0027)
7. **Pre-Deploy Command:** `python scripts/pre_deploy_migrate.py`
8. Add environment variables (see table below).
9. Deploy.

After deploy, note the public URL: `https://<service-name>.onrender.com`.

### Verify readiness (browser or PowerShell)

```powershell
Invoke-RestMethod -Uri "https://<service-name>.onrender.com/health/live"
Invoke-RestMethod -Uri "https://<service-name>.onrender.com/health/ready"
```

`/health/live` should always return 200. `/health/ready` returns 200 only when Neon and Redis are reachable (first call may take longer if Neon was suspended).

---

## Environment variables (Render dashboard)

| Name | Required | Description |
|------|----------|-------------|
| `DJANGO_SETTINGS_MODULE` | yes | `config.settings.prod` |
| `DATABASE_URL` | yes | Neon **pooled** Postgres URL (`sslmode=require`) |
| `REDIS_URL` | yes | Render Key Value URL (prefer internal URL in Singapore) |
| `SECRET_KEY` | yes | Django secret (generate locally — see below) |
| `INVITE_CODE` | yes | Shared signup gate for friends (generate locally) |
| `ALLOWED_HOSTS` | yes | Comma-separated hosts, e.g. `<service-name>.onrender.com` |
| `CSRF_TRUSTED_ORIGINS` | yes | Comma-separated HTTPS origins, e.g. `https://<service-name>.onrender.com` |
| `DB_CONN_MAX_AGE` | no | Default `60` (seconds). Use `0` if Neon pooler shows connection issues. |
| `JWT_ACCESS_TOKEN_LIFETIME_MINUTES` | no | Default `15` |
| `JWT_REFRESH_TOKEN_LIFETIME_DAYS` | no | Default `30` |
| `SECURE_SSL_REDIRECT` | no | Default `true` |
| `SECURE_HSTS_SECONDS` | no | Default `31536000` |
| `ALLOW_DESTRUCTIVE_MIGRATIONS` | no | Set to `true` **only** for one deploy after you review a destructive migration and run backup |

### Generate secrets locally (PowerShell)

Run on your PC; paste the **output values** into Render only (never into chat):

```powershell
# SECRET_KEY (50 chars, URL-safe)
python -c "import secrets; print(secrets.token_urlsafe(50))"

# INVITE_CODE (share privately with friends)
python -c "import secrets; print(secrets.token_urlsafe(12))"
```

---

## Migrations policy

- Every deploy runs `pre_deploy_migrate.py` before the new container goes live.
- Additive migrations apply automatically.
- Migrations with **RemoveField** or **DeleteModel** **block** deploy until you:
  1. Review the migration in git
  2. Run `scripts/backup-db.ps1`
  3. Set `ALLOW_DESTRUCTIVE_MIGRATIONS=true` for **one** deploy, then remove it

---

## Database backup and restore

### Backup (local PowerShell)

Set Neon **direct** (non-pooler) URL or pooled URL for read-only dump — pooled usually works for `pg_dump`:

```powershell
$env:DATABASE_URL = "<your-neon-connection-string>"
.\scripts\backup-db.ps1
```

Backups default to `D:\pixel-chat\backups\` (gitignored; inside the project per CLAUDE.md). Override with `PIXEL_CHAT_BACKUP_DIR`.

### Schedule (Windows Task Scheduler)

1. Open **Task Scheduler** → **Create Task**.
2. **Triggers:** weekly (or daily), time you choose.
3. **Actions:** Start a program  
   - Program: `powershell.exe`  
   - Arguments: `-NoProfile -ExecutionPolicy Bypass -File "D:\pixel-chat\scripts\backup-db.ps1"`  
4. **Conditions:** disable “Start only on AC” if on laptop.
5. Store `DATABASE_URL` in a **user environment variable** on your PC (not in the repo), or use a small wrapper script outside the repo that sets `$env:DATABASE_URL` then calls `backup-db.ps1`.

### Restore

```powershell
$env:DATABASE_URL = "<target-neon-url>"
$backup = "D:\pixel-chat\backups\pixel_chat_YYYYMMDD_HHMMSS.sql"
psql $env:DATABASE_URL -f $backup
```

Use Neon dashboard to reset branch or create a new branch before restoring over production data.

---

## Keep-warm (optional)

If you use an external pinger, target **`GET /health/live`** only. Do **not** ping `/health/ready` — that wakes Neon and burns CU-hours.

Render free web still spins down after **15 minutes** without inbound HTTP **or WebSocket messages**; chat activity on an open socket counts as traffic (since Feb 2026).
