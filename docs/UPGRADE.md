# Production Upgrade Guide

This document describes what needs to be changed when upgrading the infrastructure from the current free-tier setup to a paid, production-ready environment. The application is designed such that moving to a paid database or larger host is a configuration change, not a code change.

## 1. Database (PostgreSQL)
- **Change:** Migrate from the free-tier Postgres to a managed, paid database instance with automated backups, high availability (HA), and point-in-time recovery.
- **Config:** Update the `DATABASE_URL` environment variable to point to the new managed database. No code changes are required.

## 2. Redis
- **Change:** Upgrade to a paid Redis instance with higher connection limits and persistence, ensuring WebSocket connections don't drop during peak loads.
- **Config:** Update the `REDIS_URL` environment variable.

## 3. Host Size & Scaling
- **Change:** Upgrade the application host to a paid tier to eliminate idle-sleep (cold starts) and allocate more CPU/RAM. Scale the stateless ASGI workers horizontally by increasing the instance count.
- **Config:** Update scaling settings in the hosting provider's dashboard or configuration file (e.g., `render.yaml` or `fly.toml`).

## 4. Monitoring & Alerting
- **Change:** Implement proper application performance monitoring (APM) (e.g., Sentry) and set up alerts for database usage, error rates, and latency.

## Simple pg_dump Backup Script

While managed databases usually include backups, you can use this simple script to perform manual backups.

```bash
#!/usr/bin/env bash
# backup_db.sh

# Requirements: pg_dump installed, DATABASE_URL set in environment
if [ -z "$DATABASE_URL" ]; then
  echo "Error: DATABASE_URL is not set."
  exit 1
fi

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_FILE="backup_${TIMESTAMP}.sql"

echo "Starting database backup to ${BACKUP_FILE}..."
pg_dump $DATABASE_URL -F p -f $BACKUP_FILE

if [ $? -eq 0 ]; then
  echo "Backup completed successfully."
else
  echo "Backup failed!"
  exit 1
fi
```
